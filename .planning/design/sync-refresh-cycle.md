# Sync on quit/wake/write with a serialized store owner - Design Document

**Status**: Approved (Konrad, 2026-07-25; ticket AMUX-756)
**Created**: 2026-07-25
**Ticket**: AMUX-756

## Problem Statement

Sync runs only at app launch (`SyncedStore.syncAll`, commented "Runs once at
launch. Single-user, never-concurrent use is assumed"). A menu-bar app that
stays up for days therefore effectively never syncs: on 2026-07-25 the laptop
had been running since the previous evening and none of the day's vocabulary
and training changes reached the other Mac.

## Requirements

### Functional
- Sync also runs: on app quit (`applicationWillTerminate`), on wake from
  sleep and on app activation (the moments the user switches Macs), a few
  seconds after any local store mutation (debounced), and on an hourly
  backstop timer.
- Activation and wake triggers are rate-limited (skip when the last
  successful cycle was under ~5 minutes ago) so Cmd-Tab-heavy use does not
  produce sync storms.
- Layer 1, which must land before any trigger: all mutating store operations
  on the synced stores (learned.json, vocabulary.json, snippets.json) and
  `syncAll` run through ONE serialized owner (actor or serial queue), so a
  sync cycle can never interleave with a UI load-modify-save. Today that race
  exists only in the launch window; periodic sync would widen it to the whole
  app lifetime, which is why serialization is a precondition, not a polish
  item.

### Non-Functional
- No behavior change to merge semantics (`SyncMerge` untouched in meaning;
  its "never-concurrent" assumption becomes enforced rather than assumed).
- Triggers and debounce must be testable with injected clocks/paths; tests
  never touch the real `~/Library` data or the real CloudDocs folder
  (`LearnedStore.directoryOverride` / `VocabularyStore.directoryOverride`
  idiom; on machines without iCloud, `syncedDirectory` is nil and `syncAll`
  already skips - tests inject their own directories instead).

## Architecture

Files (any of these may be touched): `Sources/Mutter/SyncedStore.swift`,
`Sources/Mutter/SyncMerge.swift`, `Sources/Mutter/LearnedStore.swift`,
`Sources/Mutter/VocabularyStore.swift`, `Sources/Mutter/SnippetStore.swift`,
`Sources/Mutter/AppDelegate.swift`, `Sources/Mutter/Main.swift`,
`Sources/Mutter/AppPaths.swift`, `Sources/Mutter/MainView.swift`,
`Sources/Mutter/HistoryStore.swift` (history.json is not synced; include it
in the serialized owner only if it falls out naturally, otherwise leave it).

Shape: a single serial execution context (the "store owner") that (a) every
mutating entry point of the three synced stores routes through, and (b)
`syncAll` and every trigger route through. `applicationDidBecomeActive`
already exists (Cmd-Tab fix, 3c15a34) - EXTEND it, do not replace its
window-reopen behavior.

## Testing Strategy

Inline self-test additions (`--selftest` suite, currently 172 PASS):
- Serialization: concurrent mutations + a sync cycle against temp
  directories produce a consistent store (no lost update, no torn file).
- Debounce: injectable clock; N rapid mutations coalesce to one scheduled
  cycle.
- Rate limit: an activation trigger inside the min-interval is skipped; one
  outside it runs.
- Full suite stays green.

## Logging & Observability

Each trigger logs its reason and outcome at the existing SyncedStore log
level, so "why did/didn't it sync" is answerable from the unified log.

## Implementation Notes (Living Section)

### 2026-07-25 - Two new files: `StoreOwner.swift`, `SyncScheduler.swift`

Layer 1 and Layer 2 each got a dedicated new file rather than growing
`SyncedStore.swift` (already 438 lines) past the project's 500-line split
guidance:

- **`Sources/Mutter/StoreOwner.swift`** - the serialized store owner (Layer
  1). A synchronous serial `DispatchQueue`, not an actor: every store is
  enum-static with synchronous callers on the MainActor (SwiftUI `onAppear`
  closures, button actions, the CLI's `--format`/`--transcribe` paths). An
  actor would force every one of those call sites through `await`, rippling
  into MainView's non-async view code for no benefit - the work itself
  (JSON encode/decode plus a coordinated file write) is synchronous I/O, not
  something actor isolation improves.

  `StoreOwner.sync { }` wraps an operation; `StoreOwner.syncCycle { }` is the
  same but additionally flags the call (and everything nested inside it) as
  a sync cycle via `isRunningSyncCycle`. `LearnedStore`/`VocabularyStore`/
  `SnippetStore`'s `load()`/`save()` and every higher-level mutation
  (`add`, `addTerm`, `removeTerm`, `learn`, and a new `removeCorrection`)
  wrap their entire body in `sync`. `SyncedStore.syncAll`,
  `syncLearned`, `syncVocabulary` and `syncSnippets` each wrap their entire
  body in `syncCycle` - not just the outer `syncAll` - because self-tests
  (and `SyncMerge`'s existing composition tests) call the per-store
  functions directly with injected temp directories, bypassing `syncAll`
  entirely; if only `syncAll` were wrapped, those direct calls would race
  concurrent store mutations exactly as before.

  **Re-entrancy.** `syncAll` calls `syncLearned`/`syncVocabulary`/
  `syncSnippets`, each of which independently wraps itself in `syncCycle` -
  and `LearnedStore.learn()` calls `VocabularyStore.words()` for the
  taught-word guard, crossing store boundaries. A plain serial
  `DispatchQueue.sync` deadlocks if a thread already running on it tries to
  enter it again. `StoreOwner.sync` guards against this with a
  `DispatchSpecificKey` set on the queue: `getSpecific` returns non-nil only
  when already running on that queue, so a nested call runs `body()` inline
  instead of re-entering `queue.sync`. `syncCycle` saves/restores
  `isSyncCycle` around its body so nested `syncCycle` calls compose
  correctly (LIFO restore) instead of the inner call clearing the flag the
  outer one still needs.

  **Why a cycle flag at all.** `syncLearned`/`syncVocabulary`/`syncSnippets`
  write the merged result back locally via the stores' own `save()`. If
  `save()` unconditionally scheduled a debounced sync on every write, a
  sync cycle's own write-back would schedule its own successor, and every
  cycle would perpetually re-trigger another one a few seconds later.
  `save()` checks `StoreOwner.isRunningSyncCycle` and skips the debounce
  trigger when true.

- **`Sources/Mutter/SyncScheduler.swift`** - trigger timing (Layer 2): quit
  (bounded, `runFinalSyncBeforeQuit`), wake/activation (rate-limited,
  `triggerRateLimited`, skips inside a 5-minute window), debounced
  after-write (`triggerDebounced`, coalesces rapid mutations via a
  generation counter rather than `DispatchWorkItem.cancel()` - simpler to
  drive with an injectable `scheduleAfterDelay` for tests), and the hourly
  backstop plus the initial launch sync (both `triggerUnconditional`).
  `now`, `runCycle` and `scheduleAfterDelay` are all injectable so
  self-tests exercise real coalescing/rate-limit logic without a real clock
  or real store.

### Trigger wiring

- `Main.swift`'s launch-time sync now goes through
  `SyncScheduler.triggerUnconditional(reason: "launch")` instead of calling
  `SyncedStore.syncAll()` directly, so `lastCycleAt` is set at launch and
  the near-immediate `applicationDidBecomeActive` (NSApp activates itself
  during `showMainWindow()`) correctly rate-limits against it instead of
  double-syncing on every cold launch.
- `AppDelegate.applicationDidBecomeActive` keeps its existing
  deminiaturize/reopen body unchanged and adds one call:
  `SyncScheduler.triggerRateLimited(reason: "activate")`.
- `AppDelegate.applicationDidFinishLaunching` additionally registers for
  `NSWorkspace.didWakeNotification` (-> `triggerRateLimited(reason: "wake")`)
  and starts an hourly `Timer` (-> `triggerUnconditional(reason: "hourly
  backstop")`), matching the existing `Timer.scheduledTimer` idiom already
  used in `MicMonitor`.
- `AppDelegate.applicationWillTerminate` (new) calls
  `SyncScheduler.runFinalSyncBeforeQuit()`, which bounds the wait with a
  `DispatchSemaphore` timeout rather than trusting `syncAll` to return
  quickly on its own - the same bounded-wait posture `AppPaths.readShared`
  already takes against the same iCloud coordinator, applied one level up.
- **`Sources/Mutter/AppDelegate+Sync.swift`** (new file) holds the wiring
  above with nowhere else to go: `AppDelegate.swift` was already at
  478/500 lines before this ticket, and adding the wake observer, hourly
  `Timer` setup, and `applicationWillTerminate` inline pushed it past 500.
  Extension methods can't hold the timer's own stored property (Swift
  extensions can't add stored properties), so `hourlySyncTimer` stays
  declared in `AppDelegate.swift`, but `setUpSyncTriggers()` (wake observer +
  hourly timer), `handleWake()` and `applicationWillTerminate` moved to this
  file. `applicationDidBecomeActive`'s activation trigger stayed in the main
  file, next to the method it extends.

### Deviations from the original design sketch

- Added `SnippetStore.directoryOverride`, mirroring `LearnedStore` and
  `VocabularyStore` - it didn't exist before, and the serialization
  self-test needs to inject temp directories for all three synced stores.
- Added `LearnedStore.removeCorrection(id:)` and switched the one Training-
  page delete-correction button (`MainView.swift`) that previously called
  `LearnedStore.load()` / mutate / `LearnedStore.save()` inline to use it.
  That inline sequence was a load-modify-save race outside any store-owned
  entry point; wrapping `load()`/`save()` individually would not have made
  the *sequence* atomic, only its two halves.
