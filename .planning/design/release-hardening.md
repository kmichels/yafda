# Release hardening: corrupt-store preservation + instance guard - Design Document

**Status**: Approved (prerequisites named in release-pipeline.md; Konrad
approved that design with defaults 2026-07-25)
**Created**: 2026-07-25

## Problem Statement

Two prerequisites before the first release build installs on a machine that
also runs dev builds (release-pipeline.md, key decisions 3 and 4):

1. `LearnedStore.load()` and `SnippetStore.load()` silently return an empty
   store when the file fails to decode, and the next save overwrites the
   file - a schema-divergent build (dev vs release now coexist) could wipe
   real data. `VocabularyStore` already preserves the unreadable file as
   `.corrupt` and never re-saves over it; the other two stores adopt the
   same idiom.
2. Dev (`local.mutter`) and release (`com.konradmichels.mutter`) builds are
   different bundle ids, so `LSMultipleInstancesProhibited` no longer
   prevents one of each running together - while both share the same data
   folder (keyed on app name) and sync files. Two live instances means two
   event monitors, double paste, and store races from a second process that
   `StoreOwner` cannot serialize. At launch, if another running app is also
   named Mutter under a different bundle id, alert and quit.

## Architecture

Files: `Sources/Mutter/LearnedStore.swift` and
`Sources/Mutter/SnippetStore.swift` (missing file still means fresh start;
present-but-undecodable moves to `<name>.corrupt` before returning empty,
mirroring `VocabularyStore.preserveCorruptFile`), new
`Sources/Mutter/InstanceGuard.swift` (pure `conflictingApp` decision over
running-app descriptors + a launch-time enforcement wrapper reading
`NSWorkspace.shared.runningApplications`, matching on executable name
"Mutter", excluding self, alerting and terminating on conflict),
`Sources/Mutter/AppDelegate.swift` (call the guard first in
`applicationDidFinishLaunching`, before sync triggers start),
`Sources/Mutter/Main.swift` (wire `SnippetStore.runSelfTest` and
`InstanceGuard.runSelfTest` into `--selftest`).

## Testing Strategy

Self-tests, red first:
- LearnedStore/SnippetStore: garbage bytes at the store path (temp
  directoryOverride) -> load returns empty, original preserved as
  `.corrupt`, a subsequent save leaves the `.corrupt` file untouched;
  missing file still loads empty WITHOUT creating a `.corrupt`.
- InstanceGuard.conflictingApp matrix: same name + different id -> conflict;
  same name + same id -> none (LSMultipleInstancesProhibited's job); other
  name -> none; self excluded even with a different id.
The alert/terminate path is UI-level, dogfood-verified.

## Implementation Notes (Living Section)

### 2026-07-25 - Implemented as designed

- Both stores gained the VocabularyStore preserve idiom via a
  `fileExists` guard first (missing file = fresh start, no backup) and a
  `preserveCorruptFile()` on decode failure, plus Loggers they previously
  lacked. Red run showed the exact three expected failures; green 183 PASS
  twice (flake check), up from 175.
- `InstanceGuard.conflictingApp` matches on executable name "Mutter" +
  different bundle id, self excluded; enforcement runs first in
  `applicationDidFinishLaunching`, before monitors, stores, or sync
  triggers. The alert/terminate path is dogfood-verified only, as designed.
- VERSION bumped to 0.9.1: 0.9.0 was notarized as the pipeline's shakedown
  but never installed; 0.9.1 is the first build that meets the release
  prerequisites and actually deploys.
