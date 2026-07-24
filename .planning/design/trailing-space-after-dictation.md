# Trailing space after dictation — Design Document

**Status**: Approved
**Created**: 2026-07-24
**Last Updated**: 2026-07-24

## Problem Statement

Dictated text lands at the cursor with no trailing space, so the cursor sits hard against the
final character. Dictating two sentences in a row produces `…done.Next sentence…` and Konrad
has to type a space by hand every single time. macOS's own dictation appends the space; this
is the behaviour people expect.

Cause: `TextFormatter.format()` ends with `.trimmingCharacters(in: .whitespacesAndNewlines)`
(`TextFormatter.swift:100`), which strips any trailing whitespace, and `TextInserter.insert`
pastes exactly the string it is handed.

## Requirements

### Functional

- After dictation is inserted, the cursor ends one space past the last character.
- Controlled by a Settings toggle, **default on**. Disabling is a deliberate act.
- Skip the space when the text already ends in whitespace or a newline — saying "new
  paragraph" leaves the cursor at the start of a fresh line, where a leading space is wrong.
- Never emit a lone space for empty text.
- Applies equally to the clipboard fallback path used when Accessibility is off, so behaviour
  does not silently change with permission state.

### Non-Functional

- **The trailing space must not reach stored data.** History, correction diffing and Voice
  Profile word counts all consume the formatted string; trailing whitespace in the learning
  corpus is how junk rules get taught. The space is an *insertion-time* concern only.

## Architecture

One pure function, called at the two insertion sites.

```swift
// TextFormatter.swift — text shaping, and where the trimming happens today
static func forInsertion(_ text: String, appendTrailingSpace: Bool) -> String
```

`AppDelegate` calls it only on the copies it pastes or puts on the clipboard, *after*
`history.add(formatted, …)` has already stored the clean string.

```
recognize → format → learned → snippets → style
                   ↓
        history.add(formatted)          ← clean, no trailing space
                   ↓
   forInsertion(formatted, …) → TextInserter.insert / clipboard fallback
```

### Settings

`Settings.appendTrailingSpace: Bool`, default **true**. `UserDefaults.bool(forKey:)` returns
`false` for an unset key, so the getter must check `object(forKey:) != nil` first — otherwise
the feature ships off for everyone. Added to `migratedKeys` so it survives future renames.

## Testing Strategy

Added to `TextFormatter.runSelfTest()`:

- [ ] appends a space to text ending in a full stop
- [ ] appends a space to text ending in a letter (no punctuation)
- [ ] does not double up when the text already ends in a space
- [ ] does not append after a trailing newline
- [ ] returns empty for empty input rather than a lone space
- [ ] appends nothing when the toggle is off
- [ ] leaves interior whitespace untouched

## Logging & Observability

None. A pure string function with no I/O and no failure mode; logging every insertion would
put dictated text in the system log, which is a privacy regression.

## Implementation Notes

### 2026-07-24 — built

- Placed the helper in `TextFormatter` rather than `TextInserter`: it is a text-shaping
  concern, `TextInserter` is clipboard mechanics, and `TextFormatter` already owns the
  trimming this compensates for and already has a self-test harness.
- Chose "skip when the text ends in any whitespace" over "skip only on newline" — the style
  rewrite and snippet expansion can both return trailing whitespace, and doubling spaces is
  as annoying as having none.

## Open Questions

None.
