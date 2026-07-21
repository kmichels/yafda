# Learning Guardrails Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop transcript edits from poisoning `learned.json` with rewrite rules that fire on ordinary speech, and stop `apply()` from collapsing bidirectional rules into a single word.

**Architecture:** A new `WordChecker` protocol answers "could this phrase occur in ordinary speech?", backed by `NSSpellChecker` in production and a fixed word set in tests. `LearnedStore.isUsefulMapping` uses it to reject automatically-diffed mappings whose misheard side is ordinary language, exempting pure re-segmentations. `LearnedStore.apply` is rewritten as a single left-to-right pass so no region is rewritten twice. `learn()` reports what it learned and what it skipped so the UI can name both.

**Tech Stack:** Swift 6.2 (language mode v5), SwiftPM, AppKit, SwiftUI. No new dependencies.

**Spec:** `.planning/design/learning-guardrails-and-icloud-sync.md`

## Global Constraints

- Target branch for the PR: `fix/learning-guardrails`, cut from `main` (upstream's default branch is `main`, not `master`).
- **All four existing `LearnedStore.runSelfTest()` cases must stay green.** They are requirements, not tests we may edit. Breaking one invalidates the change.
- No new third-party dependencies.
- No XCTest target. Tests extend the repo's existing `runSelfTest() -> Bool` convention, wired to `--selftest` in `Main.swift:42-45`.
- No change to the on-disk JSON format. Existing `learned.json` files must load unchanged.
- The PR adds no logging framework.
- Swift language mode is `.v5` (`Package.swift:17`), so strict concurrency is not enforced; a mutable `static var` is acceptable.
- All guard code runs on the main actor (`AppDelegate.correctHistoryEntry` and SwiftUI call sites), so `NSSpellChecker.shared` needs no thread hopping.
- Build and test with: `swift build -c release && ./.build/release/Murmur --selftest`

## File Structure

| File | Responsibility |
|---|---|
| `Sources/Murmur/WordChecker.swift` (create) | Decide whether a phrase could occur in ordinary speech. Protocol + system-backed and fixed implementations. |
| `Sources/Murmur/LearnedStore.swift` (modify) | Guards in `isUsefulMapping`, non-cascading `apply`, `LearnOutcome` reporting, extended `runSelfTest`. |
| `Sources/Murmur/AppDelegate.swift:207-216` (modify) | `correctHistoryEntry` returns `LearnOutcome` instead of `Int`. |
| `Sources/Murmur/MainView.swift:398-405` (modify) | "Save & Learn" toast uses `LearnOutcome.summary`. |

---

### Task 1: WordChecker

**Files:**
- Create: `Sources/Murmur/WordChecker.swift`
- Modify: `Sources/Murmur/LearnedStore.swift` (self-test only)

**Interfaces:**
- Consumes: `Settings.localeIdentifier` (`AppDelegate.swift:462`)
- Produces: `protocol WordChecker { func isKnownWord(_:) -> Bool }` with extension methods `isOrdinaryWord(_:) -> Bool` and `isOrdinaryPhrase(_:) -> Bool`; `struct SystemWordChecker: WordChecker`; `struct FixedWordChecker: WordChecker { let words: Set<String> }`

- [ ] **Step 1: Write the failing test**

Add to `LearnedStore.runSelfTest()`, immediately before `return passed`:

```swift
        // MARK: Ordinary-speech detection
        let checker = FixedWordChecker(words: ["have", "work", "base", "ten", "he", "caught"])
        let wordCases: [(phrase: String, ordinary: Bool)] = [
            ("have", true),            // plain dictionary word
            ("he caught", true),       // every token ordinary
            ("Lightrim", false),       // not a word
            ("hecon Phocus", false),   // neither token a word
            ("X2D2", false),           // digits are never ordinary speech
            ("J", false),              // single letters spell-check clean but are not words
            ("", false),               // no tokens
        ]
        for testCase in wordCases {
            let got = checker.isOrdinaryPhrase(testCase.phrase)
            let ok = got == testCase.ordinary
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): ordinary(\"\(testCase.phrase)\") = \(got)" +
                  (ok ? "" : " (expected \(testCase.ordinary))"))
        }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift build -c release 2>&1 | tail -5`
Expected: FAIL to compile — `cannot find 'FixedWordChecker' in scope`

- [ ] **Step 3: Write the implementation**

Create `Sources/Murmur/WordChecker.swift`:

```swift
import AppKit
import Foundation

/// Decides whether a phrase could plausibly occur in ordinary speech.
///
/// Learned corrections are applied as global whole-word rewrites, so a rule
/// whose misheard side is ordinary language rewrites text the user never meant
/// to change. Guarding on this is what stops one transcript edit from turning
/// every future "have" into "work".
protocol WordChecker {
    /// Whether `token` - already lowercased, trimmed of surrounding
    /// punctuation, and known to be free of digits - is a word of the
    /// user's language.
    func isKnownWord(_ token: String) -> Bool
}

extension WordChecker {
    /// Whether `word` could occur in ordinary speech.
    func isOrdinaryWord(_ word: String) -> Bool {
        let token = word
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            .lowercased()
        // Punctuation-only tokens carry nothing to key a rewrite on.
        guard !token.isEmpty else { return true }
        // Model numbers and part codes ("X2D2") are never ordinary speech.
        guard token.rangeOfCharacter(from: .decimalDigits) == nil else { return false }
        // Single letters ("J" in "J Peg") spell-check clean but are not words.
        guard token.count >= 2 else { return false }
        return isKnownWord(token)
    }

    /// Whether every whitespace-separated token could occur in ordinary speech.
    /// An empty phrase is not ordinary - there is nothing to guard against.
    func isOrdinaryPhrase(_ phrase: String) -> Bool {
        let tokens = phrase.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return false }
        return tokens.allSatisfy(isOrdinaryWord)
    }
}

/// Production checker backed by the system spelling dictionary.
struct SystemWordChecker: WordChecker {
    private let language: String

    init(localeIdentifier: String = Settings.localeIdentifier) {
        // NSSpellChecker expects "en_US"; Settings stores BCP-47 "en-US".
        language = localeIdentifier.replacingOccurrences(of: "-", with: "_")
    }

    func isKnownWord(_ token: String) -> Bool {
        // Lowercasing before this call matters: the spell checker accepts any
        // capitalised token as a proper noun, which would make nearly every
        // phrase "ordinary" and reject nearly every mapping.
        NSSpellChecker.shared.checkSpelling(
            of: token, startingAt: 0, language: language, wrap: false,
            inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
    }
}

/// Deterministic checker for self-tests.
///
/// `NSSpellChecker` learns words per user, so its verdicts differ between
/// machines and drift over time. Tests must never depend on it.
struct FixedWordChecker: WordChecker {
    let words: Set<String>

    func isKnownWord(_ token: String) -> Bool { words.contains(token) }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift build -c release && ./.build/release/Murmur --selftest`
Expected: the 7 new `ordinary(...)` lines all PASS; the 14 pre-existing lines still PASS; exit 0

- [ ] **Step 5: Commit**

```bash
git add Sources/Murmur/WordChecker.swift Sources/Murmur/LearnedStore.swift
git commit -m "Add WordChecker to detect ordinary-speech phrases"
```

---

### Task 2: Ordinary-speech and reverse guards

**Files:**
- Modify: `Sources/Murmur/LearnedStore.swift:214-219` (`isUsefulMapping`), `:186-193` (`extractCorrections` filter), `:45-67` (`add`)

**Interfaces:**
- Consumes: `WordChecker`, `FixedWordChecker` from Task 1
- Produces: `LearnedStore.wordChecker: WordChecker` (settable); `LearnedStore.isUsefulMapping(heard:intended:existing:checker:) -> Bool`; `LearnedStore.normalizedForComparison(_:) -> String`; `LearnedStore.add(heard:intended:) -> Bool` (was `Void`)

- [ ] **Step 1: Write the failing test**

Add to `LearnedStore.runSelfTest()` before `return passed`:

```swift
        // MARK: Mapping guards
        let guardChecker = FixedWordChecker(words: [
            "have", "work", "he", "caught", "base", "ten", "so", "my", "a", "focus",
        ])
        let existing = [LearnedCorrection(heard: "focus", intended: "Phocus")]
        let guardCases: [(heard: String, intended: String, useful: Bool, why: String)] = [
            ("have", "work", false, "ordinary single word"),
            ("my", "a", false, "ordinary single word"),
            ("he caught", "Helicon", false, "every token ordinary, not a re-segmentation"),
            ("base ten", "Baseten", true, "re-segmentation of the same sounds"),
            ("so ren", "Søren", true, "\"ren\" is not an ordinary word"),
            ("Lightrim", "Lightroom", true, "misheard non-word"),
            ("X2D2", "X2D II", true, "digits are not ordinary speech"),
            ("Phocus", "focus", false, "reverse of an existing mapping"),
        ]
        for testCase in guardCases {
            let got = LearnedStore.isUsefulMapping(
                heard: testCase.heard, intended: testCase.intended,
                existing: existing, checker: guardChecker)
            let ok = got == testCase.useful
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): useful(\"\(testCase.heard)\" -> " +
                  "\"\(testCase.intended)\") = \(got) [\(testCase.why)]")
        }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift build -c release 2>&1 | tail -5`
Expected: FAIL to compile — `'isUsefulMapping' is inaccessible due to 'private' protection level` and `extra arguments 'existing', 'checker'`

- [ ] **Step 3: Write the implementation**

In `LearnedStore.swift`, add after `static var fileURL`:

```swift
    /// Checker used to decide whether an automatically-diffed mapping is safe
    /// to store. Overridable so self-tests are deterministic.
    static var wordChecker: WordChecker = SystemWordChecker()
```

Replace `isUsefulMapping` (currently `LearnedStore.swift:214-219`) with:

```swift
    /// Whether a mapping is safe to store as a global rewrite rule.
    ///
    /// - Parameters:
    ///   - existing: corrections already stored, used to refuse the second half
    ///     of an A -> B / B -> A pair, which would otherwise collapse both
    ///     words into one.
    ///   - checker: injectable so self-tests do not depend on the user's
    ///     spelling dictionary.
    static func isUsefulMapping(heard: String, intended: String,
                                existing: [LearnedCorrection] = [],
                                checker: WordChecker? = nil) -> Bool {
        let checker = checker ?? wordChecker
        guard heard.count >= 2, !intended.isEmpty,
              heard.lowercased() != intended.lowercased()
        else { return false }

        // A correction fires as a global whole-word rewrite. If the misheard
        // side is made entirely of ordinary words, it rewrites speech the user
        // never meant to change. The exception is a re-segmentation of the same
        // sounds ("base ten" -> "Baseten"), which is a genuine mishearing.
        if checker.isOrdinaryPhrase(heard),
           normalizedForComparison(heard) != normalizedForComparison(intended) {
            return false
        }

        // A -> B alongside B -> A rewrites every occurrence of both to one value.
        if existing.contains(where: {
            $0.heard.lowercased() == intended.lowercased()
                && $0.intended.lowercased() == heard.lowercased()
        }) {
            return false
        }
        return true
    }

    /// Lowercased with every non-alphanumeric character removed, so that
    /// "base ten" and "Baseten" compare equal.
    static func normalizedForComparison(_ text: String) -> String {
        String(String.UnicodeScalarView(
            text.lowercased().unicodeScalars.filter {
                CharacterSet.alphanumerics.contains($0)
            }))
    }
```

In `extractCorrections`, delete the guard so candidates reach `add()` and can be
reported as skipped. Replace (currently `LearnedStore.swift:186-194`):

```swift
            if !removed.isEmpty, !added.isEmpty,
               removed.count <= 4, added.count <= 4 {
                let heard = normalizePhrase(removed.joined(separator: " "))
                let intended = added.joined(separator: " ")
                    .trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
                if isUsefulMapping(heard: heard, intended: intended) {
                    pairs.append((heard, intended))
                }
            }
```

with:

```swift
            if !removed.isEmpty, !added.isEmpty,
               removed.count <= 4, added.count <= 4 {
                let heard = normalizePhrase(removed.joined(separator: " "))
                let intended = added.joined(separator: " ")
                    .trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
                if !heard.isEmpty, !intended.isEmpty {
                    pairs.append((heard, intended))
                }
            }
```

Also update the doc comment on `extractCorrections` (currently `:140-142`) from
"Returns substituted runs" to note these are *candidates*:

```swift
    /// Word-level diff between the original transcript and the user's
    /// correction. Returns substituted runs (up to 4 words long) as candidate
    /// heard -> intended pairs. Candidates are not yet validated; `add` applies
    /// the guards and reports which were rejected.
```

Replace `add` (currently `LearnedStore.swift:45-67`) with:

```swift
    /// Adds one mapping (merging duplicates) and remembers the intended term.
    /// - Returns: whether the mapping was stored. A rejected mapping still
    ///   contributes its intended wording as a recognition-bias term.
    @discardableResult
    static func add(heard: String, intended: String) -> Bool {
        let heardTrimmed = normalizePhrase(heard)
        let intendedTrimmed = intended.trimmingCharacters(in: .whitespacesAndNewlines)
        var learned = load()
        guard isUsefulMapping(heard: heardTrimmed, intended: intendedTrimmed,
                              existing: learned.corrections) else {
            appendTerm(intendedTrimmed, to: &learned)
            save(learned)
            return false
        }
        if let index = learned.corrections.firstIndex(where: {
            $0.heard.lowercased() == heardTrimmed.lowercased()
                && $0.intended == intendedTrimmed
        }) {
            learned.corrections[index].timesSeen += 1
        } else {
            learned.corrections.append(LearnedCorrection(
                heard: heardTrimmed, intended: intendedTrimmed))
        }
        if learned.corrections.count > 300 {
            learned.corrections.removeFirst(learned.corrections.count - 300)
        }
        appendTerm(intendedTrimmed, to: &learned)
        save(learned)
        return true
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift build -c release && ./.build/release/Murmur --selftest`
Expected: 8 new `useful(...)` lines PASS. **Critically, the four pre-existing `diff(...)` lines must still PASS** — `base ten` -> `Baseten` in particular.

- [ ] **Step 5: Commit**

```bash
git add Sources/Murmur/LearnedStore.swift
git commit -m "Reject mappings that fire on ordinary speech"
```

---

### Task 3: Non-cascading apply

**Files:**
- Modify: `Sources/Murmur/LearnedStore.swift:101-115` (`apply`)

**Interfaces:**
- Produces: `LearnedStore.apply(in:using:) -> String`; `apply(in:) -> String` keeps its signature and all four existing call sites (`AppDelegate.swift:312`, `Main.swift:51`, `Main.swift:95`) unchanged.

- [ ] **Step 1: Write the failing test**

Add to `LearnedStore.runSelfTest()` before `return passed`:

```swift
        // MARK: Non-cascading apply
        // Sorting by length and rewriting a mutating buffer made A -> B and
        // B -> A collapse both words to one value. A single pass cannot.
        let pair = [
            LearnedCorrection(heard: "Phocus", intended: "focus"),
            LearnedCorrection(heard: "focus", intended: "Phocus"),
        ]
        let swapped = LearnedStore.apply(in: "focus Phocus", using: pair)
        let reversed = LearnedStore.apply(in: "focus Phocus", using: pair.reversed())
        let applyCases: [(name: String, got: String, expected: String)] = [
            ("no collapse", swapped, "Phocus focus"),
            ("order independent", reversed, swapped),
            ("raw survives",
             LearnedStore.apply(in: "shoot RAW or more", using: [
                LearnedCorrection(heard: "more", intended: "RAW"),
                LearnedCorrection(heard: "RAW", intended: "more"),
             ]),
             "shoot more or RAW"),
            ("whole words only",
             LearnedStore.apply(in: "defocused", using: [
                LearnedCorrection(heard: "focus", intended: "Phocus"),
             ]),
             "defocused"),
            ("empty corpus", LearnedStore.apply(in: "untouched", using: []), "untouched"),
        ]
        for testCase in applyCases {
            let ok = testCase.got == testCase.expected
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): apply/\(testCase.name) = \"\(testCase.got)\"" +
                  (ok ? "" : " (expected \"\(testCase.expected)\")"))
        }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift build -c release 2>&1 | tail -5`
Expected: FAIL to compile — `extra argument 'using' in call`

- [ ] **Step 3: Write the implementation**

Replace `apply(in:)` (currently `LearnedStore.swift:101-115`) with:

```swift
    /// Fixes known mishearings in text loaded from the store.
    static func apply(in text: String) -> String {
        apply(in: text, using: load().corrections)
    }

    /// Fixes known mishearings in a single left-to-right pass, so no region of
    /// `text` is rewritten more than once.
    ///
    /// The previous implementation applied each correction as a global regex
    /// over the same mutating string, which meant A -> B followed by B -> A
    /// rewrote every occurrence of both words to a single value. Consuming the
    /// input once makes the result independent of correction order.
    static func apply(in text: String, using corrections: [LearnedCorrection]) -> String {
        guard !corrections.isEmpty else { return text }
        // Longest first so overlapping mappings resolve predictably.
        let ordered = corrections.sorted { $0.heard.count > $1.heard.count }
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            var matched = false
            if isWordStart(at: index, in: text) {
                for correction in ordered {
                    guard let end = matchEnd(of: correction.heard, in: text, at: index)
                    else { continue }
                    result += correction.intended
                    index = end
                    matched = true
                    break
                }
            }
            if !matched {
                result.append(text[index])
                index = text.index(after: index)
            }
        }
        return result
    }

    /// Whether a match starting at `index` would begin a whole word.
    private static func isWordStart(at index: String.Index, in text: String) -> Bool {
        guard index > text.startIndex else { return true }
        let previous = text[text.index(before: index)]
        return !(previous.isLetter || previous.isNumber)
    }

    /// The index just past `phrase` when it occurs at `index` as a whole word,
    /// case-insensitively; `nil` when it does not.
    private static func matchEnd(of phrase: String, in text: String,
                                 at index: String.Index) -> String.Index? {
        guard !phrase.isEmpty,
              let range = text.range(of: phrase,
                                     options: [.caseInsensitive, .anchored],
                                     range: index..<text.endIndex)
        else { return nil }
        if range.upperBound < text.endIndex {
            let next = text[range.upperBound]
            if next.isLetter || next.isNumber { return nil }
        }
        return range.upperBound
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift build -c release && ./.build/release/Murmur --selftest`
Expected: 5 new `apply/...` lines PASS; all previous lines still PASS

Then confirm the real fix end-to-end against the live store:

Run: `./.build/release/Murmur --format "I shoot RAW and want more focus"`
Expected: "RAW" and "more" both survive; neither is replaced by the other

- [ ] **Step 5: Commit**

```bash
git add Sources/Murmur/LearnedStore.swift
git commit -m "Apply corrections in one pass so pairs cannot collapse"
```

---

### Task 4: Report learned and skipped mappings

**Files:**
- Modify: `Sources/Murmur/LearnedStore.swift:88-97` (`learn`)
- Modify: `Sources/Murmur/AppDelegate.swift:207-216` (`correctHistoryEntry`)
- Modify: `Sources/Murmur/MainView.swift:398-405` (Save & Learn button)

**Interfaces:**
- Consumes: `LearnedStore.add(heard:intended:) -> Bool` from Task 2
- Produces: `struct LearnedPair: Equatable { var heard: String; var intended: String }`; `struct LearnOutcome: Equatable { var learned: [LearnedPair]; var skipped: [LearnedPair]; var summary: String }`; `LearnedStore.learn(original:corrected:) -> LearnOutcome`; `AppDelegate.correctHistoryEntry(id:newText:) -> LearnOutcome`

- [ ] **Step 1: Write the failing test**

Add to `LearnedStore.runSelfTest()` before `return passed`:

```swift
        // MARK: Outcome summaries
        let summaryCases: [(outcome: LearnOutcome, expected: String)] = [
            (LearnOutcome(), "Transcript updated."),
            (LearnOutcome(learned: [LearnedPair(heard: "Lightrim", intended: "Lightroom")],
                          skipped: []),
             "Learned “Lightrim” → “Lightroom”."),
            (LearnOutcome(learned: [],
                          skipped: [LearnedPair(heard: "have", intended: "work")]),
             "Skipped “have” - too common to rewrite safely."),
            (LearnOutcome(learned: [LearnedPair(heard: "JPIG", intended: "JPEG")],
                          skipped: [LearnedPair(heard: "my", intended: "a")]),
             "Learned “JPIG” → “JPEG”. Skipped “my” - too common to rewrite safely."),
        ]
        for testCase in summaryCases {
            let got = testCase.outcome.summary
            let ok = got == testCase.expected
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): summary = \"\(got)\"" +
                  (ok ? "" : " (expected \"\(testCase.expected)\")"))
        }
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift build -c release 2>&1 | tail -5`
Expected: FAIL to compile — `cannot find 'LearnOutcome' in scope`

- [ ] **Step 3: Write the implementation**

In `LearnedStore.swift`, add after `struct LearnedData` (currently ends line 17):

```swift
/// One misheard -> intended mapping considered during a transcript fix.
struct LearnedPair: Codable, Equatable {
    var heard: String
    var intended: String
}

/// What a transcript fix taught Murmur, and what it declined to learn.
struct LearnOutcome: Equatable {
    var learned: [LearnedPair] = []
    var skipped: [LearnedPair] = []

    /// Names both outcomes so a rejected mapping is visible rather than silent.
    var summary: String {
        var parts: [String] = []
        if !learned.isEmpty {
            parts.append("Learned " + learned
                .map { "“\($0.heard)” → “\($0.intended)”" }
                .joined(separator: ", "))
        }
        if !skipped.isEmpty {
            parts.append("Skipped " + skipped
                .map { "“\($0.heard)”" }
                .joined(separator: ", ") + " - too common to rewrite safely")
        }
        guard !parts.isEmpty else { return "Transcript updated." }
        return parts.joined(separator: ". ") + "."
    }
}
```

Replace `learn` (currently `LearnedStore.swift:88-97`) with:

```swift
    /// Learns from a user-corrected transcript: extracts word-level
    /// substitutions and stores those that pass the guards.
    @discardableResult
    static func learn(original: String, corrected: String) -> LearnOutcome {
        var outcome = LearnOutcome()
        for candidate in extractCorrections(original: original, corrected: corrected) {
            let pair = LearnedPair(heard: candidate.heard, intended: candidate.intended)
            if add(heard: candidate.heard, intended: candidate.intended) {
                outcome.learned.append(pair)
            } else {
                outcome.skipped.append(pair)
            }
        }
        return outcome
    }
```

In `AppDelegate.swift`, replace `correctHistoryEntry` (currently `:207-216`) with:

```swift
    /// Applies a user correction to a transcript and learns the
    /// misheard -> intended mappings from it.
    /// - Returns: what was learned and what was skipped.
    @discardableResult
    func correctHistoryEntry(id: String, newText: String) -> LearnOutcome {
        guard let entry = history.entries.first(where: { $0.id == id }),
              entry.text != newText else { return LearnOutcome() }
        let outcome = LearnedStore.learn(original: entry.text, corrected: newText)
        history.update(id: id, text: newText)
        entries = history.entries
        rebuildMenu()
        return outcome
    }
```

In `MainView.swift`, replace the Save & Learn action (currently `:398-405`) with:

```swift
                    Button("Save & Learn") {
                        let outcome = app.correctHistoryEntry(
                            id: entry.id, newText: editText)
                        learnFeedback = outcome.summary
                        editingEntry = nil
                    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift build -c release && ./.build/release/Murmur --selftest`
Expected: 4 new `summary = ...` lines PASS; every previous line still PASS; exit 0

- [ ] **Step 5: Commit**

```bash
git add Sources/Murmur/LearnedStore.swift Sources/Murmur/AppDelegate.swift Sources/Murmur/MainView.swift
git commit -m "Name learned and skipped mappings in the fix toast"
```

---

### Task 5: Verify against the real corpus, then review and open the PR

**Files:**
- No source changes unless verification finds a defect.

- [ ] **Step 1: Confirm the full self-test suite passes**

```bash
swift build -c release && ./.build/release/Murmur --selftest; echo "exit=$?"
```
Expected: every line PASS, `exit=0`. The four original `diff(...)` cases must be among them.

- [ ] **Step 2: Measure the guard against the real 36-mapping corpus**

The corpus and expected verdicts are in the spec's Testing Strategy section. Re-run the
measurement harness against the built guard rather than a standalone script, and confirm
it still reports **20/23 junk rejected, 10/13 keepers retained**. If the numbers moved,
update the spec and the PR description to the measured values — do not report the
spec's figures without re-measuring.

- [ ] **Step 3: Confirm the app still builds, signs, and runs**

```bash
./scripts/make_app.sh && open build/Murmur.app && sleep 3 && pgrep -f "Murmur.app" >/dev/null && echo "running"
```
Expected: `Built build/Murmur.app`, then `running`

- [ ] **Step 4: Gemini panel review**

```bash
~/.claude/tools/review panel .planning/plans/2026-07-21-learning-guardrails.md
```
Read the `.panel-review.md` output file. Fix every `High` finding and re-run, up to
3 rounds. Do not open the PR while a `High` finding is outstanding.

- [ ] **Step 5: Cut the PR branch and open the PR**

The working branch `local/main` carries the design docs, which must not reach upstream.
Cherry-pick only the four implementation commits onto a branch cut from `main`:

```bash
git checkout -b fix/learning-guardrails main
git cherry-pick <task1> <task2> <task3> <task4>
git diff --stat main   # must show ONLY Sources/Murmur/*.swift
```

Confirm no `.planning/` path appears in that diff before pushing. Then fork and open
the PR against `janisbelozerovs-dev/murmur:main`.

The PR description states the measured numbers honestly, including the three junk
mappings that survive and the three legitimate ones that are lost, and notes that all
four pre-existing self-tests remain green.

---

## Self-Review

**Spec coverage:**

| Spec requirement | Task |
|---|---|
| Ordinary-speech guard with re-segmentation exception | 2 |
| Reverse guard | 2 |
| `apply` order-independent, no double rewrite | 3 |
| Voice Training path unaffected | 2 (`add` guards; explicit `addTerm` untouched) |
| Toast names learned and skipped | 4 |
| No on-disk format change | all - no `Codable` field added to `LearnedData`/`LearnedCorrection` |
| Author's four self-tests stay green | 2 step 4, 5 step 1 |
| `WordChecker` injectable for determinism | 1 |
| PR adds no logging | all |
| Gemini panel review before PR | 5 |

**Known gap, deliberate:** `LearnedPair` is declared `Codable` although nothing
serialises it yet. That is groundwork for the sync plan's tombstones and costs one
protocol conformance; if the panel review flags it as unused, drop the conformance.

**Type consistency check:** `isUsefulMapping` takes `existing:`/`checker:` in Tasks 2
and is called with both in Task 2's test. `add` returns `Bool` in Task 2 and is consumed
as `Bool` in Task 4. `LearnOutcome.summary` is defined in Task 4 and used in Task 4's
MainView change. `apply(in:using:)` is defined in Task 3 and used in Task 3's tests only.
No forward references to undefined types.
