# Renaming Murmur → Mutter — Strategy

**Status**: Draft (awaiting approval)
**Created**: 2026-07-24
**Repo**: `~/projects/murmur`, branch `local/main` (68 commits ahead of upstream `main`, 0 behind)

## Problem Statement

The fork `kmichels/murmur` has diverged into its own product. Konrad wants it renamed to
"Mutter". The rename is not a find-and-replace: several of the strings named "Murmur" are
**identity anchors** that macOS and iCloud key off. Getting the order wrong loses TCC
permission grants, 3.3 GB of downloaded Whisper models, or — worst case — the learned
corrections store.

## Verified current state (all checked, not assumed)

### Where the name appears

| Location | Count | Kind |
|---|---|---|
| `Sources/Murmur/*.swift` (17 files) | 55 | UI strings, comments, error domains, logger subsystems, `MurmurMain` struct |
| `Package.swift` | 3 | package name, product name, target path |
| `scripts/make_app.sh` | 10 | app bundle name, executable, icon, `CFBundleIdentifier`, mic-usage string |
| `scripts/make_icon.swift` | 2 | comment + default output filename |
| `README.md` / `PLAN.md` / `LICENSE` | 24 | prose |
| `.planning/**` (7 docs) | 160 | historical design/plan docs |
| `Resources/Murmur.icns` | — | filename |
| `Sources/Murmur/` | — | directory name |

### Identity anchors (these are the whole problem)

1. **`CFBundleIdentifier = local.murmur`** — TCC grants are keyed to it. Verified live:
   - `kTCCServiceAccessibility | local.murmur | 2` (system TCC.db) — required for text insertion
   - `kTCCServiceMicrophone | local.murmur | 2` (user TCC.db)
   - `kTCCServiceFileProviderDomain | local.murmur | 2` (user TCC.db) — this is the grant that
     actually lets sync read `CloudDocs/`
   - `UserDefaults` domain = bundle ID. `~/Library/Preferences/local.murmur.plist` holds
     `hotkey`, `engine`, `whisperModel`, `inputDeviceUID` (the Sennheiser fix), `voiceProfile`.

2. **`~/Library/Application Support/Murmur/`** — `AppPaths.supportDirectory`, the parent of
   *everything*: `learned.json`, `vocabulary.json`, `snippets.json`, `history.json`,
   `sync-base.json`, two hand-made backups, and **`whisper-models/` at 3.3 GB**.

3. **`~/Library/Mobile Documents/com~apple~CloudDocs/Murmur/`** — the shared folder. **A second
   Mac (the MacBook Pro) reads and writes this.** `SyncMerge.runSelfTest()` hard-asserts
   `lastPathComponent == "Murmur"`.

4. **Code-signing identity `WhisperFlow Dev`** (present in the login keychain; `make_app.sh`
   uses it). The signature is what makes the Accessibility grant survive rebuilds. **Renaming
   the certificate invalidates the signature and resets every TCC grant** — an own-goal with
   no upside.

5. **Second `Murmur` UserDefaults domain** (`~/Library/Preferences/Murmur.plist`, holding
   `disambiguationEngine = off`). Running the *unbundled* binary makes `UserDefaults.standard`
   key off the process name, so the **executable name is also a defaults domain**. Not
   harmless: it holds real state, and renaming the executable silently resets it to the
   `.off` default — which happens to be the same value today, but will not be once the macOS
   27 disambiguation toggle lands. Back it up and migrate it with the rest.

### Precedent already in the code

This app has been renamed once before (WhisperFlow → Murmur) and the migration code is still
there — reuse the pattern, don't invent one:
- `AppPaths.swift:11-15` — moves `Application Support/WhisperFlow` → `Murmur` if the new dir
  is absent.
- `AppDelegate.swift:481` — reads the legacy `local.whisperflow` defaults suite.
- `AppDelegate.resetAccessibilityGrant()` — already shells out to
  `tccutil reset Accessibility <bundleid>` and relaunches.

