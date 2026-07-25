# History observability: show which corrections fired - Design Document

**Status**: Approved (Konrad, 2026-07-25, dogfood session "mutter fixes")
**Created**: 2026-07-25
**Ticket**: AMUX-755

## Problem Statement

`LearnedStore.apply` rewrites are invisible: the transcript arrives wrong
with no trace of which rule fired. The 2026-07-25 "laptop" substitution took
hours to diagnose for exactly this reason. Each dictation should record which
corrections actually matched so a poisoned rule is spotted at a glance.

## Requirements

### Functional
- `LearnedStore.apply` gains a variant returning which corrections matched
  and how many occurrences each replaced.
- The dictation pipeline (`AppDelegate.stopAndTranscribe`) threads the result
  into the saved `HistoryEntry`.
- The History page shows an applied-corrections line on entries that had any,
  e.g. `Konrad -> laptop x2`, styled as secondary text.
- Older history entries without the field decode unchanged (optional field,
  no migration).

### Non-Functional
- No behavior change to the rewriting itself; the plain `apply(in:)` result
  text must remain byte-identical for identical inputs.
- History file format stays JSON-compatible both directions (an entry written
  by the new build must not break an older build's decoder: use an optional
  field, tolerated by JSONDecoder in both).

## Architecture

Files: `Sources/Mutter/LearnedStore.swift` (apply variant),
`Sources/Mutter/HistoryStore.swift` (`HistoryEntry.appliedCorrections`
optional field, plus a `runSelfTest` for encode/decode round-trip),
`Sources/Mutter/AppDelegate.swift` (thread results through
`stopAndTranscribe`), `Sources/Mutter/MainView.swift` (History row line),
`Sources/Mutter/Main.swift` (wire the new HistoryStore self-test into
`--selftest`).

## API Design

```swift
struct AppliedCorrection: Codable, Equatable {
    var heard: String
    var intended: String
    var count: Int
}

// New: same single-pass walk, also reporting matches.
static func applyReportingMatches(
    in text: String, using corrections: [LearnedCorrection])
    -> (text: String, applied: [AppliedCorrection])
```

`apply(in:using:)` becomes a thin wrapper over the reporting variant so the
single-pass logic exists once.

## Testing Strategy

Inline self-test cases:
- Reporting variant: matched rules and counts correct for multi-occurrence
  and overlapping-rule inputs; text identical to the plain variant's output.
- No matches: empty applied list.
- HistoryStore: entry with and without `appliedCorrections` encodes/decodes
  round-trip; a legacy JSON blob without the field decodes.

## Logging & Observability

This feature IS the observability. No extra logging.

## Implementation Notes (Living Section)

### 2026-07-25 - Implemented as designed

- `LearnedStore.applyReportingMatches(in:using:)` holds the single-pass walk;
  `apply(in:using:)` is now a one-line wrapper (`applyReportingMatches(...).text`).
  Matches are keyed by rule `id` and reported in first-fired order, counting
  every occurrence per rule. The existing `apply/...` self-tests (locking
  output byte-for-byte) pass unchanged, confirming the wrapper is behavior-
  preserving.
- `HistoryEntry.appliedCorrections: [AppliedCorrection]? = nil` uses Swift's
  synthesized `Codable` (no custom `CodingKeys`) - an `Optional` stored
  property is decoded with `decodeIfPresent` automatically, so a legacy
  history.json with no key for it decodes to `nil` with no migration code.
  `HistoryStore.runSelfTest()` exercises this purely via
  `JSONEncoder`/`JSONDecoder` on `HistoryEntry` in memory - no file I/O, so
  no temp-directory scaffolding was needed for it.
- Confirmed `history.json` is not synced: `SyncedStore.swift` only syncs
  `learned.json`, `vocabulary.json`, `snippets.json` (`grep -n history`
  across `SyncedStore.swift`/`SyncMerge.swift`/`AppPaths.swift` had zero
  hits). No merge-key work was needed for this feature.
- `AppDelegate.stopAndTranscribe` now calls `applyReportingMatches` instead
  of `apply(in:)` and threads the non-empty result into `history.add(...,
  appliedCorrections:)`; empty results pass `nil` so old and new entries stay
  indistinguishable in storage when nothing fired.
- History row caption format settled on `"heard" → "intended" ×N` (curly
  quotes + →, matching `LearnOutcome.summary`; `×N` matching the Training
  page's `timesSeen` display) rather than the ticket's plain-ASCII example -
  the ticket asked to follow the file's existing typography conventions,
  and this is the established one for describing a correction as text.
- TDD note: the `HistoryEntry` round-trip has no implementation to get wrong
  once the field exists (Swift's Codable synthesis handles it for free), so
  RED was produced by temporarily adding an explicit `CodingKeys` enum that
  omitted the new key - a real class of regression (a hand-maintained key
  list forgetting a new field) - then removed for GREEN.
