# Learning Guardrails + iCloud Sync - Design Document

**Status**: Draft
**Created**: 2026-07-20
**Last Updated**: 2026-07-20
**Upstream**: https://github.com/janisbelozerovs-dev/murmur (default branch `main`)

## Problem Statement

Two separate problems, addressed together because the second must not ship before the first.

### Problem 1: transcript editing poisons the correction store

`LearnedStore.learn(original:corrected:)` fires whenever the user edits a transcript in
History (`AppDelegate.swift:212`). It runs a word-level LCS diff and treats *any*
substituted run as a pronunciation fix. The only rejection rule is
`isUsefulMapping()`, which discards a mapping only when `heard` is under two characters
or equals `intended`.

Consequently, editing a transcript for *wording* rather than to fix a mishearing
invents a bogus rewrite rule. Those rules are then applied globally to every future
transcript by `LearnedStore.apply(in:)` (called on the live dictation path at
`AppDelegate.swift:312`, `Main.swift:51`, `Main.swift:95`), which produces more text
the user wants to edit, which learns more bogus rules. It is a positive feedback loop.

`apply(in:)` compounds this. It loads all corrections, sorts by `heard.count`
descending, and applies each as a global case-insensitive whole-word regex over the
*same mutating string*, sequentially. Bidirectional pairs therefore collapse
deterministically:

| Stored rules | Sorted order | Net effect on any text |
|---|---|---|
| `Phocus`→`focus`, `focus`→`Phocus` | `Phocus` (6) then `focus` (5) | every "focus" **and** "Phocus" becomes "Phocus" |
| `more`→`RAW`, `RAW`→`more` | `more` (4) then `RAW` (3) | every "RAW" **and** "more" becomes "more" |

Observed on a real store after roughly one day of use: 36 corrections, of which 23 were
harmful. Single common words rewritten globally included `my`→`a`, `God`→`guide`,
`have`→`work`, `It's`→`than`, `form`→`forum`, `defeat`→`datasheet`. The word "RAW"
had become undictatable.

### Problem 2: learnings are per-machine

All state is local: `~/Library/Application Support/Murmur/*.json` plus
`~/Library/Preferences/local.murmur.plist`. Using Murmur on a second Mac means
re-teaching every correction and vocabulary term from scratch. There is no export,
import, or sync of any kind.

## Requirements

### Functional

**Fix (upstream PR):**
- A mapping whose `heard` side could plausibly occur in ordinary speech must not be
  learned automatically from a transcript diff.
- A mapping must not be learned when its reverse is already stored.
- `apply(in:)` output must be independent of correction ordering, and no region of the
  input may be rewritten more than once.
- Explicit teaching via the Voice Training page is unaffected. The user stating a
  mapping outright is not a guess and is not second-guessed.
- **All four existing `LearnedStore.runSelfTest()` cases must remain green.** They
  encode the author's definition of a legitimate mapping and are treated as
  requirements, not as tests we are free to edit.
- The existing "Learned N corrections" feedback names what was learned and what was
  skipped.
- No change to the on-disk format. Existing `learned.json` files must load unchanged.

**Sync (local branch only):**
- `learned.json`, `vocabulary.json`, `snippets.json` shared between two Macs via iCloud
  Drive. History and scratchpad are explicitly excluded.
  **Revised 2026-07-23:** `dictionary.json` was replaced as the dictionary's source of
  truth by `vocabulary.json` (`[VocabularyEntry]`, the fork's own format — see
  `vocabulary-dictionary-and-context-disambiguation.md`). The legacy `dictionary.json`
  is a frozen one-time migration source and is NOT synced.
- Merging must be non-destructive: a correction present on either machine survives.
- Deleting a correction on one machine must not be undone by a merge from the other.
- iCloud Drive absent, logged out, or unreachable degrades to local-only silently.

### Non-Functional

- The fix must be small and idiomatic enough to be accepted into an hours-old repo
  (created 2026-07-20, two commits, one author, no PRs, no CONTRIBUTING guidance). It
  follows the author's existing `runSelfTest()` convention rather than introducing
  XCTest.
- The sync change must stay confined to `AppPaths` plus one new file, so the local
  branch rebases cleanly onto upstream.
- No new third-party dependencies.
- No Apple Developer account required. Verified: the app is unsandboxed with no
  entitlements, so a plain path under `~/Library/Mobile Documents/com~apple~CloudDocs/`
  is writable without a provisioning profile or CloudKit container.

## Architecture

### Branch topology

| Branch | Base | Contents | Destination |
|---|---|---|---|
| `main` | upstream | untouched tracking branch | — |
| `local/main` | `main` | design docs + fix + sync; the build we run daily | never pushed upstream |
| `fix/learning-guardrails` | `main` | fix commits only, cherry-picked | fork → PR |