### Constraints that make this *easier* than expected

- **Upstream is dormant.** `janisbelozerovs-dev/murmur` has 2 commits total, last one
  2026-07-20. PR #1 has been open since 2026-07-21 with zero maintainer comments. The usual
  argument against renaming source directories in a fork (every future upstream merge becomes
  a conflict on every file) barely applies here.
- **Not installed system-wide.** The app runs in place from `~/projects/murmur/build/Murmur.app`
  — no `/Applications` copy, no LaunchAgent, no login item. Fewer places to miss.
- **`kmichels/mutter` is available on GitHub** (404 on the API — no collision).
- **The 3.3 GB model dir is on the same volume**, so `FileManager.moveItem` is a rename, not a
  copy. Instant.

## Naming note (flag, not a blocker)

"Mutter" is the name of GNOME's window manager (`GNOME/mutter`), and is German for "mother".
Neither collides on macOS or in the `kmichels/` namespace. In English it means to speak
quietly and indistinctly — the same register as "murmur", so the fork reads as a deliberate
continuation rather than a random rebrand. Konrad's call; noted so it isn't a surprise later.

## Strategy: three phases, ordered by blast radius

The controlling idea: **separate the free renames from the anchored ones, and ship the free
ones first.** Phase 1 is reversible with **`git revert` plus a rebuild** — `build/` and `.build/` are
gitignored, so a revert restores the source but not a runnable bundle, and the rebuild
produces a new cdhash. The genuinely irreversible parts of Phase 1 are the LaunchServices
registration, the deleted Accessibility row, and `Murmur.plist` → `Mutter.plist`. Phases 2 and
3 each break something real and get their own verification gate.

---

### Phase 1 — Everything that is only text (recommended: do all of it)

No permission loss, no data migration, no second-Mac coordination.

1. `git mv Sources/Murmur Sources/Mutter`; update `Package.swift` (package name, product
   name, target name, `path:`).
2. `git mv Resources/Murmur.icns Resources/Mutter.icns`.
3. `MurmurMain` → `MutterMain` in `Main.swift`; the CLI usage block's `Murmur --transcribe`
   etc.
4. All user-visible strings: menu items ("Open Mutter…", "Quit Mutter"), window title,
   `MainView` body copy (16 occurrences), and `AppDelegate.swift:389`
   `accessibilityDescription` — VoiceOver-visible, easy to miss.
   `LearnedStore` skip messages: **one** production format string at `LearnedStore.swift:41`
   plus **four** self-test expectations at `:657, :660, :664, :672` that are compared
   string-equal against its output at `:676` — they must change together. (Those five, plus
   `SyncMerge.swift:72` in Phase 3, are the *only* string-equality assertions carrying the
   name; the `murmur-selftest-*` temp paths are self-consistent within a run.)
5. Error domains (`NSError(domain: "Murmur")` ×2) and logger subsystems
   (`com.murmur`, `local.murmur` — currently inconsistent with each other; unify on
   `local.mutter` while touching them, they are log-filtering labels only).
6. Temp-file prefixes: `murmur-<uuid>.caf`, `murmur-selftest-*` (4 sites).
7. `make_app.sh`: `build/Mutter.app`, `CFBundleName`/`CFBundleExecutable`/`CFBundleIconFile`
   = `Mutter`, mic-usage string. **Leave `CFBundleIdentifier` alone in this phase** (see
   Phase 2). `make_icon.swift` default filename.
8. `README.md`, `PLAN.md`, `LICENSE` (`Copyright (c) 2026 Murmur contributors` stays — that
   line is upstream's attribution and MIT requires preserving it; add nothing, remove
   nothing). Fork-attribution blockquote gets a "formerly Murmur" line.
9. `.planning/**` and `.superpowers/sdd/**`: **leave as historical record.** These are dated
   design docs describing what was built when it was called Murmur; rewriting them falsifies
   the record. One note at the top of each design doc is enough.
