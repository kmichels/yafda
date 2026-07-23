# Vocabulary Dictionary + Context Disambiguation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Murmur a Wispr-style dictionary where the user adds vocabulary words that bias recognition, plus an on-device context pass that resolves homophone collisions (focus vs Phocus) the bias alone can't.

**Architecture:** A new `VocabularyStore` (unified word list + optional per-word "misheard" correction) replaces the old replacement-only dictionary and migrates it in. Its words feed the recogniser's existing bias prompt; its corrections feed the existing `TextFormatter` replacement pass. A new `VocabularyDisambiguator` reuses the FoundationModels path (as `RewriteEngine` does) to substitute homophones toward vocabulary terms, gated by a pure structural guard that discards any model output that does more than 1:1 whole-word substitution toward a vocab term.

**Tech Stack:** Swift 6.2 (language mode v5), SwiftPM, FoundationModels (Apple Intelligence, system framework), SwiftUI. No new dependencies.

**Spec:** `.planning/design/vocabulary-dictionary-and-context-disambiguation.md`

## Global Constraints

- Branch `local/main` (the fork's development line).
- Swift 6.2, language mode v5. No new third-party dependencies.
- The disambiguation pass is **always optional polish**: any failure (empty vocabulary, Apple Intelligence unavailable, model throws, guard rejects) returns the raw transcript unchanged. A keypress must always produce text.
- **Validate model output mechanically, never trust the prompt.** The `accept` guard is the enforcement point; the prompt is only a hint.
- The guard is a **structural** safety net (no rephrasing/insertion/corruption), NOT a semantic judge. Whether "focus" in *this* sentence really means "Phocus" is the model's context call; the guard only ensures the model didn't do anything other than substitute toward a vocab term.
- v1 disambiguation is **1:1 whole-word substitution only**. Word-count-changing collisions ("base ten" -> "Baseten") fall back to the raw transcript. Likewise, a word with internal punctuation the guard does not strip (a possessive like "Phocus's") only matches if that exact form is a vocabulary term; otherwise it falls back — safe, just unfixed. Acceptable for v1.
- Persist to `vocabulary.json` in `AppPaths.supportDirectory`. Leave the legacy `dictionary.json` in place after migration (rollback safety).
- Tests extend the existing `runSelfTest() -> Bool` convention wired to `--selftest`.
- Build and test with: `swift build -c release && ./.build/release/Murmur --selftest`
- **Baseline before this plan: 67 PASS / 0 FAIL.** The four `LearnedStore` `diff(...)` invariants must stay green throughout.
- **Testability rule (from the guardrails work):** pure transforms and the guard are unit-tested; I/O and the model call are thin wrappers around them. The on-device model is not headless-testable, so the guard around it carries the test weight.

## File Structure

| File | Responsibility |
|---|---|
| `Sources/Murmur/VocabularyStore.swift` (create) | Entry model, JSON persistence, pure transforms (`words`/`corrections`/`correctionMap`/`migrate`), one-time migration from `dictionary.json`. |
| `Sources/Murmur/VocabularyDisambiguator.swift` (create) | On-device context pass + the pure `accept` guard. |
| `Sources/Murmur/LearnedStore.swift` (modify) | `biasTerms()` pulls vocabulary words; self-test cases. |
| `Sources/Murmur/AppDelegate.swift` (modify) | Run the disambiguator in the transcribe pipeline before formatting. |
| `Sources/Murmur/MainView.swift` (modify) | Rewrite `DictionaryPage` to the Wispr-style unified UI over `VocabularyStore`. |

---

### Task 1: VocabularyStore + migration

**Files:**
- Create: `Sources/Murmur/VocabularyStore.swift`
- Modify: `Sources/Murmur/LearnedStore.swift` (self-test only)

**Interfaces:**
- Consumes: `AppPaths.supportDirectory`, `TextFormatter.loadDictionary()` (legacy source for migration).
- Produces: `struct VocabularyEntry: Codable, Identifiable, Equatable { var id: UUID; var word: String; var misheard: String? }`; `enum VocabularyStore` with `load() -> [VocabularyEntry]`, `save(_:)`, `words(from:) -> [String]`, `words() -> [String]`, `corrections(from:) -> [(misheard: String, word: String)]`, `correctionMap(from:) -> [String: String]`, `correctionMap() -> [String: String]`, `migrate(from: [String: String]) -> [VocabularyEntry]`.

- [ ] **Step 1: Write the failing test**

Add to `LearnedStore.runSelfTest()`, immediately before `return passed`:

```swift
        // MARK: Vocabulary store
        // Pure transforms are tested directly; the file round trip uses the
        // save/restore pattern so it never clobbers the real vocabulary.json.
        let sampleEntries = [
            VocabularyEntry(word: "Phocus", misheard: "focus"),
            VocabularyEntry(word: "Hasselblad", misheard: nil),
        ]
        let vWords = VocabularyStore.words(from: sampleEntries)
        let wordsOK = vWords == ["Phocus", "Hasselblad"]
        if !wordsOK { passed = false }
        print("\(wordsOK ? "PASS" : "FAIL"): vocabulary words() = \(vWords)")

        let corr = VocabularyStore.corrections(from: sampleEntries)
        let corrOK = corr.count == 1 && corr[0].misheard == "focus" && corr[0].word == "Phocus"
        if !corrOK { passed = false }
        print("\(corrOK ? "PASS" : "FAIL"): vocabulary corrections() keeps only misheard entries")

        let map = VocabularyStore.correctionMap(from: sampleEntries)
        let mapOK = map == ["focus": "Phocus"]
        if !mapOK { passed = false }
        print("\(mapOK ? "PASS" : "FAIL"): vocabulary correctionMap() = \(map)")

        // Migration turns a legacy spoken->replacement pair into a correction.
        let migrated = VocabularyStore.migrate(from: ["focus": "Phocus", "lightrim": "Lightroom"])
        let migratedOK = migrated.count == 2
            && migrated.allSatisfy { $0.misheard != nil }
            && Set(migrated.map(\.word)) == ["Phocus", "Lightroom"]
        if !migratedOK { passed = false }
        print("\(migratedOK ? "PASS" : "FAIL"): migrate() converts legacy dictionary to corrections")

        // File round trip via save/restore, so the user's real store is untouched.
        let savedVocab = VocabularyStore.load()
        VocabularyStore.save(sampleEntries)
        let reloaded = VocabularyStore.load()
        let roundTripOK = reloaded.map(\.word) == ["Phocus", "Hasselblad"]
        VocabularyStore.save(savedVocab)
        if !roundTripOK { passed = false }
        print("\(roundTripOK ? "PASS" : "FAIL"): vocabulary.json round trips words")
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift build -c release 2>&1 | tail -5`
Expected: FAIL to compile — `cannot find 'VocabularyStore' in scope` / `cannot find 'VocabularyEntry' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/Murmur/VocabularyStore.swift`:

```swift
import Foundation

/// One dictionary entry. A bare vocabulary word biases recognition toward its
/// spelling. When `misheard` is set, the entry is also a hard correction:
/// the recogniser's `misheard` output is replaced with `word`.
struct VocabularyEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var word: String
    /// nil for a plain vocabulary word; set for a "Correct a misspelling" entry.
    var misheard: String?
}

/// Unified dictionary store, Wispr-style: a list of vocabulary words, some of
/// which also carry a misheard-form correction. Replaces the old
/// replacement-only `dictionary.json`, which it migrates in once.
enum VocabularyStore {
    static var fileURL: URL {
        AppPaths.supportDirectory.appendingPathComponent("vocabulary.json")
    }

    /// Serialises the first-launch migration so a background transcribe task and
    /// the Dictionary UI can't both migrate-and-write at the same instant.
    private static let migrationLock = NSLock()

    /// Loads entries, migrating a legacy `dictionary.json` on first use.
    static func load() -> [VocabularyEntry] {
        if let entries = readFile() { return entries }
        // No vocabulary.json yet: migrate under a lock, double-checking inside
        // it so a concurrent caller that just migrated wins and we don't write
        // twice.
        migrationLock.lock()
        defer { migrationLock.unlock() }
        if let entries = readFile() { return entries }
        // Migrate the legacy dictionary if present, then always write the file
        // so this branch runs exactly once (even with nothing to migrate).
        let migrated = migrate(from: TextFormatter.loadDictionary())
        save(migrated)
        return migrated
    }

    private static func readFile() -> [VocabularyEntry]? {
        guard let data = try? Data(contentsOf: fileURL),
              let entries = try? JSONDecoder().decode([VocabularyEntry].self, from: data)
        else { return nil }
        return entries
    }

    static func save(_ entries: [VocabularyEntry]) {
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: - Pure transforms (unit-tested directly)

    /// Every entry's word, trimmed, de-duplicated, in order. Feeds the
    /// recogniser's bias prompt.
    static func words(from entries: [VocabularyEntry]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for entry in entries {
            let word = entry.word.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = word.lowercased()
            guard !word.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(word)
        }
        return result
    }

    /// Entries that carry a non-empty misheard form, as hard corrections.
    static func corrections(from entries: [VocabularyEntry]) -> [(misheard: String, word: String)] {
        entries.compactMap { entry in
            guard let misheard = entry.misheard?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !misheard.isEmpty else { return nil }
            let word = entry.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty else { return nil }
            return (misheard, word)
        }
    }

    /// Corrections as a `[misheard: word]` map for `TextFormatter`.
    static func correctionMap(from entries: [VocabularyEntry]) -> [String: String] {
        var map: [String: String] = [:]
        for correction in corrections(from: entries) {
            map[correction.misheard] = correction.word
        }
        return map
    }

    /// Converts a legacy `spoken -> replacement` dictionary into corrections.
    /// De-duplicates by lowercased misheard form so a legacy dictionary with
    /// both "focus" and "Focus" produces a single entry.
    static func migrate(from legacy: [String: String]) -> [VocabularyEntry] {
        var seen = Set<String>()
        var entries: [VocabularyEntry] = []
        for (spoken, replacement) in legacy.sorted(by: { $0.key.lowercased() < $1.key.lowercased() }) {
            let spokenTrimmed = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
            let replacementTrimmed = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !spokenTrimmed.isEmpty, !replacementTrimmed.isEmpty else { continue }
            let key = spokenTrimmed.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            entries.append(VocabularyEntry(word: replacementTrimmed, misheard: spokenTrimmed))
        }
        return entries.sorted { $0.word.lowercased() < $1.word.lowercased() }
    }

    // MARK: - Convenience wrappers over the live store

    static func words() -> [String] { words(from: load()) }
    static func correctionMap() -> [String: String] { correctionMap(from: load()) }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift build -c release && ./.build/release/Murmur --selftest`
Expected: 72 PASS, 0 FAIL, exit 0 (67 + 5 new). The four `diff(...)` invariants still PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Murmur/VocabularyStore.swift Sources/Murmur/LearnedStore.swift
git commit -m "Add VocabularyStore with legacy dictionary migration"
```

---

### Task 2: Wire vocabulary into bias and hard corrections

**Files:**
- Modify: `Sources/Murmur/LearnedStore.swift` (`biasTerms()` + self-test)

**Interfaces:**
- Consumes: `VocabularyStore.words()`, `VocabularyStore.correctionMap(from:)`.
- Produces: no new public symbols; `biasTerms()` now includes vocabulary words. Hard corrections apply through `TextFormatter`'s **existing** `dictionary` parameter, which the Task 4 pipeline supplies from `VocabularyStore`. `TextFormatter`'s default initializer is deliberately left unchanged (a disk read in a default initializer is a footgun for any future non-pipeline caller).

- [ ] **Step 1: Write the failing test**

Add to `LearnedStore.runSelfTest()` before `return passed`:

```swift
        // MARK: Vocabulary feeds bias and formatting
        // Save/restore the real store so the assertions are deterministic.
        let savedForBias = VocabularyStore.load()
        VocabularyStore.save([VocabularyEntry(word: "Baseten", misheard: "base ten")])
        let bias = LearnedStore.biasTerms()
        let biasOK = bias.contains("Baseten")
        if !biasOK { passed = false }
        print("\(biasOK ? "PASS" : "FAIL"): biasTerms() includes a vocabulary word")

        // TextFormatter, given the vocabulary correction map, applies the
        // correction as a replacement (this is exactly how Task 4 wires it).
        let vocabMap = VocabularyStore.correctionMap(from: VocabularyStore.load())
        let formatted = TextFormatter(dictionary: vocabMap).format("the base ten pipeline")
        let formatOK = formatted.contains("Baseten") && !formatted.lowercased().contains("base ten")
        if !formatOK { passed = false }
        print("\(formatOK ? "PASS" : "FAIL"): TextFormatter applies a vocabulary correction = \(formatted)")
        VocabularyStore.save(savedForBias)
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift build -c release && ./.build/release/Murmur --selftest 2>&1 | grep -E "vocabulary word|vocabulary correction"`
Expected: the `biasTerms()` line FAILs — it does not yet include vocabulary words. (The `TextFormatter` line may already pass, since it passes the map explicitly; the load-bearing new assertion is the bias one.)

- [ ] **Step 3: Write the implementation**

In `LearnedStore.swift`, in `biasTerms()`, replace the dictionary line. The current body (around `LearnedStore.swift:286-303`) contains:

```swift
        let learned = load()
        learned.terms.forEach(insert)
        learned.corrections.map(\.intended).forEach(insert)
        TextFormatter.loadDictionary().values.forEach(insert)
        SnippetStore.load().map(\.trigger).forEach(insert)
```

Change the `TextFormatter.loadDictionary().values` line to pull from the vocabulary store (which supersedes the legacy dictionary and includes every word, bare or correction target):

```swift
        let learned = load()
        learned.terms.forEach(insert)
        learned.corrections.map(\.intended).forEach(insert)
        VocabularyStore.words().forEach(insert)
        SnippetStore.load().map(\.trigger).forEach(insert)
```

**Do NOT change `TextFormatter`'s initializer.** Its default stays `init(dictionary: [String: String] = TextFormatter.loadDictionary())`. Vocabulary corrections reach the real dictation path because Task 4 constructs `TextFormatter(dictionary: VocabularyStore.correctionMap(from: vocabEntries))` explicitly. Keeping the default off disk-backed vocabulary avoids a synchronous read in every future `TextFormatter()` call.

- [ ] **Step 4: Run to verify it passes**

Run: `swift build -c release && ./.build/release/Murmur --selftest`
Expected: 74 PASS, 0 FAIL, exit 0 (72 + 2). The four `diff(...)` invariants still PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Murmur/LearnedStore.swift
git commit -m "Feed vocabulary words into recognition bias"
```

---

### Task 3: VocabularyDisambiguator + structural guard

**Files:**
- Create: `Sources/Murmur/VocabularyDisambiguator.swift`
- Modify: `Sources/Murmur/LearnedStore.swift` (self-test + make `runSelfTest()` async), `Sources/Murmur/Main.swift` (await the async call site)

**Interfaces:**
- Consumes: `FoundationModels` (`SystemLanguageModel`, `LanguageModelSession`).
- Produces: `struct VocabularyDisambiguator` with `var isAvailable: Bool`, `func disambiguate(_ transcript: String, vocabulary: [String]) async -> String`, and `static func accept(original: String, candidate: String, vocabulary: [String]) -> Bool`.

- [ ] **Step 1: Write the failing test**

Add to `LearnedStore.runSelfTest()` before `return passed`:

```swift
        // MARK: Vocabulary disambiguation guard
        // The on-device model is not headless-testable, so the structural guard
        // that gates its output carries the weight. It must accept a 1:1
        // substitution toward a vocab term and the no-change case, and reject
        // anything else.
        let guardCases: [(name: String, vocab: [String],
                          original: String, candidate: String, accept: Bool)] = [
            ("clean substitution toward a vocab term", ["Phocus"],
             "send it to focus today", "send it to Phocus today", true),
            ("no change", ["Phocus"],
             "i need to focus", "i need to focus", true),
            ("case-insensitive vocab match", ["Phocus"],
             "open focus now", "open phocus now", true),
            // Regression: a sentence-final substitution keeps its punctuation.
            ("substitution keeps trailing punctuation", ["Phocus"],
             "does the word focus.", "does the word Phocus.", true),
            // Multi-word term: v1 does not substitute toward it (the term is a
            // single Set element, never a single token), so it falls back.
            ("multi-word term falls back (v1 unsupported)", ["Apple Vision Pro"],
             "i want apple vision pro", "i want Apple Vision Pro", false),
            // Loophole closed: the model may not recase an arbitrary non-vocab
            // word and have it pass as "no change".
            ("recasing a non-vocab word is rejected", ["Phocus"],
             "i love my macbook", "i love my MacBook", false),
            ("rephrase changes word count", ["Phocus"],
             "send it to focus", "please send it to Phocus", false),
            ("insertion", ["Phocus"],
             "send it to focus", "send it to Phocus really", false),
            ("substitution to a non-vocab word", ["Phocus"],
             "send it to focus", "send it to Lightroom", false),
        ]
        for testCase in guardCases {
            let got = VocabularyDisambiguator.accept(
                original: testCase.original, candidate: testCase.candidate,
                vocabulary: testCase.vocab)
            let ok = got == testCase.accept
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): guard/\(testCase.name) = \(got)")
        }

        // Empty vocabulary short-circuits without a model call, returning input.
        let disambiguator = VocabularyDisambiguator()
        let passthrough = await disambiguator.disambiguate("send it to focus", vocabulary: [])
        let passthroughOK = passthrough == "send it to focus"
        if !passthroughOK { passed = false }
        print("\(passthroughOK ? "PASS" : "FAIL"): empty vocabulary returns the transcript unchanged")
```

Note: this test uses `await`, so `runSelfTest()` must become `async`. Verified: `LearnedStore.runSelfTest()` is currently `static func runSelfTest() -> Bool` (`LearnedStore.swift:483`) with a single caller, `Main.swift:44`, which already runs inside `static func main() async` (`Main.swift:7`). Step 3 makes the conversion — it is clean because the call site is already async.

- [ ] **Step 2: Run to verify it fails**

Run: `swift build -c release 2>&1 | tail -5`
Expected: FAIL to compile — `cannot find 'VocabularyDisambiguator' in scope`.

- [ ] **Step 3: Write the implementation**

First make `runSelfTest()` async so the passthrough test can `await`. In `LearnedStore.swift:483`, change:

```swift
    static func runSelfTest() -> Bool {
```
to:
```swift
    static func runSelfTest() async -> Bool {
```
and update its single caller in `Main.swift:44`:
```swift
            let learnedPassed = await LearnedStore.runSelfTest()
```
(`TextFormatter.runSelfTest()` at `Main.swift:43` stays synchronous — leave it.)

Then create `Sources/Murmur/VocabularyDisambiguator.swift`:

```swift
import FoundationModels
import Foundation

/// Resolves homophone errors the bias prompt cannot: "send it to focus" ->
/// "send it to Phocus", using sentence context, while "I need to focus" is left
/// alone. Reuses the on-device model, exactly as `RewriteEngine` does for Styles.
///
/// The model is trusted for the *context* judgment (does this word mean the
/// custom term here?). It is NOT trusted structurally: `accept` discards any
/// output that does more than substitute whole words toward vocabulary terms,
/// so a hallucinated rephrase can never reach the user.
struct VocabularyDisambiguator {
    /// Upper bound on the on-device model call. A hung or throttled Apple
    /// Intelligence daemon must never block dictation — past this, fall back to
    /// the raw transcript.
    private static let timeout: Duration = .seconds(3)

    var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    func disambiguate(_ transcript: String, vocabulary: [String]) async -> String {
        guard !vocabulary.isEmpty, isAvailable else { return transcript }
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return transcript }

        let instructions = """
        You fix speech-to-text homophone errors. The user has these custom \
        terms: \(vocabulary.joined(separator: ", ")).
        In the text below, replace any word that — given the sentence context — \
        is actually one of these custom terms, with the exact custom term. Only \
        replace a word that sounds like a custom term AND where the context \
        clearly means the custom term. Change nothing else: do not rephrase, \
        add, remove, reorder, or repunctuate words. If nothing should change, \
        return the text exactly as given.
        Output ONLY the resulting text — no preamble, no quotes, no explanations.
        """

        // Race the model against a timeout. Capture only Strings across the
        // task boundary (the session is built inside the child) so nothing
        // non-Sendable crosses it.
        let input = transcript
        let candidate: String? = await withTaskGroup(of: String?.self) { group in
            group.addTask {
                let session = LanguageModelSession(instructions: instructions)
                guard let response = try? await session.respond(to: input) else { return nil }
                return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            group.addTask {
                try? await Task.sleep(for: Self.timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }

        guard let candidate,
              Self.accept(original: transcript, candidate: candidate, vocabulary: vocabulary)
        else { return transcript }
        return candidate
    }

    /// Structural safety net. Accepts `candidate` only when every difference
    /// from `original` is a whole-word substitution whose replacement is a
    /// vocabulary term (comparing each word with surrounding punctuation
    /// stripped, case-insensitively). Same word count required (v1 handles 1:1
    /// substitution only, so multi-word vocab terms simply fall back). The
    /// no-change case is accepted. A rephrase, insertion, deletion, reorder, or
    /// substitution to a non-vocab word is rejected — the caller then keeps the
    /// original transcript.
    static func accept(original: String, candidate: String, vocabulary: [String]) -> Bool {
        // Split on any whitespace (spaces, tabs, newlines), not just U+0020,
        // so punctuation stripping and matching don't break on a stray newline.
        let originalWords = original.split(whereSeparator: \.isWhitespace).map(String.init)
        let candidateWords = candidate.split(whereSeparator: \.isWhitespace).map(String.init)
        guard originalWords.count == candidateWords.count else { return false }
        // Word core: strip surrounding punctuation but KEEP case, so a
        // sentence-final "Phocus." matches the term while an unrequested
        // capitalization change ("macbook" -> "MacBook") still counts as a real
        // change that must justify itself against the vocabulary (closing the
        // "the model may recase anything" loophole).
        func core(_ word: String) -> String {
            String(word.trimmingCharacters(in: .punctuationCharacters))
        }
        let vocab = Set(vocabulary.map { $0.lowercased() })
        for (originalWord, candidateWord) in zip(originalWords, candidateWords) {
            if core(originalWord) == core(candidateWord) { continue }
            // A changed word is allowed only if it IS a vocabulary term (matched
            // case-insensitively). A multi-word vocab term is one Set element
            // and never equals a single token, so multi-word substitutions fall
            // back — v1 is 1:1 whole-word substitution only.
            guard vocab.contains(core(candidateWord).lowercased()) else { return false }
        }
        return true
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift build -c release && ./.build/release/Murmur --selftest`
Expected: 84 PASS, 0 FAIL, exit 0 (74 + 10). The four `diff(...)` invariants still PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Murmur/VocabularyDisambiguator.swift Sources/Murmur/LearnedStore.swift Sources/Murmur/Main.swift
git commit -m "Add context disambiguator with a structural output guard"
```

---

### Task 4: Run disambiguation in the transcribe pipeline

**Files:**
- Modify: `Sources/Murmur/AppDelegate.swift`

**Interfaces:**
- Consumes: `VocabularyDisambiguator`, `VocabularyStore.words()`.
- Produces: no new public symbols; the transcribe pipeline gains a disambiguation step before formatting.

- [ ] **Step 1: Add the disambiguator property**

There is no self-test for the pipeline wiring (it depends on the on-device model and the audio path); Task 3 already tests the guard, and correctness here is verified by build + `--selftest` staying green + the manual check in Step 4. In `AppDelegate`, alongside the existing `private let rewriteEngine = RewriteEngine()` (search for `rewriteEngine`), add:

```swift
    private let vocabularyDisambiguator = VocabularyDisambiguator()
```

- [ ] **Step 2: Insert the pass before formatting**

In `stopAndTranscribe()`, the transcribe `Task` currently begins (around `AppDelegate.swift:308-312`):

```swift
        Task { [history, rewriteEngine] in
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                let raw = try await recognize(fileAt: url)
                var formatted = TextFormatter().format(raw)
```

Change the capture list to include the disambiguator, and disambiguate the raw transcript before formatting (so the model sees natural sentences, per the spec):

```swift
        Task { [history, rewriteEngine, vocabularyDisambiguator] in
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                let raw = try await recognize(fileAt: url)
                // Load the vocabulary once and reuse it for both the context
                // pass and the correction map, so vocabulary.json is read a
                // single time per dictation rather than twice.
                let vocabEntries = VocabularyStore.load()
                // Context pass: fix homophones toward the user's vocabulary
                // before cleanup. No-op when the vocabulary is empty.
                let disambiguated = await vocabularyDisambiguator.disambiguate(
                    raw, vocabulary: VocabularyStore.words(from: vocabEntries))
                var formatted = TextFormatter(
                    dictionary: VocabularyStore.correctionMap(from: vocabEntries)
                ).format(disambiguated)
```

Leave the rest of the pipeline (`LearnedStore.apply`, `SnippetStore.expand`, style rewrite, insertion) unchanged.

Note: this call site passes the correction map explicitly. `TextFormatter`'s default initializer is intentionally left reading `dictionary.json` (unchanged), so no `TextFormatter()` call does a vocabulary disk read implicitly.

Deliberately NOT cached in memory: `VocabularyStore.load()` runs once per completed dictation — human speech cadence, immediately after a multi-hundred-millisecond recognition and audio-file I/O — so one small JSON read is negligible. An in-memory cache would need invalidation coordinated between the Dictionary UI's save and this read; that coherence cost is not justified by a sub-millisecond saving. Revisit only if profiling shows it matters.

- [ ] **Step 3: Verify build and suite**

Run: `swift build -c release && ./.build/release/Murmur --selftest; echo "exit=$?"`
Expected: 84 PASS, 0 FAIL, `exit=0`. No test count change (this task is integration wiring).

- [ ] **Step 4: Manual end-to-end check**

```bash
./scripts/make_app.sh && open build/Murmur.app
```
IMPORTANT: fully quit any running Murmur first (a stale process will not have the new code): `osascript -e 'quit app "Murmur"'` or `pkill -f 'build/Murmur.app'`, then relaunch.

Add "Phocus" as a plain vocabulary word (Task 5 gives the UI; until then, verify via a hand-written `vocabulary.json` if running this task before Task 5), then dictate "Does the word Phocus come out right?" on the close mic. Report what you observe. Expected: with Apple Intelligence available, "Phocus" is produced; with it unavailable, the transcript is unchanged (never corrupted).

- [ ] **Step 5: Commit**

```bash
git add Sources/Murmur/AppDelegate.swift
git commit -m "Run vocabulary disambiguation before formatting"
```

---

### Task 5: Wispr-style Dictionary page

**Files:**
- Modify: `Sources/Murmur/MainView.swift`

**Interfaces:**
- Consumes: `VocabularyStore`, `VocabularyEntry`.

- [ ] **Step 1: Rewrite DictionaryPage**

There is no self-test for SwiftUI; verification is Step 2 (running the app). Replace the existing `struct DictionaryPage: View` (search for `struct DictionaryPage`) and its `DictionaryRow` helper with the vocabulary-backed version. Match the surrounding card style (`Palette.card`, `RoundedRectangle(cornerRadius: 16)`, `.padding(20)`) used by the other pages:

```swift
struct DictionaryPage: View {
    @State private var entries: [VocabularyEntry] = []
    @State private var newWord = ""
    @State private var newMisheard = ""
    @State private var correctingMisspelling = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Dictionary")
                .font(.system(size: 30, weight: .medium))
                .padding(.top, 24)
            Text("Add names, jargon and terms you use so Murmur spells them your " +
                 "way. A plain word biases recognition. Turn on \u{201C}Correct a " +
                 "misspelling\u{201D} to also replace a form it keeps hearing wrong.")
                .foregroundStyle(.secondary)

            // Add-new card.
            VStack(alignment: .leading, spacing: 12) {
                Text("Add to vocabulary").font(.headline)
                Toggle("Correct a misspelling", isOn: $correctingMisspelling)
                    .toggleStyle(.switch)
                HStack {
                    if correctingMisspelling {
                        TextField("misheard as", text: $newMisheard)
                            .textFieldStyle(.roundedBorder)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    }
                    TextField("word or name", text: $newWord)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(add)
                    Button(action: add) { Image(systemName: "plus.circle.fill") }
                        .buttonStyle(.borderless)
                        .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 16))

            // Existing entries.
            VStack(spacing: 8) {
                ForEach($entries) { $entry in
                    HStack {
                        Text(entry.word)
                        if let misheard = entry.misheard, !misheard.isEmpty {
                            Text("\u{2190} \(misheard)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            entries.removeAll { $0.id == entry.id }
                            VocabularyStore.save(entries)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 16))
        }
        .onAppear { entries = VocabularyStore.load() }
    }

    private func add() {
        let word = newWord.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty else { return }
        let misheard = correctingMisspelling
            ? newMisheard.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        let normalizedMisheard = misheard.isEmpty ? nil : misheard
        // Reject only an exact duplicate of the (word, misheard) pair, so a user
        // can still map two different misheard forms ("focus", "pocus") to the
        // same word, while a true repeat is not accumulated in the file.
        let isDuplicate = entries.contains {
            $0.word.lowercased() == word.lowercased()
                && $0.misheard?.lowercased() == normalizedMisheard?.lowercased()
        }
        guard !isDuplicate else {
            newWord = ""
            newMisheard = ""
            correctingMisspelling = false
            return
        }
        entries.append(VocabularyEntry(word: word, misheard: normalizedMisheard))
        VocabularyStore.save(entries)
        newWord = ""
        newMisheard = ""
        correctingMisspelling = false
    }
}
```

Remove the old `struct DictionaryRow` (it is no longer referenced). If any other code references `DictionaryRow`, search for it first (`grep -rn DictionaryRow Sources/`) — nothing should, but confirm before deleting.

This is an in-place replacement inside `MainView.swift`, which already has `import SwiftUI` at the top — do not add another import.

- [ ] **Step 2: Verify by running the app**

```bash
swift build -c release && ./.build/release/Murmur --selftest && ./scripts/make_app.sh
```
Fully quit any running Murmur, then `open build/Murmur.app`. Check by hand and report what you observe:
1. The Dictionary page lists existing entries (any migrated `dictionary.json` entries appear, showing their `\u{2190} misheard` badge).
2. Adding a plain word (toggle off) adds it with no badge.
3. Adding with "Correct a misspelling" on captures the misheard-as form and shows the badge.
4. Deleting removes the entry and persists (reopen the page to confirm).
5. A word added here is used by dictation: add "Phocus", dictate the test sentence, confirm it comes out "Phocus".

- [ ] **Step 3: Commit**

```bash
git add Sources/Murmur/MainView.swift
git commit -m "Rewrite Dictionary page as a Wispr-style vocabulary list"
```

---

### Task 6: Review

- [ ] **Step 1: Full suite**

```bash
swift build -c release && ./.build/release/Murmur --selftest; echo "exit=$?"
```
Expected: every line PASS, `exit=0`, including the four `diff(...)` invariants.

- [ ] **Step 2: Gemini panel review**

```bash
git diff <mic-feature-head>..HEAD -- Sources/ > /tmp/murmur-vocab.diff
~/.claude/tools/review panel /tmp/murmur-vocab.diff
```
(Use the commit before this plan's Task 1 as the base — the tip of the microphone feature — so the diff is vocabulary-only.) Read `/tmp/murmur-vocab.diff.panel-review.md`. Fix findings that are ours; record out-of-scope architecture findings rather than acting on them here.

- [ ] **Step 3: Adversarial review**

Dispatch a reviewer over the same diff, focused on: whether `accept` can ever pass a corrupting rewrite (especially punctuation/tokenisation edge cases in the whitespace split); whether the disambiguation pass can block or slow dictation when the model hangs (it is `await`ed inline in the transcribe Task — confirm the 3s timeout bounds it and a slow model degrades latency but never drops text, and check that a timed-out `LanguageModelSession` does not leak memory in the daemon across repeated dictations); whether the double-checked migration lock is correct and migration can neither run twice nor lose entries; and whether feeding vocabulary corrections through `TextFormatter` in the pipeline double-applies with the unchanged default `dictionary.json` read anywhere.

---

## Self-Review

**Spec coverage:**

| Spec requirement | Task |
|---|---|
| Unified Dictionary: vocabulary words + opt-in correction | 1 (store), 5 (UI) |
| Bare word biases recognition | 1, 2 |
| Correction does a hard misheard->word replacement | 1, 2 (via TextFormatter) |
| Context-aware disambiguation pass | 3, 4 |
| Runs auto when vocabulary non-empty, skipped when empty | 3 (`disambiguate` guard), 4 |
| Migrate legacy dictionary.json once | 1 |
| Mechanical validation of model output | 3 (`accept`) |
| Guard is structural, not semantic | 3 (doc + tests) |
| v1 = 1:1 substitution; word-count changes fall back | 3 (`accept` count check) |
| Always-optional polish; failure returns raw transcript | 3, 4 |
| No new dependencies; reuse FoundationModels | 3 |
| Tests extend runSelfTest | 1, 2, 3 |

**Deliberate exclusions carried from the spec:** no sync (folds into the paused iCloud sync plan), no per-app vocabulary, no phonetic collision index, multi-word/re-segmentation collisions deferred.

**Type consistency:** `VocabularyEntry(word:misheard:)`, `VocabularyStore.words()/corrections()/correctionMap()/migrate()/load()/save()`, `VocabularyDisambiguator.disambiguate(_:vocabulary:)/accept(original:candidate:vocabulary:)/isAvailable` are used identically across Tasks 1-5.

**Test-harness change (resolved, not a risk):** Task 3 makes `LearnedStore.runSelfTest()` async so its one passthrough test can `await`. Verified during planning: the sole caller (`Main.swift:44`) already runs inside `static func main() async`, so the conversion is a two-line change with no ripple. `TextFormatter.runSelfTest()` stays synchronous.