Planning documents live only on `local/main`, so the PR branch cannot pick them up.

### Components - the fix

**`WordChecker`** (new, ~25 lines, `Sources/Murmur/WordChecker.swift`)

Single responsibility: answer "could this phrase occur in ordinary speech?" A protocol
with two implementations - `SystemWordChecker` wrapping `NSSpellChecker` for
production, and a fixed-word-set fake for tests.

The seam is required, not decorative: `NSSpellChecker` learns words per user, so its
verdicts differ between machines and drift over time. Self-tests asserting against the
live checker would pass on one Mac and fail on another.

**`LearnedStore.isUsefulMapping(heard:intended:)`** gains two guards:

- *Ordinary-speech guard*: reject when every whitespace-separated token in `heard` is an
  ordinary word, **unless the mapping is a pure re-segmentation** - that is, unless
  `heard` and `intended` are equal after lowercasing and removing every non-alphanumeric
  character. A token is ordinary when, after trimming surrounding punctuation and
  lowercasing, it contains no digits, is at least two characters, and is spelled
  correctly. Lowercasing is essential - spell checkers accept any capitalised token as a
  proper noun, and digit rejection preserves model names like `X2D2`.
- *Reverse guard*: reject when `intended`→`heard` is already stored.

The re-segmentation exception is not a nicety; without it the guard rejects the
author's own self-test case `base ten`→`Baseten` (`LearnedStore.swift:227`), which is
precisely the feature they built this for. Re-segmentation is the signal that separates
a genuine mishearing from a content edit: the same sounds, split differently
(`"base ten"` and `"Baseten"` both normalise to `"baseten"`). `He caught`→`Helicon`
does *not* normalise-equal and stays correctly rejected - without the guard,
"he caught the ball" would become "Helicon the ball".

**`LearnedStore.apply`** splits in two:

- `apply(in:)` - existing signature, loads the file, delegates. Unchanged call sites.
- `apply(in:using:)` - takes corrections explicitly. Single left-to-right pass over the
  original string; each source region is consumed at most once. Order-independent.

**`MainView`** - the learn-feedback toast reports skipped mappings alongside learned ones.

### Components - sync

**`AppPaths.syncedDirectory`** - returns
`~/Library/Mobile Documents/com~apple~CloudDocs/Murmur/` when iCloud Drive is present,
`nil` otherwise.

**`SyncedStore`** (new, `Sources/Murmur/SyncedStore.swift`) - merge on load, write both
copies on save, for the three shared files.

### Merge strategy: three-way, no schema change

**Revised 2026-07-21, replacing the original union-plus-tombstones design.** Two facts
found while reading the stores killed the original:

- `dictionary.json` is a bare `[String: String]` and `snippets.json` a bare `[Snippet]`
  array. Neither has anywhere to carry a tombstone list without changing a file format
  upstream owns - while PR #1 is open, that is exactly the wrong thing to do.
- Tombstones need a per-entity timestamp to decide whether a deletion is stale, which
  means touching all three schemas.

Instead each machine keeps a local snapshot of the state it last synced, and merging is
a three-way diff of base vs local vs remote. **No on-disk format that upstream owns
changes at all.**

For each store, entities are keyed (see below) and the merge is:

1. `localChanges  = diff(base, local)`  - added, modified, removed
2. `remoteChanges = diff(base, remote)`
3. Apply both change sets to `base`.
4. If both sides changed the same key, prefer local - it is the machine the user is
   sitting at. Never-concurrent use makes this rare by construction.
   **Delete-vs-edit sub-case (made explicit 2026-07-23): the edit wins, in either
   direction.** A key deleted on one side but edited on the other survives with the
   edited value - losing an edit is unrecoverable, while an unwanted resurrected entry
   can simply be deleted again. "Prefer local" applies only when both sides hold
   values; a deletion never silently destroys the other machine's edit.
5. Write the merged result to local and remote, then write it as the new base.

Deletion needs no tombstone: a key present in `base` and absent in `local` was deleted
here, so it is removed from the merge rather than resurrected from the remote. That was
the failure that motivated the original design, and it is handled structurally.

**A missing base degrades to a plain union**, which is exactly the desired first-run
behaviour when seeding the second machine.

Keys per store:

| Store | Key | Collision rule |
|---|---|---|
| `learned.json` corrections | `heard.lowercased()` | higher `timesSeen` wins |
| `learned.json` terms | the term, lowercased | union; **no delete UI exists, so removals are never inferred** |
| `vocabulary.json` | `word.lowercased() + "\u{0}" + (misheard ?? "").lowercased()` — the same (word, misheard) pair key `VocabularyStore.migrate` dedups by | prefer local |
| `snippets.json` | `trigger.lowercased()` | prefer local |