10. `rm -rf build/ .build/` and rebuild. **This is a correctness requirement, not hygiene** —
    renaming the SwiftPM target renames the product binary, so a stale `.build/release/Murmur`
    would otherwise sit there ready for `make_app.sh:13` to copy. Delete the stale
    `build/Murmur.app` explicitly, and re-register LaunchServices (step above), or Konrad
    relaunches the old one from Spotlight. Note `Package.resolved` needs no change — it pins
    only WhisperKit and swift-argument-parser, and its `originHash` is a dependency-graph
    hash, not a package-name hash.

**Verification gate:** `swift build -c release && .build/release/Mutter --selftest` — all 115+
self-tests pass; `./scripts/make_app.sh` produces a signed `build/Mutter.app`; launch it and
confirm dictation still works, hotkey still `rightOption`, mic still the Sennheiser.

**Do not use "no permission dialogs appeared" as the gate.** Phase 1 changes the executable
name, the bundle name, and the bundle path, so the cdhash is entirely new and LaunchServices
re-registers the app at a new location. A prompt re-firing is a *normal* outcome, not evidence
of signature damage — and the Accessibility row in System Settings is bound to the old
`build/Murmur.app` path, which step 10 deletes, so re-adding `Mutter.app` there is expected.
Use a positive check instead:

```
codesign -dr - build/Mutter.app     # expect: identifier "local.murmur" and cert leaf …
```

`make_app.sh:55` signs without `--identifier`, so the signing identifier still defaults to
`CFBundleIdentifier` (`local.murmur`) and the designated requirement is preserved. That is the
thing to verify. Also run `lsregister -kill -r -domain local -domain user` after deleting the
old bundle, or Spotlight and `open -a` keep resolving "Murmur" to a path that no longer exists.

**Result:** app is called Mutter everywhere the user can see, with zero permission or data
disruption. Data still lives in `Application Support/Murmur/` and `CloudDocs/Murmur/`.

---

### Phase 2 — Bundle identifier and local data directory (recommended: yes, but separately)

This is where permissions break. Do it as its own commit, on its own day, with the app quit.

**Recommendation: change `local.murmur` → `local.mutter`.** Rationale for doing it rather
than living with the mismatch: the bundle ID is also the `UserDefaults` domain and the
`tccutil` argument the app passes to itself in `resetAccessibilityGrant()`. Leaving it stale
means every future permission-debugging session starts with "wait, why is Mutter registered
as murmur?" — and this app has *already* burned real time on TCC confusion (the FDA/Ubiquity
gotcha). One re-grant now is cheaper than permanent ambiguity.

**Rationale for a reader who disagrees:** keeping `local.murmur` is entirely viable. It is an
opaque reverse-DNS string with a `local.` prefix that no user ever sees; System Settings
displays `CFBundleName` ("Mutter"), not the identifier. If Konrad would rather never re-grant
anything, skipping Phase 2's bundle-ID change costs nothing functional.

Steps, in order:

1. **Back up first**, to `~/Murmur-backup-$(date +%Y%m%d)` — **not the Desktop**, which is
   iCloud-synced under Desktop & Documents and would upload `history.json` (every sentence
   ever dictated) to Apple. Exclude `whisper-models` (3.3 GB, re-downloadable). Also copy the
   three files in `CloudDocs/Murmur/`, **and both preference files**:
   `~/Library/Preferences/local.murmur.plist` and `~/Library/Preferences/Murmur.plist`.
2. Quit Mutter on **both** Macs. Confirm with `pgrep -fl -i 'murmur|mutter'` on each.
   **Quitting the app is not sufficient for the plists.** `cfprefsd` caches both domains in
   memory and rewrites them on its own schedule, so any `defaults` surgery needs a
   `killall cfprefsd` after it — and the Phase 2 verification `defaults read local.mutter`
   may otherwise read a cache rather than the file.
