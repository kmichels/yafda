# Learning guard: never auto-learn a rule whose heard side is a taught word - Design Document

**Status**: Approved (Konrad, 2026-07-25, dogfood session "mutter fixes")
**Created**: 2026-07-25
**Ticket**: AMUX-754

## Problem Statement

A pre-guardrail auto-learned rule `"Konrad" -> "laptop"` globally rewrote
Konrad's own name; combined with vocabulary-biased recognition it turned
dictated "claude"/"cowork" into "laptop" for hours. The rule was learned from
a History edit diff: the user said "laptop", the biased recognizer wrote
"Konrad", the user fixed it, and the diff learner stored the fix as a global
rewrite of a word the user had explicitly taught. Rewriting a taught spelling
away is near-certainly a mislearned diff.

## Requirements

### Functional
- The automatic diff-learning path (`learn()` / `record()` as driven by
  History corrections) must refuse any mapping whose heard side matches,
  case-insensitively, a word the user explicitly taught: a `VocabularyStore`
  word or an existing `learned.terms` entry. Multi-word heard phrases are
  refused when any constituent word is a taught word.
- Voice Training's explicit `add(heard:intended:)` and Dictionary-page
  misheard entries remain allowed: those are deliberate user acts.
- The existing poisoned-store escape hatch (updating an existing rule for the
  same heard phrase) must keep working.
- A refused mapping still contributes its intended wording as a bias term
  (existing behavior).

### Non-Functional
- Guard must be injectable (taught-words provider passed in) so self-tests
  never read the user's real vocabulary.json or learned.json.

## Architecture

File: `Sources/Mutter/LearnedStore.swift`. The check joins the existing
guard chain in `isUsefulMapping`/`shouldStore`, applied only on the automatic
path (`learn()`), mirroring how `checker: WordChecker?` is threaded today.

## API Design

```swift
// record()/learn() gain a taughtWords parameter (defaulting to the real
// stores), checked alongside the WordChecker ordinary-speech guard.
static func learn(original: String, corrected: String,
                  checker: WordChecker? = nil,
                  taughtWords: Set<String>? = nil) -> LearnOutcome
```

Exact shape may follow the existing checker-injection idiom; the invariant is
what matters: automatic path refuses taught-word heard sides, explicit path
does not.

## Testing Strategy

Inline self-test cases in `LearnedStore.runSelfTest()`:
- Diff-learn "Konrad" -> "laptop" with "Konrad" taught: refused, lands in
  skipped outcome, "laptop" still appended as term.
- Multi-word heard containing a taught word: refused on the automatic path.
- Same mapping via explicit `add(heard:intended:)`: still stored.
- Escape hatch: existing rule for a heard phrase can still be updated.
- Heard side NOT taught: stored exactly as before (no regression).

## Logging & Observability

Refused mappings already surface in `LearnOutcome.skipped` (the fix toast);
no new logging.

## Implementation Notes (Living Section)

(fill in during implementation)