The vocabulary key deliberately ignores each entry's `UUID id`: the two machines
mint different UUIDs for the same logical entry (e.g. both migrated `X2D2 -> X2D II`
independently), so keying on identity content rather than UUID is what makes the
first merge unify them instead of duplicating every entry.

Keying corrections on `heard` alone matches `LearnedStore.merging(_:heard:intended:)`,
which already enforces one rule per phrase.

The base snapshot lives at `AppPaths.supportDirectory/sync-base.json` - **local, not in
iCloud**, because it records what *this machine* last saw. Re-applying a merge after a
crash between the two writes is idempotent, so a stale base is self-correcting.

## Data Flow

**Learn:** user edits transcript → `extractCorrections` diffs → each candidate passes
guards → survivors stored → toast names learned and skipped.

**Apply:** transcript produced → `apply(in:using:)` single pass → text inserted.

**Sync (launch):** read base, local and remote; three-way merge; write the merged result
to local and remote atomically; write it as the new base.
**Ordinary saves during a session:** write local only, exactly as today. Sync runs at
launch, so an in-session save needs no remote round trip.
**iCloud absent:** local only, no error surfaced, base left untouched.

## API Design

```swift
protocol WordChecker {
    /// True when `word` is an ordinary word of the user's language.
    func isOrdinaryWord(_ word: String) -> Bool
}

extension WordChecker {
    /// True when every token could occur in ordinary speech.
    func isOrdinaryPhrase(_ phrase: String) -> Bool
}

enum LearnedStore {
    static func apply(in text: String) -> String
    static func apply(in text: String, using corrections: [LearnedCorrection]) -> String

    static func isUsefulMapping(heard: String, intended: String,
                                existing: [LearnedCorrection],
                                checker: WordChecker) -> Bool
}

/// One store's worth of keyed entities, as seen at the last successful sync.
struct SyncBase: Codable, Equatable {
    var corrections: [String: LearnedCorrection] = [:]
    var terms: [String] = []
    var vocabulary: [String: VocabularyEntry] = [:]
    var snippets: [String: Snippet] = [:]
}

enum SyncMerge {
    /// Three-way merge of one keyed collection. `prefersLocal` breaks a
    /// both-sides-changed tie; `resolve` merges two versions of one entity.
    static func merge<Value: Equatable>(
        base: [String: Value], local: [String: Value], remote: [String: Value],
        resolve: (Value, Value) -> Value) -> [String: Value]
}

enum SyncedStore {
    /// Merged view of a store, and the base to persist if the caller writes.
    static func loadLearned() -> LearnedData
    static func saveLearned(_ data: LearnedData)
    static func syncAll()
}
```

## Testing Strategy

Extends the existing `runSelfTest()` convention wired to `--selftest`. No new test
target, no new dependency.

### Guard tests (`LearnedStore`)

The regression suite has two halves, and the first half gates merge:

**The author's four existing cases are hard invariants.** They define what a legitimate
mapping means to the person who has to accept the PR: `base ten`→`Baseten`,
`Soren`→`Søren`, `so ren`→`Søren`, and `Hello world` producing no mappings. All four
must stay green. Any guard that breaks one is wrong by definition, regardless of how
well it scores on the corpus below.

**The 36 real mappings** from an actual poisoned store, each with a known verdict, run
against the fake `WordChecker` for determinism.

Measured against the live `NSSpellChecker` with the re-segmentation exception in place:
**author's tests 3/3 mapping cases pass, 20 of 23 junk mappings rejected, 10 of 13
legitimate mappings retained.**

- Known false negatives (junk that survives): `Phocus`→`focus`,
  `Phocus standard`→`focus-stack`, `Lightroom, right`→`Lightroom`. All survive because
  they contain user-specific vocabulary a dictionary reads as distinctive. Harm is
  bounded by the single-pass `apply`, and the toast now names them so they can be
  deleted.
- Known false positives (legitimate mappings lost): `Dot force`→`.phos`, `TIF`→`TIFF`,
  `J.P`→`JPEG`. All redundant - `Dot Foss` still covers `.phos` and four other rules
  still cover JPEG.

These numbers are reported in the PR description rather than smoothed over.

### Cascade tests (`LearnedStore.apply(in:using:)`)

- Given `Phocus`→`focus` and `focus`→`Phocus`, input `"focus Phocus"` must not collapse
  to a single value, and output must be identical whichever order the rules arrive in.
- Given `more`→`RAW` and `RAW`→`more`, "RAW" must survive.
- No region rewritten twice.

### Merge tests (`SyncMerge`, local branch)

`SyncMerge.merge` is pure, so all of these run without touching disk:

- Disjoint additions on both sides keep both.
- An entry deleted locally (in base, absent in local) stays deleted, and is **not**
  resurrected from the remote. This is the regression that motivated the design.