3. `AppPaths.supportDirectory`: rename target to `Mutter`, and make the legacy list a
   **chain** — `Murmur` first, then `WhisperFlow` — so a machine that skipped a generation
   still migrates. **Keep the existing `if !exists(new) && exists(legacy)` guard verbatim.**
   It is doing more work than it looks: `FileManager.moveItem` throws if the destination
   exists, so that guard is the only thing making the migration idempotent. A chained rewrite
   that drops it will throw the first time anything has already created
   `Application Support/Mutter/` — and a self-test run is enough to create it. Move the
   **whole directory**, never a subset: `sync-base.json` must travel with the store files it
   describes (see Phase 3 note on why splitting them is the real data-loss path).

   **⚠ This is the step that will actually bite — see "How this really goes wrong" below.**
   `AppPaths.supportDirectory` calls `createDirectory` *unconditionally* at
   `AppPaths.swift:17-18`, after the migration guard at `:12-15`. So merely **reading** the
   property creates the directory and closes the guard forever. Three changes are required
   together, not one:
   - **Do the `mv` by hand before building.** `mv ~/Library/Application\ Support/Murmur \
     ~/Library/Application\ Support/Mutter`. Then the in-code migration is a safety net for
     the MacBook Pro rather than the mechanism you are betting on.
   - **Widen the guard from "destination absent" to "destination absent *or empty*"**, so a
     stray directory-creation is self-healing instead of permanent.
   - **Replace `try? moveItem` with logged error handling.** `AppPaths.swift:14` currently
     swallows every failure silently, in a file where every other risky path logs. If the
     move fails you get an empty store and no evidence.
4. `Settings.migrateLegacyDefaults()` (`AppDelegate.swift:477-489`) — **extend the existing
   one-time copy, do not add a fallback suite.** The existing function is already the right
   shape: it is guarded so it runs once, copies values into the new domain, and leaves no
   permanent read path to the old one. A `UserDefaults` *fallback* would instead resurrect an
   old value whenever the user resets a setting in the new domain, making a factory reset
   impossible.

   **The key list is the trap.** The function currently copies only
   `hotkey`, `locale`, `styleDefault`, `styleOverrides`. Everything added since the last
   rename is missing: `engine`, `whisperModel`, `inputDeviceUID`, `disambiguationEngine`, and
   `voiceProfile` (written separately by `VoiceProfile.save()` at `VoiceProfile.swift:30`).
   Copying only the current list silently drops all five.
   **`inputDeviceUID` matters most** — losing it reverts recording to the Studio Display
   far-field array, which is exactly the bug the mic selector was built to fix, and it fails
   silently. The guard condition (`hotkey == nil && locale == nil`) also needs rethinking,
   since a machine could have `hotkey` set but nothing else.
5. `make_app.sh`: `CFBundleIdentifier` → `local.mutter`. **Do not rename the signing
   certificate** — `WhisperFlow Dev` stays exactly as it is, in both `make_app.sh` and
   `make_signing_cert.sh`. Its name is cosmetic; its stability is what preserves grants
   across rebuilds. (Add a one-line comment explaining why the stale name is deliberate.)
6. Rebuild, launch, re-grant: Microphone (prompted), Accessibility (System Settings →
   Privacy & Security → Accessibility, add `build/Mutter.app`), and Files & Folders → iCloud
   Drive when sync first runs.
7. Remove the stale `local.murmur` TCC rows once Mutter's are confirmed working:
   `tccutil reset Accessibility local.murmur` etc. **Do this last, and only after
   verification** — it is the rollback path.

**Verification gate:** `Application Support/Mutter/` exists and contains all 8 files plus
`whisper-models/`; `Application Support/Murmur/` is gone (moved, not copied — check free disk
space did not drop by 3.3 GB); `defaults read local.mutter` shows the Sennheiser UID and
`rightOption`; dictate one sentence into a text field and see it inserted (proves
Accessibility); check `learned.json` mtime updates after a correction.

**No second machine to repeat this on** — see Decision 4. The MacBook Pro will install Mutter
natively later and never migrate anything.

