# Vocabulary Dictionary + Context Disambiguation - Design Document

**Status**: Approved
**Created**: 2026-07-23
**Last Updated**: 2026-07-23
**Fork roadmap**: capabilities #2 (pre-emptive dictionary) + #3 (context-aware pass), merged

## Problem Statement

Murmur's dictation now records from the right microphone (see
`microphone-selector.md`), which removed the dropped/garbled-words failure. What
remains is homophone error: "Does the word **Phocus** come out right?" is
recognised as "Does the word **focus** come out right?". "Phocus" and "focus"
are acoustically identical; no microphone or acoustic model fixes this.

Wispr Flow solves it with a **dictionary of vocabulary words** the user adds
pre-emptively (their dictionary already contains `Phocus`, `Hasselblad`,
`Konrad`, `HNNR`). A word in the dictionary biases recognition toward that
spelling, and Wispr resolves collisions with the common word by sentence
context.

Murmur today has only a `spoken -> replacement` "Dictionary" - a blind
find-and-replace. That mode cannot handle `focus/Phocus`: replacing every
"focus" with "Phocus" would corrupt every genuine use of "focus". There is no
way to add a bare vocabulary word, and no context awareness.

The recognition engine already supports vocabulary biasing
(`LearnedStore.biasTerms()` feeds a term list into Whisper's decoder prompt and
Apple's contextual strings), but nothing lets the user add bare words to it, and
bias alone is context-blind.

## Requirements

### Functional

- A unified Dictionary page matching Wispr's model: primarily a list of
  **vocabulary words**, with **"Correct a misspelling"** as an opt-in per entry.
- Adding a bare vocabulary word biases recognition toward that spelling (no
  replacement).
- A "Correct a misspelling" entry additionally performs a hard
  `misheard -> word` replacement, for terms the user always wants swapped.
- A **context-aware disambiguation pass** resolves homophone collisions that
  bias alone cannot: "send it to focus" -> "send it to Phocus", while "I need to
  focus" is left unchanged.
- The disambiguation pass runs automatically whenever the vocabulary is
  non-empty and Apple Intelligence is available; it is skipped entirely when the
  vocabulary is empty (zero added latency for users who never add words).
- Existing `dictionary.json` replacement entries migrate into the new store as
  corrections, once, transparently.

### Non-Functional

- No new third-party dependencies. Reuse the existing FoundationModels path
  (`SystemLanguageModel` / `LanguageModelSession`) already used by
  `RewriteEngine` for Styles/Transforms.
- The disambiguation pass is **always optional polish**. Any failure (Apple
  Intelligence unavailable, model throws, output fails validation) falls back to
  the raw transcript. A keypress must always produce text, exactly as today's
  Whisper -> Apple fallback guarantees.
- **Mechanical validation of LLM output, not prompt trust.** Prompt compliance
  is probabilistic; the guard is deterministic. The model's output is used only
  if it preserves the transcript's word structure and only substitutes *toward*
  vocabulary terms. Otherwise the original transcript is kept.
- Tests extend the existing `runSelfTest() -> Bool` convention wired to
  `--selftest`. Swift 6.2, language mode v5.
- Added latency budget for the LLM pass: a few hundred ms to ~1s on-device,
  accepted, and only incurred when the vocabulary is non-empty.

## Architecture

### Components

**`VocabularyStore.swift`** (new, `Sources/Murmur/VocabularyStore.swift`)

The unified store behind the Dictionary page. Pure data + JSON persistence, no
UI, no model calls.

- Entry model: `struct VocabularyEntry: Codable, Identifiable, Equatable`
  - `word: String` - the vocabulary term, always present.
  - `misheard: String?` - set only for "Correct a misspelling" entries; the
    form the recogniser produces that should be hard-replaced with `word`.
- Storage: `vocabulary.json` in `~/Library/Application Support/Murmur/`, an array
  of entries.
- API:
  - `static func load() -> [VocabularyEntry]`
  - `static func save(_ entries: [VocabularyEntry])`
  - `static func words() -> [String]` - every `word`, for bias.
  - `static func corrections() -> [(misheard: String, word: String)]` - entries
    with a non-empty `misheard`, for hard replacement.
  - `static func add`, `remove`, `update` helpers as needed by the UI.
- **Migration:** on first `load()`, if `vocabulary.json` is absent but a legacy
  `dictionary.json` exists, convert each `spoken -> replacement` pair into
  `VocabularyEntry(word: replacement, misheard: spoken)`, write `vocabulary.json`,
  and leave `dictionary.json` in place (untouched, for safety/rollback).

**Bias wiring** (modify `LearnedStore.biasTerms()`)

Add `VocabularyStore.words()` to the assembled term list, deduplicated by the
existing `insert` helper. Vocabulary words become the primary, user-curated
source of bias, alongside learned terms, learned-correction intendeds, and
snippet triggers.

**`VocabularyDisambiguator.swift`** (new,
`Sources/Murmur/VocabularyDisambiguator.swift`)

The context-aware pass - the second line of defense after bias.

- Availability mirrors `RewriteEngine`: gated on
  `SystemLanguageModel.default.availability == .available`.
- `func disambiguate(_ transcript: String, vocabulary: [String]) async -> String`
  - Returns the original transcript unchanged if `vocabulary` is empty, the
    model is unavailable, the call throws, or the output fails the guard.
  - Otherwise sends transcript + vocabulary to a `LanguageModelSession` with a
    tightly-scoped instruction: replace only words that, in sentence context,
    are clearly one of the supplied custom terms; change nothing else - no
    rephrasing, no additions, no punctuation edits.
- **Guard (pure, testable in isolation):**
  `static func accept(original: String, candidate: String, vocabulary: [String]) -> Bool`
  - Accepts the candidate only when every difference from the original is a
    **whole-word substitution toward a vocabulary term** (case-insensitive): a
    changed word in the candidate must be a vocabulary term, and the surrounding
    words must be unchanged. The no-change case is accepted. Anything else - a
    rephrase, an insertion or deletion, a substitution to a non-vocabulary word,
    reordering - is rejected.
  - **v1 scope: 1:1 whole-word substitution.** A run of original words collapsing
    to a single multi-word-derived vocab term ("base ten" -> "Baseten") is NOT
    accepted by v1 and falls back to the raw transcript (safe, just unfixed).
    See Open Questions.
  - `disambiguate` calls `accept`; on `false` it returns `original`.

**`DictionaryPage` rewrite** (modify `MainView.swift`)

Wispr-style unified UI:

- A list of vocabulary words. Correction entries carry a small badge (e.g.
  `focus -> Phocus`).
- "Add new" reveals a single **word** field plus a **"Correct a misspelling"**
  toggle (off by default). Toggling on reveals the **misheard form** field.
- Add / edit / delete write through `VocabularyStore`.

### Data Flow

```
recognize(fileAt:)                       // raw transcript, biased by words()
  -> VocabularyDisambiguator.disambiguate // LLM, vocab-aware, guarded (skipped if empty)
  -> existing cleanup / formatting (TextFormatter)
  -> hard corrections (misheard -> word from VocabularyStore.corrections())
  -> TextInserter (clipboard + Cmd V)
```

Disambiguation runs **before** cleanup so the model sees natural sentences (user
decision, 2026-07-23).

### Error Handling

| Condition | Behaviour |
|---|---|
| Vocabulary empty | Skip the LLM pass entirely. No added latency. |
| Apple Intelligence unavailable | Skip the pass; return the raw transcript. |
| `LanguageModelSession` throws | Catch, log, return the raw transcript. |
| Guard rejects the model output | Return the raw transcript. Never emit unvalidated model text. |
| Legacy `dictionary.json`, no `vocabulary.json` | Migrate to entries with `misheard` set; keep the legacy file. |

## API Design

```swift
struct VocabularyEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var word: String
    var misheard: String?   // nil => bare vocabulary word; set => correction
}

enum VocabularyStore {
    static func load() -> [VocabularyEntry]
    static func save(_ entries: [VocabularyEntry])
    static func words() -> [String]
    static func corrections() -> [(misheard: String, word: String)]
}

struct VocabularyDisambiguator {
    var isAvailable: Bool
    func disambiguate(_ transcript: String, vocabulary: [String]) async -> String
    static func accept(original: String, candidate: String,
                       vocabulary: [String]) -> Bool
}
```

## Testing Strategy

Extends `runSelfTest()`.

### Unit Tests
- [ ] `VocabularyStore` round-trips words and corrections through JSON.
- [ ] `words()` returns every entry's word; `corrections()` returns only entries
      with a non-empty `misheard`.
- [ ] Migration: a synthetic legacy `dictionary.json` produces the right
      `VocabularyEntry(word:, misheard:)` set, and `vocabulary.json` becomes the
      source of truth.
- [ ] `biasTerms()` includes vocabulary words.

### Disambiguation guard (the load-bearing test - model call is not headless-testable)
- [ ] `accept` accepts a clean single substitution toward a vocab term
      ("send it to focus" -> "send it to Phocus", vocab ["Phocus"]).
- [ ] `accept` accepts the no-change case (identical strings).
- [ ] `accept` rejects a rephrase (word count / structure changed).
- [ ] `accept` rejects an insertion or deletion.
- [ ] `accept` rejects a substitution to a word that is not in the vocabulary.
- [ ] `accept` is case-insensitive on the vocab match.

### Edge Cases
- [ ] Empty vocabulary: `disambiguate` returns the input unchanged without a
      model call.
- [ ] Model unavailable: returns the input unchanged.

## Logging & Observability

- `VocabularyDisambiguator` logs (via the app's existing logging) when it skips
  (empty vocab / unavailable), when the model throws, and when the guard rejects
  output - with enough context (original vs candidate) to diagnose a bad
  rejection, never the audio.
- `VocabularyStore` logs migration (count of legacy entries converted).

## Implementation Notes (Living Section)

_Empty - populated during implementation._

## Open Questions / Deliberate Exclusions

- **No sync in this feature.** `vocabulary.json` folds into the paused iCloud
  sync plan (`.planning/plans/2026-07-21-icloud-sync.md`) alongside
  `dictionary.json` when sync is built. Noted so the sync file-set includes it.
- **No phonetic collision index.** The disambiguation pass runs whenever the
  vocabulary is non-empty rather than only on detected collisions; a phonetic
  index was considered and rejected as complexity the LLM pass makes unnecessary
  (the transcript contains the *wrong* word, so a string-match collision check
  would miss the very cases that matter).
- **No per-app vocabulary.** Vocabulary is global, like the recogniser.
- **Multi-word / re-segmentation collisions deferred.** v1 disambiguation
  handles 1:1 whole-word homophone substitution (focus -> Phocus). Collisions
  that change word count ("base ten" -> "Baseten", "so ren" -> "Søren") are the
  harder re-segmentation case the learning guardrails already grapple with; they
  fall back to the raw transcript in v1 rather than risk an under-constrained
  guard. Revisit once 1:1 is proven in daily use.