- An entry deleted remotely disappears locally.
- An entry re-added after deletion survives.
- Colliding corrections take the higher `timesSeen`.
- Both sides modified the same key: local wins.
- **Missing base behaves as a union** - the first-run seeding case.
- An unchanged store merges to itself.

Only the file-level plumbing (`syncAll`, eviction, corrupt remote) needs a temporary
directory. That is a smaller surface than the original design required, because no
tombstone bookkeeping has to be round-tripped through JSON.

All of this stays on the local branch and out of PR #1.

### Edge cases

- Empty store, empty transcript, mapping with punctuation only.
- `learned.json` written by an unmodified upstream build (no `updatedAt`, no `deleted`).
- Remote file corrupt or truncated.
- Remote evicted to a `.icloud` placeholder.

## Error Handling

| Condition | Behaviour |
|---|---|
| iCloud Drive absent / logged out | local-only, silent |
| Remote JSON corrupt | log, keep local, **do not** overwrite remote until a clean read succeeds |
| Remote evicted (`.icloud` placeholder) | request download, skip this merge cycle - never treat absent as empty |
| Local JSON corrupt | fall back to remote if readable, else empty store |
| Atomic write fails | log, keep in-memory state, retry on next save |
| Base missing or corrupt | treat as empty, which degrades the merge to a union - safe, since a union can only over-retain, never delete |
| Crash between writing the merge and writing the base | next launch re-merges from the stale base; re-applying the same change set is idempotent |

The "absent is not empty" rule matters most: treating a not-yet-downloaded file as an
empty store would merge to empty and then write that emptiness back, destroying both
copies.

## Logging & Observability

The app has no logging framework today and adding one is out of scope for the PR.

**Fix branch (PR): adds no logging.** Visibility into guard decisions is delivered
through the existing toast, which names both learned and skipped mappings. Introducing
`os.Logger` to a repo that has never used it would enlarge the diff and invite a
style debate on a change whose point is a bug fix.

**Sync branch (local only):** uses `os.Logger`, subsystem `local.murmur`, category
`sync`:

- `.info` on merge: counts in from local, in from remote, merged, tombstoned.
- `.error` on unreadable remote, failed write, or eviction, including the file path and
  the underlying error - not just its message.

No transcript text, correction text, or vocabulary term is ever logged. The store is a
record of how the user speaks, and log files have a different privacy lifetime than
Application Support.

## Implementation Notes (Living Section)

### 2026-07-23 - Sync half reconciled with the vocabulary-dictionary feature

The guardrails half shipped (upstream PR #1) in July. The sync half sat unimplemented
while the fork grew the vocabulary dictionary (2026-07-23), which changed the ground
under this design in three ways, now reconciled above and in the revised plan:

- **`dictionary.json` is no longer the dictionary.** `VocabularyStore`/`vocabulary.json`
  (`[VocabularyEntry {id, word, misheard?}]`) replaced it as source of truth; the legacy
  file is a frozen one-time migration input. Sync therefore covers `vocabulary.json`,
  not `dictionary.json`, and the merge keys on the (word, misheard) content pair, not
  the entry UUID (each machine mints different UUIDs for the same logical entry).
- **`VocabularyStore.load()` has side effects sync must respect**: one-time migration
  under a double-checked `NSLock`, and corrupt-file preservation (`vocabulary.json.corrupt`).
  Sync reads local vocabulary through `VocabularyStore.load()` so those behaviours hold,
  and its `localIsIntact` damage check decodes `[VocabularyEntry].self`.
- **The self-test baseline moved from 57 to 88** (mic selector + vocabulary features),
  and `LearnedStore.runSelfTest()` is now `async`. `SyncMerge.runSelfTest()` stays
  synchronous.

First-run interplay verified by reasoning, to be proven in the plan's Task 5: on a fresh
laptop, `VocabularyStore.load()` migrates an absent legacy file to an empty
`vocabulary.json`; sync then sees empty local + missing base and unions with the remote,
which can only add. Order does not matter because a missing base degrades to a union.

## Open Questions / Accepted Limitations

- **Launch-time sync only.** A machine left running for days will not see the other's
  changes until relaunch. Acceptable given single-user, never-concurrent usage. A
  `DispatchSource` file watcher is the escape hatch if it becomes annoying.
- **`timesSeen >= 2` before applying** was considered and rejected. It would block
  legitimate one-off corrections from taking effect and make the feature feel broken.
  The ordinary-speech guard carries the load instead.
- **Phonetic-similarity scoring** was considered and rejected for the PR. More
  principled, but threshold tuning without a corpus is guesswork and the diff is too
  opinionated for a first contribution.
- **`Phocus`→`focus` residual.** The user's own vocabulary defeats a dictionary-based
  guard by construction. Mitigated, not solved.
- **Upstream may decline.** If so, `local/main` becomes a maintained fork; the fix is
  already isolated in its own commits, so nothing changes structurally.