---

### Phase 3 — The iCloud folder (recommended: manual move, not code)

`CloudDocs/Murmur/` is user-visible in Finder, so it gets renamed (Decision 2). Per Decision 4
there is currently exactly one writer, which removes most of the danger this phase originally
carried — but the remaining hazard is real and does not require a second machine.

**Do not implement this as an in-app migration**, even with one machine. A
"move `Murmur/` → `Mutter/` if absent" migration running against an eventually-consistent
filesystem collides with `syncedDirectoryWasJustCreated` — the guard that exists precisely
because "folder looks empty" and "folder hasn't downloaded yet" are indistinguishable. This
codebase has already documented that symlinking into iCloud silently diverges and that
conflating *evicted* with *missing* is the single most destructive mistake available here. A
hand-move into a folder that already exists is the live version of that same class of bug.

Instead, sequence it by hand, once:

1. Mutter quit on this Mac. (Per Decision 4 there is no second machine, so this is the whole
   coordination requirement — one writer, one rename.)
1b. **Confirm `CloudDocs/Mutter/` does not already exist.** `mv src dst` where
   `dst` is an existing directory does not rename — it moves `src` *inside* `dst`, giving you
   `CloudDocs/Mutter/Murmur/learned.json`. The app then sees an empty-looking `Mutter/`, takes
   the seed branch (`SyncedStore.swift:167-177`), and writes local state over a remote that is
   one directory deeper. Silent divergence, on both Macs. `CloudDocs/Mutter/` can already exist
   from a single `--selftest` run of a Phase-3 build, because `SyncMerge.runSelfTest():71`
   reads `AppPaths.syncedDirectory`, which *creates* the folder (`AppPaths.swift:35-42`).
   **So: no Phase-3 build may be run at all — not even `--selftest` — until after the move.**
   Use `mv -n` regardless.

2. On Mac A, rename the folder **in Finder, not with `mv`**. Finder wraps the operation in
   `NSFileCoordinator`, which lets `fileproviderd` issue a true server-side rename. A shell
   `mv` can present as delete-plus-create to the daemon, forcing a full re-upload and
   discarding sync metadata. (Reported by the review panel; I have not verified it against
   this specific macOS version — but Finder costs nothing and is the strictly safer default,
   so there is no reason to take the risk to find out.)
