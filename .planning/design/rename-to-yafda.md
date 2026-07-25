# Renaming Mutter → YAFDA — Strategy

**Status**: Approved (Konrad, 2026-07-25) — decisions: display/bundle/executable `YAFDA`;
first release **0.10.0**; laptop gets the release install in Phase 4 (dev-build arrangement
retires); GH repo rename with Phase 4.
**Created**: 2026-07-25
**Baseline**: `a6ee5cd` (v0.9.2), branch `local/main` lineage
**Prior art**: `.planning/design/rename-to-mutter.md` — read it first. This doc is a delta
against it, not a replacement. Everything that document says about identity anchors, TCC,
`cfprefsd`, LaunchServices, and iCloud eventual consistency still applies.

## Problem Statement

"Mutter" collides with **muttervoice.com** — a commercial Mac AI dictation app (hold-hotkey,
on-device private mode, GitHub org `MutterVoice`, shipping since 2026-06-09). Same name, same
platform, same category, same interaction model. The 2026-07-24 rename doc's "no macOS
collision" claim was wrong: the iTunes search was clean because muttervoice is not on the App
Store, and the web search missed it. Verified 2026-07-25 (App Store Mac+iOS via iTunes API,
Kagi web, GitHub, Homebrew).

The niche is picked clean — Murmur/Murmure, Utter, Sotto, PushToType, Leise, Whisper\* are all
competing dictation products. Konrad chose **YAFDA — Yet Another Fine Dictation App**. Only
existing use of the string is a Minecraft food mod; zero collision in software-for-Macs space.

The UI redesign (the app still visually resembles Wispr Flow) is **explicitly out of scope** —
it is a separate project that starts after this rename ships.

## Naming decisions (settled with Konrad, 2026-07-25)

