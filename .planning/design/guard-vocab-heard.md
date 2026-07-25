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

### 2026-07-25 - Implemented as designed, one deviation on test mechanics

`record()`, `learn()`, and the private `shouldStore()` all gained a
`taughtWords: Set<String>?` parameter, mirroring how `checker: WordChecker?`
is already threaded through. The key asymmetry: for `record()`/`shouldStore()`,
`nil` means "skip the guard" (the explicit path's contract - `add()` never
passes it, so Voice Training and Dictionary corrections are structurally
unaffected, not just unaffected by convention). For `learn()`, `nil` means
"use the production default" (`Set(VocabularyStore.words())`) - it resolves
that default once per call and always passes a non-nil set into `record()`,
because the automatic path must always guard, never skip.

`record()` unions the passed-in `taughtWords` with `learned.terms` (the
in-memory store already threaded through `record()`) before checking, so a
word the user taught via a prior correction guards itself immediately, even
before it lands in VocabularyStore.

Placement: the new `containsTaughtWord` check sits in `shouldStore()`
immediately after `isValidMapping` and before both `isReverseOfExistingMapping`
and the existing-rule bypass (`existing.contains(where: heard matches...) {
return true }`). This was the one place per-lines-of-code decision that
mattered: putting it before the bypass means the automatic path refuses to
*keep alive* a taught-word rule that already exists (a fresh diff reproducing
the pre-guardrail "Konrad" -> "laptop" mistake would otherwise match
`existing` and slip through as an "update"). Putting the check after
`isValidMapping` but unconditionally on both paths would have broken the
explicit-path requirement, so it's gated on `taughtWords` being non-nil
rather than being unconditional - the explicit path's escape hatch for
poisoned stores is untouched.

Matching logic: `containsTaughtWord` splits both `heard` and every
`taughtWords` entry into whitespace-separated words, trims non-alphanumeric
characters per word (matching `WordChecker.isOrdinaryWord`'s idiom), and
lowercases before comparing. A multi-word taught entry ("Apple Vision Pro")
therefore guards each word it contains, not just the phrase as a whole -
this is stricter than the design doc's literal wording ("any VocabularyStore
word") but was chosen deliberately: treating a taught phrase as a bag of
taught words is the safer direction for a guard whose entire purpose is
avoiding a repeat of the "Konrad" -> "laptop" class of bug.

**Deviation from the brief's literal test recipe**: the brief asked for a
test proving "the same mapping via explicit `add()` IS stored." `add()` has
no `checker:` parameter, so exercising it directly would depend on the real
`SystemWordChecker` (NSSpellChecker), which the file's own commentary
explicitly warns against for self-tests ("NSSpellChecker learns words per
user... tests must never depend on it"). Instead, the explicit-path
assertion calls `record()` directly without `taughtWords` - the exact shape
`add()` itself uses internally - with an injected `FixedWordChecker`,
keeping the test deterministic. The full automatic-path pipeline (`learn()`
with a temp `directoryOverride`) is still exercised end to end for the
"Konrad" -> "laptop" scenario, so the plumbing between `learn()` and
`record()` is proven, not just the guard logic in isolation.

Pre-existing condition, not introduced by this change: `LearnedStore.swift`
was already 1037 lines before this work (over the repo's 500-line advisory
threshold) and has no `.500-line-exempt` marker. The `verify-code.sh` hook
fired a WARNING (not a block) on every edit; the file is now ~1211 lines.
Splitting the self-test block out of this file is worth a follow-up but is
out of scope for AMUX-754.