3. Verify the rename landed: `Mutter/` holds all three files fully downloaded (no
   `.learned.json.icloud` placeholders) and `Murmur/` is gone. With one machine there is no
   propagation to wait on — just confirm Finder shows the files as downloaded, not evicted.
   (Don't reach for `brctl`; it has been effectively neutered on recent macOS.)
4. Only then ship the code change: `AppPaths.syncedDirectory` → `Mutter`, and the
   `SyncMerge.runSelfTest()` assertion `lastPathComponent == "Murmur"` → `"Mutter"`.
5. Launch on both. Because the folder already exists, `syncedDirectoryWasJustCreated` stays
   false and the normal merge path runs — this is the main reason to move by hand rather than
   let the app create it.
6. **Ship a launch guard with the Phase 3 code**, because step 3 depends on Konrad's patience
   and nothing else. If `CloudDocs/Mutter/` is absent while `CloudDocs/Murmur/` is present,
   the rename has not propagated to this Mac yet — refuse to sync this launch and say so in
   the UI. Without it, launching Mac B too early makes the app create a second, empty
   `Mutter/`, and iCloud resolves the ensuing collision as `Mutter 2`. Do not `fatalError`
   here (the panel's suggestion) — a dictation app that refuses to launch because iCloud is
   slow is worse than the bug. Skip the sync, run the app, show an indicator.

`sync-base.json` is content-keyed and lives locally, so it survives the folder move untouched.
No re-seed, no false deletions.

7. **Deal with `CloudDocs/Murmur-deploy/`.** It exists (created 2026-07-23 17:08) and holds a
   `learned.json` and `vocabulary.json` — the hand-carry from the old MacBook Pro deploy
   process, now obsolete since sync shipped. It is not read by any code (nothing references
   `Murmur-deploy`), so it is inert — but leaving a folder named `Murmur-deploy` beside a
   `Mutter/` folder is exactly the ambiguity that gets mistakenly restored from in six months.
   Delete it or rename it, and write down which.

**Verification gate:** the two-machine round-trip proof is unavailable until the laptop exists,
so the gate for now is narrower and must be stated honestly as such — add a vocabulary term,
quit, confirm it appears in `CloudDocs/Mutter/vocabulary.json` on disk; delete it, quit,
confirm it is gone from that file and that `sync-base.json` tracked the deletion rather than
the entry resurrecting on next launch. That proves the merge still round-trips through the
renamed path. **It does not prove cross-machine sync** — that claim can only be re-established
when the MacBook Pro is set up, and it should be re-verified then rather than assumed to have
survived the rename.

---

### Phase 4 — Repo, remotes, and the outside world

1. Rename `kmichels/murmur` → `kmichels/mutter` on GitHub. GitHub redirects the old URL, and
   **PR #1 to upstream survives a fork rename** — but verify it, don't assume: reopen the PR
   page after renaming and confirm the head ref still resolves.
2. `git remote set-url fork https://github.com/kmichels/mutter.git`. Leave `origin`
   (upstream) alone.
3. **Do not touch the `fix/learning-guardrails` branch.** It carries the open upstream PR and
   is based on upstream's tree; renaming `Sources/Murmur` there would turn a clean PR into an
   unmergeable one. `main` also stays untouched.
4. Rename the working copy: `mv ~/projects/murmur ~/projects/mutter`. Nothing outside the repo
   references that path except Claude session artifacts (checked) — no scripts, no cron, no
   config.
5. Update the Apple Note "Deploy Murmur to the MacBook Pro", the auto-memory file
   `project_murmur.md` → `project_mutter.md`, and its `MEMORY.md` index line.

## Sequencing summary

```
Phase 1 (text only) ──► verify: selftest + codesign -dr ──► commit
Phase 2 ──► hand-mv Application Support FIRST, then bundle ID + code ──► verify: dictation
            inserts text, defaults read local.mutter shows the Sennheiser UID ──► commit
Phase 3 ──► confirm CloudDocs/Mutter absent ──► Finder-rename ──► THEN build the code
            change ──► verify: term round-trips on disk ──► commit
Phase 4 (repo rename, remotes, working copy, notes)
```

**The one ordering rule that matters:** in Phases 2 and 3, the filesystem move happens *before*
any build of the code that points at the new name. Both phases have a failure mode where
merely building-and-testing first creates the destination and strands the source.

With a single machine (Decision 4), all four phases are doable in one sitting. Phase 2 still
warrants its own commit and its own verification pass rather than being folded into Phase 1 —
it is where permissions and 3.3 GB of data move, and the failure mode is silent.

## Second opinions: what survived, what didn't

Reviewed by a 3-reviewer Gemini panel (Security / Architecture / Correctness) on the document,
plus direct re-reading of the code. The panel reviewed only the document, so several of its
code-level claims are speculative — each was checked against the source before being adopted.

**Adopted (real):**
- The `UserDefaults` unmasking bug — a fallback suite makes settings un-resettable. Fixed
  above by extending the existing one-time copy instead. The panel could not see that
  `migrateLegacyDefaults()` already exists and already does this correctly.
- `moveItem` is not idempotent. True, and already mitigated by the existing guard — which is
  now called out as load-bearing rather than incidental.
- Finder rather than `mv` for the iCloud folder. Unverified but free.
- A launch guard for the Phase 3 propagation window. Genuinely missing; added.
- Leave `.planning/` history alone; "Mutter" has no macOS collision. Both reviewers agreed
  with the draft.

**Rejected after checking the code:**
- *"Command injection via `tccutil`."* False. `AppDelegate.swift:179-186` already uses
  `Process()` with an argument array — no shell involved.
- *"Raw voice data exposed in world-readable temp files."* False.
  `AudioRecorder.swift:65` uses `FileManager.default.temporaryDirectory`, which is the
  per-user `$TMPDIR` at mode `0700`, not `/tmp`.
- *"Skip-message strings may be persisted and break decoding."* False. `history.json` entries
  are `{text, date, duration}` only — the skip messages are transient UI strings. The four
  matching self-test expectations (`LearnedStore.swift:657,660,664,672`) are in-code and
  change with the generator at line 41.
- *"Orphaned `~/Library/Caches/local.murmur`."* Does not exist; nor does any saved
  application state.

**Second reviewer (code-level, adversarial).** Read the source rather than the document and
found the blocker above — that the draft's own verification gate strands the data directory —
plus the `mv`-into-existing-directory nesting bug, the false "no dialogs" gate, the missing
`CloudDocs/Murmur-deploy/` folder, `cfprefsd` caching, LaunchServices re-registration, and the
Desktop-backup iCloud leak. All verified directly before adoption. It also confirmed several
draft claims: the 3.3 GB same-volume move is an O(1) APFS rename; a GitHub fork rename
preserves the open PR; `sync-base.json` really is content-keyed (`SyncedStore.swift:51-64`,
no paths anywhere in `SyncBase`); and not renaming the `WhisperFlow Dev` cert is correct,
since the cert leaf is half the TCC designated requirement.

**Corrected — the panel's headline blocker is overstated.** It claimed the sync engine treats
an empty local store as "delete everything remote", so a stray old-build launch would wipe
both Macs. The guard exists (`SyncedStore.swift:199-200, 289-290`: `localIsIntact` gated on a
non-empty base), but more importantly the feared case is safe by construction: deletions are
derived as *"present in base, absent locally"*, so a **fresh profile with an empty
`sync-base.json` cannot express a deletion at all** — it downloads. The old-build scenario is
therefore an annoyance, not a wipe.

The genuine hazard the panel missed is narrower and sharper: **`sync-base.json` and the store
files must never move separately.** A populated base beside emptied stores is the one shape
that reads as a legitimate mass deletion, and it is exactly what a partial or hand-curated
migration produces. Move the directory whole, or not at all.

## One thing the app itself has an opinion about

`history.json` contains the dictated sentence that started this task. Whisper transcribed
"Mutter" as **"matter"**. For an app whose own name is spoken aloud during use, that is worth
knowing before committing — it is also precisely what the vocabulary feature exists to fix
(add `Mutter` as a term, optionally with `matter` as a `misheard` correction), so it is a
one-entry problem rather than an objection.

## How this really goes wrong (the failure the draft plan caused itself)

A second reviewer read the code rather than the document and found that **the draft plan's own
verification gate triggers the failure.** Verified directly:

`AppPaths.supportDirectory` (`AppPaths.swift:4-20`) checks the migration guard at `:12-15`,
then calls `createDirectory(withIntermediateDirectories: true)` **unconditionally** at
`:17-18`. `SyncMerge.runSelfTest()` reads that property five times (`SyncMerge.swift:79, 84,
93, 95, 107`).

So the realistic sequence is: change `AppPaths` to `"Mutter"` in Phase 2 step 3, then do the
sensible thing and run `swift build && .build/release/Mutter --selftest` before building the
bundle. The selftest creates an empty `Application Support/Mutter/`. **Every test passes.**
The migration guard `!fileExists(directory)` is now permanently false. Launch the app and:

- `history.json`, `scratchpad.txt`, `dictionary.json` — gone (still in `Murmur/`, unreferenced)
- `whisper-models/` — 3.3 GB stranded, re-downloads from scratch
- `whisperModel` — also lost via Blocker 1's key list, so it downloads the *wrong* model
- `sync-base.json` — absent, so `loadBase()` returns empty (`SyncedStore.swift:117-122`)

The learned data itself survives: an empty base cannot express a deletion, so the union path
pulls it back from iCloud. But **every entry deleted on either Mac since the last sync
resurrects**, and the anti-mass-deletion guards at `SyncedStore.swift:199, :289, :368` are all
gated on `!base.X.isEmpty` — so an empty base silently disables the protection that would
catch the *next* problem. And `try?` at `AppPaths.swift:14` guarantees no log line explains any
of it.

This is why Phase 2 step 3 now says **move the directory by hand first**, widen the guard to
"absent or empty", and add logging. The in-code migration should be the safety net, not the
mechanism.

## The four ways this goes wrong

1. **Both builds coexist.** Old `Murmur.app` left in `build/` (or launched from Spotlight
   history) after Phase 2 → it finds no `Application Support/Murmur/`, creates an empty one,
   and on sync the three-way merge reads a local store that legitimately lost every entry.
   Deletions propagate to iCloud and the MacBook Pro. **Mitigation: delete the old bundle in
   Phase 1, before the data ever moves.**
2. **`CloudDocs/Mutter/` already exists when the Phase 3 `mv` runs**, so the folder nests
   instead of renaming and the app seeds over a remote one directory deeper. This no longer
   needs a second machine to happen — one `--selftest` run of a Phase-3 build creates the
   folder. **Mitigation: `mv -n`, an explicit existence check, and no Phase-3 build of any
   kind until after the move.**
3. **Signing certificate renamed for tidiness.** `WhisperFlow Dev` looks like leftover cruft
   and is the most tempting thing on this list to "clean up". Renaming it changes the
   signature and drops every TCC grant on both Macs, including ones Phase 2 just
   re-established. **Mitigation: an explicit comment in both scripts saying so.**
4. **Settings migrated with the stale key list.** `migrateLegacyDefaults()` copies four keys
   and the app now has nine. Extending the bundle ID without extending that list loses the
   Sennheiser `inputDeviceUID`, the Whisper model choice, and the voice profile — none of
   which announce themselves. Dictation still works; it just quietly gets worse.
   **Mitigation: the Phase 2 verification gate checks `defaults read local.mutter` explicitly
   rather than assuming.**

## Decisions (settled 2026-07-24)

1. **Bundle ID → `local.mutter`.** Confirmed.
2. **iCloud folder → rename to `Mutter/`.** Confirmed.
3. **`.planning/` docs stay as written**, as the historical record.
4. **The MacBook Pro has never had the app installed.** Confirmed by Konrad and corroborated
   by the filesystem: `CloudDocs/Murmur/{learned,snippets,vocabulary}.json` and the local
   `sync-base.json` all carry one identical mtime (2026-07-23 20:06), which is a single
   writer. The "store-less machine" in the sync notes was this Mac with its store moved
   aside, not a second machine.

### What (4) removes from the plan

This is the single biggest simplification available, and it collapses the riskiest parts:

- **Phase 2 no longer repeats on a second Mac.** One migration, one set of re-grants.
- **Phase 3 has exactly one writer**, so the both-quit gate, the propagation wait, and the
  split-brain race all disappear. The folder rename becomes an ordinary rename of a folder
  nothing else touches.
- **The laptop never migrates at all.** When it is eventually set up it installs Mutter from
  day one, finds `CloudDocs/Mutter/` already populated, and pulls everything down through the
  normal first-contact path. No legacy directory, no legacy defaults domain, no chained
  migration ever runs there.

Two things are still worth keeping despite (4), because they cost almost nothing and pay off
precisely when the laptop *does* arrive:

- **The `mv -n` precondition and the no-Phase-3-build-before-the-move rule.** These guard
  against `CloudDocs/Mutter/` already existing — which a single `--selftest` run creates, on
  this Mac, with no second machine required.
- **The launch guard** (`Mutter/` absent while `Murmur/` present → skip sync, show an
  indicator). It is dead code today and the correct behaviour the first time the laptop syncs.