| Surface | Value |
|---|---|
| Display name / bundle name / executable | `YAFDA` (all caps — it's an acronym) |
| Dev bundle id | `local.yafda` |
| Release bundle id | `com.konradmichels.yafda` |
| Data dir | `~/Library/Application Support/YAFDA/` |
| iCloud folder | `CloudDocs/YAFDA/` |
| GitHub repo | `kmichels/yafda` |
| Tagline (About window, README) | "Yet Another Fine Dictation App" |
| Logger subsystem / error domains | `local.yafda` |

`YAFDA` is already in the app Dictionary on Konrad's machines, so dictating the app's own
name works (the "Mutter → matter" lesson from the last rename, pre-applied).

**Open before implementation** (see Open Questions): DMG/volume casing, first release version
number, whether the laptop gets the release install as part of this.

## What changed since the Mutter rename — why this is a new doc

The last rename's hard lessons are now **code**, which removes the worst hazards, and the
world grew three new anchors, which add different ones.

### Hazards that are now handled by machinery (verify, don't re-solve)

1. **Local data-dir migration is a parameterized chain with the right guard.**
   `AppPaths.dataDirectoryNames = ["Mutter", "Murmur", "WhisperFlow"]`; the guard is
   *absent-or-empty* (a stray `--selftest` no longer strands the data dir), failures are
   logged, populated targets are never overwritten. The rename is: prepend `"YAFDA"`.
2. **The iCloud rename launch guard exists and is parameterized.**
   `AppPaths.syncedDirectory(in:name:legacyNames:)` returns nil (sync skips, app runs) when
   the new name is absent but a legacy name is present. `legacySyncedDirectoryNames`
   becomes `["Mutter", "Murmur"]`. The Mutter rename shipped this as dead code; **this rename
   is the first time it runs for real**, because there are now two live machines.
3. **Defaults migration is a versioned one-shot copy with a maintained key list.**
   `Settings.legacySuiteNames` + `migratedKeys` (12 keys) + `defaultsMigratedVersion`. The
   rename is: prepend the new legacy domains, bump `currentMigrationVersion` 2 → 3 so the
   copy re-runs into the new domain. **Trap:** `legacySuiteNames` is currently
   `["local.mutter", "local.murmur", "local.whisperflow"]` — it must gain **both** current
   domains, newest first: `["com.konradmichels.mutter", "local.mutter", ...]`. The release
   install on mac-mini-pro keeps its settings under `com.konradmichels.mutter`; forgetting it
   silently factory-resets that machine (including `inputDeviceUID`, the classic silent one).

### New anchors that did not exist last time

4. **The release pipeline** (`scripts/release.sh`, `scripts/deploy-mac.sh`,
   `scripts/release.entitlements`): release bundle id `com.konradmichels.mutter`, app/DMG/
   volume names, Info.plist strings, pgrep/quit-by-name logic in deploy. The Developer ID
   cert ("Developer ID Application", team 85QL287QYW) and the notary profile
   (`palomino-notary`) are **not** name-bearing — leave both alone. The dev signing cert
   `WhisperFlow Dev` stays, same as last time; the stale name is deliberate and load-bearing
   (cert leaf is half the TCC designated requirement).
5. **Two live machines, two identities.**
   - Laptop (Konrad-M5-MBP): runs the **dev** build daily (`local.mutter`, WhisperFlow Dev
     per-machine cert, `~/scripts/projects/mutter/build/Mutter.app`).
   - mac-mini-pro: runs the **release** install (`com.konradmichels.mutter`,
     `/Applications/Mutter.app`).
   Each machine re-grants TCC for its own identity after its bundle id changes. That is two
   independent re-grant sessions (Accessibility + Microphone + Files & Folders/iCloud), and
   both need Konrad at the keyboard.
6. **Sync is no longer launch-only.** `SyncScheduler` (AMUX-756) syncs on quit, wake,
   debounce, and hourly. "Both apps quit during the iCloud folder rename" is now a hard
   requirement, not a courtesy — a background hourly sync firing mid-rename is the new race.
7. **`InstanceGuard` matches on the executable name literal** (`executableName == "Mutter"`).
   It exists to stop dev/release coexistence under different bundle ids. It must become
   `"YAFDA"` in the same commit as the executable rename, or the guard goes blind exactly
   during the transition window it exists for. Transition note: a still-running old
   `Mutter.app` and a new `YAFDA.app` will NOT trigger the guard (different executable
   names) — the deploy step must quit the old app explicitly, which `deploy-mac.sh` already
   does by name (`pgrep -x Mutter`) and must do for **both** names during the transition.
8. **Three checkouts** (mac-mini-pro `~/projects/mutter` = dev line; bot-mini
   `~/scripts/projects/mutter`, remote `mmp`; laptop `~/scripts/projects/mutter`). Directory
   renames and remote-URL updates on all three, plus GitHub repo rename with redirect.
9. **GitHub Releases is the distribution channel** (v0.9.1, v0.9.2 live). Repo rename
   preserves releases and redirects old URLs. Old assets keep their `Mutter-*.dmg` names —
   historical record, leave them.

## Phases

Same controlling idea as last time: **separate the free renames from the anchored ones, ship
free first, filesystem moves before any build that points at the new name.** Phase numbering
mirrors the Mutter doc so the two read side by side.

### Phase 1 — Text only (source dir, strings, dev bundle *name*)

All of `rename-to-mutter.md` Phase 1, transposed, plus the new sites:

- `git mv Sources/Mutter Sources/YAFDA`; `Package.swift` (package/product/target/path).
- `git mv Resources/Mutter.icns Resources/YAFDA.icns`.
- `MutterMain` → `YAFDAMain`; CLI usage strings.
- All user-visible strings, incl. the VoiceOver `accessibilityDescription`, MainMenu items
  ("Quit YAFDA" etc. — MainMenu.swift is new since last time), and the About/tagline.
- `InstanceGuard`: executable-name literal + alert strings (see anchor 7).
- String-equality self-test assertions: the `LearnedStore` skip-message set, and
  `SyncMerge.runSelfTest()`'s `lastPathComponent` assertion. Grep for `"Mutter"` in test
  expectations rather than trusting this list — the suite grew to 172 tests since the last
  rename inventoried it.
- Logger subsystems and error domains → `local.yafda`.
- Temp-file prefixes (`mutter-*.caf`, selftest scratch names).
- `make_app.sh`: bundle/executable/icon names → YAFDA. **`CFBundleIdentifier` stays
  `local.mutter` in this phase** (Phase 2's job), same split as last time.
- README / LICENSE: fork-attribution line gains "formerly Mutter, Murmur"; upstream MIT
  attribution line stays verbatim.
- `.planning/**` history stays as written (this doc's own rule too).
- `rm -rf build/ .build/`, delete stale `build/Mutter.app`, rebuild, re-register
  LaunchServices (`lsregister -kill -r -domain local -domain user`).

**Gate:** `swift build && .build/debug/YAFDA --selftest` → 172 PASS 0 FAIL;
`./scripts/make_app.sh` produces signed `build/YAFDA.app`;
`codesign -dr - build/YAFDA.app` shows identifier `local.mutter` (unchanged, deliberately)
and the WhisperFlow Dev leaf; dictation works.

### Phase 2 — Bundle ids and the local data directory

Do on each machine separately, app quit, own commit.

1. Back up (not to Desktop — iCloud), both prefs domains per machine:
   dev `local.mutter.plist`, release `com.konradmichels.mutter.plist`, plus the bare
   executable-name domain `Mutter.plist` if present.
2. Code: prepend `"YAFDA"` to `dataDirectoryNames`; extend `legacySuiteNames` per anchor 3
   (both mutter domains, newest first — plus `local.yafda` at the head, covering a dev-YAFDA
   interlude before a machine's first release install); `make_app.sh` `CFBundleIdentifier` →
   `local.yafda`; `release.sh` `BUNDLE_ID` → `com.konradmichels.yafda`. **No migration
   version bump** — the marker lives in the new (empty) domain, so the one-shot copy runs
   there regardless; see Implementation Notes.
3. Per machine, **hand-`mv` first, build second**:
   `mv ~/Library/Application\ Support/Mutter ~/Library/Application\ Support/YAFDA` (laptop
   and mac-mini-pro; bot-mini has no real data dir, selftests self-heal via absent-or-empty).
   The in-code chain remains the safety net, not the mechanism.
4. `killall cfprefsd` after any defaults surgery; verify with `defaults read local.yafda`
   (laptop) / `defaults read com.konradmichels.yafda` (mac-mini-pro after Phase 4 deploy)
   showing `inputDeviceUID` and `hotkey` intact.
5. Re-grant TCC per machine, per identity (anchor 5). In the Accessibility pane, **remove the
   old Mutter row with the “−” button before adding YAFDA** — macOS caches the old bundle-id/
   path association, and a stale row alongside the new one is the known shape of
   “checkbox on, hotkey dead”. Old-id TCC *database* rows are still the rollback path —
   `tccutil reset ... local.mutter` only after the gate passes.
6. Re-run `lsregister -kill -r -domain local -domain system -domain user` at the end of the
   phase — the bundle **id** changed this time (Phase 1 only changed names/paths), and stale
   LaunchServices rows for `local.mutter` otherwise keep resolving to a bundle that no longer
   exists.

**Gate (per machine):** data dir contains all stores + `whisper-models/` (moved, not copied —
disk free unchanged); dictation inserts text; a correction updates `learned.json` mtime;
settings survived (mic UID, hotkey, model).

### Phase 3 — The iCloud folder (first live two-machine run)

The hand-rename rule from last time, now with real coordination:

1. **Quit the app on BOTH Macs** and verify (`pgrep -x Mutter` / `-x YAFDA` on each). This
   now matters because of SyncScheduler's background syncs (anchor 6). Quit also means
   *stays* quit: if `launchAtLogin` is enabled on either Mac, disable it (or don't log
   in/reboot) for the duration of the phase — a login-item relaunch mid-rename is the same
   race as a background sync.
2. Confirm `CloudDocs/YAFDA/` does not already exist. (The launch guard makes a premature
   new-build launch skip sync rather than fork the folder, but do not lean on it — ordering
   stays: move first, build second.)
3. Finder-rename `Mutter` → `YAFDA` on ONE Mac (Finder, not `mv` — NSFileCoordinator
   server-side rename).
4. **Wait for propagation to the second Mac** and verify there with positive checks, not a
   Finder glance (`brctl` is not an option — effectively neutered on recent macOS, per the
   Mutter rename's review round). On Mac 2, all four must hold:
   - `test -d ~/Library/Mobile\ Documents/com~apple~CloudDocs/YAFDA` → exists
   - `test -e .../CloudDocs/Mutter` → gone
   - `find .../CloudDocs/YAFDA -name '*.icloud'` → empty (no undownloaded placeholders)
   - **content proof**: `shasum` all three JSON files on both Macs and compare — reading the
     files forces materialization, and matching hashes are the only claim that actually
     means "propagated". If hashes differ, wait and re-check; do not proceed on "looks
     synced".
   This step did not exist last time; it is the whole reason the launch guard was built.
5. Ship the code: `syncedDirectoryName = "YAFDA"`, `legacySyncedDirectoryNames =
   ["Mutter", "Murmur"]`.
6. Launch on both; folder pre-exists on both, so `syncedDirectoryWasJustCreated` stays false
   and the normal merge runs.

**Gate:** vocabulary term round-trips machine-to-machine: add on laptop, quit, appears in
`CloudDocs/YAFDA/vocabulary.json`, arrives on mac-mini-pro next launch; delete it, confirm
it stays deleted (no resurrection = `sync-base.json` on both machines survived intact). This
is the cross-machine proof the Mutter rename explicitly deferred — it is available now, so
it is the gate.

### Phase 4 — Release pipeline, repo, outside world

1. `release.sh` / `deploy-mac.sh` / `release.entitlements`: remaining name sites (app/DMG/
   volume/Info.plist strings, pgrep names — transition: quit-by-name must handle `Mutter`
   AND `YAFDA` for the first deploy, then the `Mutter` arm can be dropped).
2. Cut the first YAFDA release (version per Open Questions; `VERSION` file), notarize,
   staple, `spctl` gate — the pipeline is name-parameterized enough that this is mostly a
   re-run.
3. Deploy to mac-mini-pro (`deploy-mac.sh mac-mini-pro`): old Mutter.app quit + removed, new
   YAFDA.app in `/Applications`, **TCC re-grant session for `com.konradmichels.yafda`**
   (needs Konrad).
4. (If Open Question 3 says yes) first release install on the laptop — folds its pending
   release-install re-grant and this rename's re-grant into one session.
5. GitHub: rename `kmichels/mutter` → `kmichels/yafda`; update remote URLs on all three
   checkouts; verify releases page redirects. Rename working copies
   (`~/projects/mutter` → `~/projects/yafda` on mac-mini-pro, ditto the two
   `~/scripts/projects/mutter` clones) and the `mmp` remote URL on bot-mini/laptop.
6. Bookkeeping: memory file `project_mutter.md` → `project_yafda.md` + MEMORY.md index line;
   amux board tags `project:mutter` → `project:yafda` on open tickets; Apple Notes deploy
   note.
7. Check `CloudDocs/Murmur-deploy/` — flagged for deletion in the last rename; verify it was
   actually dealt with, deal with it now if not. While at it, grep all three machines for
   external automation referencing the old names/paths (`/Applications/Mutter.app`,
   `projects/mutter`) — crontabs, LaunchAgents, shell aliases — before declaring Phase 4
   done.
8. Upstream lineage: `fix/learning-guardrails` and upstream PR #1 (janisbelozerovs-dev/
   murmur) — same rule as last time, **do not touch**; verify the PR still resolves after
   the repo rename (it survived the murmur→mutter rename; expected to survive again, but
   verify, don't assume).

## Sequencing

```
Phase 1 (text)      ─► gate: selftest + codesign -dr ─► commit
Phase 2 (ids/data)  ─► per machine: hand-mv FIRST ─► gate: dictation + defaults ─► commit
Phase 3 (iCloud)    ─► both quit ─► Finder rename ─► propagation VERIFIED on Mac 2
                      ─► THEN build ─► gate: cross-machine term round-trip ─► commit
Phase 4 (release/repo) ─► notarized YAFDA release deployed ─► repo renamed ─► bookkeeping
```

Phases 1–2 can run on bot-mini + one machine in a sitting; Phase 3 needs both Macs awake and
Konrad present; Phase 4's re-grants need Konrad at each machine. Realistically: one session
for 1–2, one coordinated session for 3–4.

## The ways this specific rename goes wrong

1. **The release install's settings domain is forgotten** (`com.konradmichels.mutter` missing
   from `legacySuiteNames`) → mac-mini-pro silently factory-resets. Mitigation: anchor 3's
   list + the Phase 2 gate reads the migrated domain explicitly.
2. **A background sync fires mid-folder-rename** (SyncScheduler is new since last time) →
   the app recreates `Mutter/` next to `YAFDA/` or seeds into the wrong folder. Mitigation:
   both-quit is a verified precondition, not a request.
3. **InstanceGuard renamed out of sync with the executable** → dev/release coexistence guard
   blind during the exact window two differently-named apps exist. Mitigation: same commit;
   deploy script quits both names.
4. **Someone "cleans up" WhisperFlow Dev** — still no. Three renames later the comment in
   `make_app.sh` stays.

## Implementation Notes (living)

### 2026-07-25 — Phases 1–4 code landed on `design/rename-to-yafda` (cab74aa..ec6f3fb)

- Suite is **186** tests now, not the doc's stale "172"; gate held at 0 FAIL throughout.
- **Migration version stays 2** (doc said bump to 3): the marker lives in the *new* defaults
  domain, which starts at 0, so the one-shot copy runs after any bundle-id change without a
  bump. Bumping would only force a re-run inside an unchanged domain — not this situation.
- `SyncMerge.runSelfTest`'s folder-name assertion now compares against
  `AppPaths.syncedDirectoryName` instead of a hardcoded literal — stays correct through
  every phase and every future rename.
- `deploy-mac.sh` quits/removes **both** `Mutter` and `YAFDA` during the transition (drop
  the Mutter arm once no machine runs a Mutter build).
- **Launch guard verified live on bot-mini**: a YAFDA build's selftest with
  `CloudDocs/Mutter` present and `YAFDA` absent yielded `syncedDirectory = nil` and created
  no folder. (Cosmetic: the selftest's nil caption says "iCloud Drive unavailable", which
  conflates the legacy-guard skip with true unavailability — fine to leave.)
- Phase 3+4 code is COMMITTED but deploy is gated: no machine may build+launch this branch
  until the CloudDocs folder rename lands (bot-mini selftests are safe, the guard covers
  them).

## Review log (Gemini, 2026-07-25)

**Round 1 — adopted:** positive iCloud-propagation checks in Phase 3 step 4 (content hashes,
not Finder); explicit removal of the old Accessibility row before adding the new one;
`lsregister` rebuild at the end of Phase 2 (bundle *id* changed, not just names).

**Round 2 — rejected after checking the source** (all four findings assume a sandboxed
CloudKit/Sparkle app, which this is not):
- *"iCloud container entitlement mismatch."* False. `release.entitlements` contains exactly
  one entitlement (`com.apple.security.device.audio-input`). Sync is a plain unsandboxed
  path under `CloudDocs/` — no ubiquity container, by design (documented in both the
  entitlements file and `AppPaths.swift`).
- *"Keychain access loss."* False. Zero keychain/`SecItem` usage anywhere in `Sources/`.
- *"New provisioning profile required."* False. Developer ID app with no restricted
  entitlements; v0.9.1/0.9.2 notarized Accepted with none.
- *"Sparkle update feed breaks."* False. No Sparkle; distribution is GH Releases +
  `deploy-mac.sh`. (The underlying point — old app must be quit/removed on update — is
  already handled by the deploy script and anchor 7's both-names rule.)

## Out of scope

- UI redesign (separate project, starts after this ships).
- App Store anything (`distribution.md` closed it).
- Upstream PR #1 and the `fix/learning-guardrails` branch (frozen, upstream's tree).

## Open Questions

- [ ] 1. DMG / volume casing: `YAFDA-0.x.dmg` volume "YAFDA" (assumed) — confirm.
- [ ] 2. First YAFDA release version: continue 0.9.x (0.9.3) or mark the rename with 0.10.0?
      (Recommend 0.10.0 — a rename is exactly what a minor bump is for.)
- [ ] 3. Does the laptop get the release install in Phase 4 (retiring the daily dev-build
      arrangement), folding two pending re-grant sessions into one? (Recommend yes.)
- [ ] 4. GitHub repo rename timing: with Phase 4 (assumed) or immediately? Redirects make
      early harmless, but doing it with Phase 4 keeps release assets and repo name moving
      together.
