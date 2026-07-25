# Voice Training: visible trained-words list - Design Document

**Status**: Approved (Konrad, 2026-07-25, dogfood session "mutter fixes")
**Created**: 2026-07-25
**Ticket**: AMUX-753

## Problem Statement

Training a word that the recognizer hears correctly (or whose mapping the
guards reject) stores it only in `learned.terms`. The Voice Training page's
one real list shows `corrections`; terms surface as a comma-joined
"Vocabulary hints" caption. On 2026-07-25 Konrad trained "cowork", the toast
claimed success, and the word appeared in no list he could find. The data was
saved; the UI hid it.

## Requirements

### Functional
- The Training page shows a "Trained words" list of `learned.terms`, newest
  first, each row with a delete button.
- The list refreshes after every training attempt and on page appear.
- Deleting a term removes it from `learned.terms` (delete is best-effort
  local: sync merges terms union-style, so another Mac may re-contribute it;
  that limitation is out of scope here and noted in the UI copy only if
  trivial).
- The "Vocabulary hints" caption is replaced by the list.

### Non-Functional
- No change to file formats. No new stores.
- Store mutation logic lives in `LearnedStore` so the self-test can drive it.

## Architecture

Files: `Sources/Mutter/LearnedStore.swift` (add `removeTerm(_:)`, keep all
existing semantics), `Sources/Mutter/MainView.swift` (TrainingPage list UI).

## API Design

```swift
extension LearnedStore {
    /// Removes a term case-insensitively. Returns whether anything changed.
    @discardableResult
    static func removeTerm(_ term: String) -> Bool
}
```

## Testing Strategy

Inline self-test cases in `LearnedStore.runSelfTest()` (the repo's test
suite, run via `Mutter --selftest`):
- addTerm then removeTerm round-trip (case-insensitive removal).
- removeTerm of an absent term returns false and changes nothing.
- terms ordering preserved for the UI (newest appended last; UI reverses).

UI list itself is covered by the existing e2e/dogfood loop
(`Sources/Mutter/.tdd-optional` documents the inline-suite convention).

## Logging & Observability

No new I/O paths; store writes reuse existing save().

## Implementation Notes (Living Section)

(fill in during implementation)
