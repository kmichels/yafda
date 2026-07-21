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
        // Script-bearing tags ("zh-Hans-CN") do not name an installed
        // dictionary, so fall back to the checker's own language rather than
        // passing a name it will not recognise.
        let candidate = localeIdentifier.replacingOccurrences(of: "-", with: "_")
        let checker = NSSpellChecker.shared
        language = checker.availableLanguages.contains(candidate)
            ? candidate
            : checker.language()
    }

    /// - Important: `token` must already be lowercased by `isOrdinaryWord`.
    ///   The spell checker accepts any capitalised token as a proper noun, so
    ///   checking raw input would report nearly every phrase as ordinary and
    ///   reject nearly every mapping.
    func isKnownWord(_ token: String) -> Bool {
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
- Produces: `LearnedStore.wordChecker: WordChecker` (settable); `LearnedStore.isValidMapping(heard:intended:) -> Bool`; `LearnedStore.isUsefulMapping(heard:intended:existing:checker:) -> Bool`; `LearnedStore.shouldStore(heard:intended:existing:checker:) -> Bool`; `LearnedStore.normalizedForComparison(_:) -> String`; `LearnedStore.add(heard:intended:) -> Bool` (was `Void`)

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

        // A store poisoned before these guards existed must stay repairable:
        // re-correcting an existing rule is an update, not a new rule.
        let poisoned = [LearnedCorrection(heard: "have", intended: "work")]
        let storeCases: [(heard: String, intended: String, store: Bool, why: String)] = [
            ("have", "halve", true, "updates an existing rule, even an ordinary word"),
            ("my", "a", false, "new rule on an ordinary word"),
            ("have", "have", false, "no-op mapping is never valid"),
        ]
        for testCase in storeCases {
            let got = LearnedStore.shouldStore(
                heard: testCase.heard, intended: testCase.intended,
                existing: poisoned, checker: guardChecker)
            let ok = got == testCase.store
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): shouldStore(\"\(testCase.heard)\" -> " +
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
    ///
    /// Only ever touched from the main actor (transcript fixes and Voice
    /// Training are both UI actions); marked explicitly so a future move to
    /// Swift 6 language mode does not turn this into a build error.
    nonisolated(unsafe) static var wordChecker: WordChecker = SystemWordChecker()
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
        guard isValidMapping(heard: heard, intended: intended) else { return false }

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

    /// The structural checks every mapping must pass, guards aside.
    static func isValidMapping(heard: String, intended: String) -> Bool {
        heard.count >= 2 && !intended.isEmpty
            && heard.lowercased() != intended.lowercased()
    }

    /// Whether `add` should store this mapping given what is already stored.
    ///
    /// Updating a rule that already exists adds no new exposure - there is
    /// still exactly one rule for that phrase. Refusing the update would trap
    /// anyone whose store was poisoned before these guards existed, leaving the
    /// Voice Training delete button as their only escape.
    static func shouldStore(heard: String, intended: String,
                            existing: [LearnedCorrection],
                            checker: WordChecker? = nil) -> Bool {
        guard isValidMapping(heard: heard, intended: intended) else { return false }
        if existing.contains(where: { $0.heard.lowercased() == heard.lowercased() }) {
            return true
        }
        return isUsefulMapping(heard: heard, intended: intended,
                               existing: existing, checker: checker)
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
        guard shouldStore(heard: heardTrimmed, intended: intendedTrimmed,
                          existing: learned.corrections) else {
            // Still worth biasing recognition toward the intended wording.
            appendTerm(intendedTrimmed, to: &learned)
            save(learned)
            return false
        }
        if let index = learned.corrections.firstIndex(where: {
            $0.heard.lowercased() == heardTrimmed.lowercased()
        }) {
            var updated = learned.corrections.remove(at: index)
            if updated.intended == intendedTrimmed {
                updated.timesSeen += 1
            } else {
                // One misheard phrase maps to one intended phrase. Storing both
                // would leave a dead rule and force apply() to choose between
                // them; the newer correction is the user's current intent.
                updated.intended = intendedTrimmed
                updated.timesSeen = 1
            }
            // Re-append so the 300-item cap, which evicts from the front,
            // discards stale rules rather than ones still being corrected.
            learned.corrections.append(updated)
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
            // Equal-length rules must not resolve by input order.
            ("ties deterministic",
             LearnedStore.apply(in: "cat", using: [
                LearnedCorrection(heard: "cat", intended: "dog"),
                LearnedCorrection(heard: "cat", intended: "cow"),
             ]),
             LearnedStore.apply(in: "cat", using: [
                LearnedCorrection(heard: "cat", intended: "cow"),
                LearnedCorrection(heard: "cat", intended: "dog"),
             ])),
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
    ///
    /// Corrections are indexed by first character so each word start tests only
    /// the few rules that could begin there. Measured on a 500-word transcript
    /// against a full 300-rule store: 0.23 ms, versus 4.05 ms for the regex
    /// implementation this replaces and 19.16 ms for an unindexed single pass.
    static func apply(in text: String, using corrections: [LearnedCorrection]) -> String {
        guard !corrections.isEmpty else { return text }
        // Longest first so overlapping mappings resolve predictably. The
        // secondary keys make the ordering total: Swift's sort is not
        // guaranteed stable, so equal-length rules would otherwise resolve
        // differently between runs and defeat the point of a single pass.
        let ordered = corrections.sorted {
            ($0.heard.count, $0.heard, $0.intended)
                > ($1.heard.count, $1.heard, $1.intended)
        }
        var byFirstCharacter: [Character: [LearnedCorrection]] = [:]
        for correction in ordered {
            guard let first = correction.heard.lowercased().first else { continue }
            byFirstCharacter[first, default: []].append(correction)
        }

        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            var matched = false
            // `.lowercased().first` rather than Character(_:) - lowercasing a
            // single character can yield more than one ("İ"), which would trap.
            if isWordStart(at: index, in: text),
               let lowered = text[index].lowercased().first,
               let candidates = byFirstCharacter[lowered] {
                for correction in candidates {
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
            // A heavily rewritten transcript must not produce an unbounded toast.
            (LearnOutcome(learned: [], skipped: [
                LearnedPair(heard: "my", intended: "a"),
                LearnedPair(heard: "have", intended: "work"),
                LearnedPair(heard: "God", intended: "guide"),
                LearnedPair(heard: "form", intended: "forum"),
             ]),
             "Skipped “my”, “have” and 2 more - too common to rewrite safely."),
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
struct LearnedPair: Equatable {
    var heard: String
    var intended: String
}

/// What a transcript fix taught Murmur, and what it declined to learn.
struct LearnOutcome: Equatable {
    var learned: [LearnedPair] = []
    var skipped: [LearnedPair] = []

    /// Names both outcomes so a rejected mapping is visible rather than silent.
    /// Long lists are capped - the toast is a one-line hint, not a report, and
    /// a transcript rewritten heavily can produce a dozen candidates.
    var summary: String {
        var parts: [String] = []
        if !learned.isEmpty {
            parts.append("Learned " + Self.list(
                learned.map { "“\($0.heard)” → “\($0.intended)”" }))
        }
        if !skipped.isEmpty {
            parts.append("Skipped " + Self.list(skipped.map { "“\($0.heard)”" })
                + " - too common to rewrite safely")
        }
        guard !parts.isEmpty else { return "Transcript updated." }
        return parts.joined(separator: ". ") + "."
    }

    /// Joins up to two items, summarising any remainder as a count.
    private static func list(_ items: [String]) -> String {
        guard items.count > 2 else { return items.joined(separator: ", ") }
        return items.prefix(2).joined(separator: ", ") + " and \(items.count - 2) more"
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

**Review findings addressed (Gemini, round 1 — 0 Blocker, 1 High, 1 Medium, 1 Low):**

| Finding | Resolution |
|---|---|
| High: duplicate `heard` with differing `intended` leaves a dead rule and an arbitrary winner | `add` now matches on `heard` alone and overwrites `intended`, resetting `timesSeen`. Also hardened the sort — Swift's `sorted(by:)` is not stable, so equal-length rules were non-deterministic; the ordering is now total on `(count, heard, intended)`, with a regression test. |
| High: `learnFeedback` might be `Int?` | Not applicable. Verified `MainView.swift:361` already declares `@State private var learnFeedback: String?`. No change needed. |
| Medium: toast could overflow on a heavily rewritten transcript | `LearnOutcome.summary` caps at two named items plus "and N more", with a test. |
| Medium: `NSSpellChecker` first-call hitch; warm it up at launch | Declined. The checker is only reached from "Save & Learn" and Voice Training, both interactive; it is never on the dictation path (`apply` does not consult it). A speculative warm-up would add launch code to a PR whose value is a bug fix. |
| Low: `_` treated as a word boundary, unlike regex `\b` | Accepted. Underscores do not occur in speech transcripts. |
| Low: unused `Codable` on `LearnedPair` | Dropped the conformance. The sync plan can add it when something actually serialises it. |
| Low: misplaced comment in `SystemWordChecker` | Reworded as a doc comment stating the precondition on the parameter. |

**Review findings addressed (Gemini, round 2 — 0 Blocker, 1 High, 1 Medium, 1 Low):**

| Finding | Resolution |
|---|---|
| High: `apply` matches inside contractions — `can` rewrites `can't` | **Declined: not a regression.** Reproduced upstream's current `apply`; ICU's `\b` treats `'` as a boundary, so today's code already yields `"CAN't stop"`. This implementation preserves that exactly. Fixing it changes behaviour beyond the collapse bug and belongs in a separate PR. Recorded as a follow-up. |
| High: `apply` loses the capitalisation of the matched text | **Declined: not a regression.** Upstream already substitutes the stored `intended` verbatim — `"Focus is good"` with `focus`→`phocus` yields `"phocus is good"` today. Case-forcing would also corrupt deliberately-uppercase rules such as `JPEG`. Recorded as a follow-up. |
| Medium: legacy poison is unrepairable — the guard rejects updates to a pre-existing bad rule | **Adopted, and it is the most valuable finding in either round.** Anyone who poisoned their store before this ships could never fix `have`→`work` by re-correcting. Extracted `shouldStore`, which permits updating a rule whose `heard` already exists: exposure is unchanged (still one rule for that phrase) and the user regains a repair path. Pure, so it is covered by three new self-test cases. |
| Medium: `zh-Hans-CN` does not map to an installed dictionary by hyphen replacement | Adopted. `SystemWordChecker` now falls back to `NSSpellChecker.language()` when the converted identifier is absent from `availableLanguages`. |
| Low: use an em-dash in the toast copy | **Declined — conflicts with a project convention.** `~/scripts/CLAUDE.md` states "No em-dashes - use regular dashes or restructure". |
| Low: acronyms reduce to length 1 and are therefore learnable | Confirmed intentional. `J Peg`→`JPEG` must remain learnable. |
| Low: redundant lowercasing in `normalizedForComparison` | No action. Called at most twice per candidate mapping, off any hot path. |

**Review findings addressed (Gemini, round 3 — 0 Blocker, 2 High, 2 Medium, 1 Low):**

| Finding | Resolution |
|---|---|
| High: `apply` is O(words x 300) and may hitch the main thread | **Adopted — the review was right and my assumption was wrong.** I expected the single pass to beat 300 regex scans; measured, it was 4.7x *slower* (19.16 ms vs 4.05 ms on a 500-word transcript with a full store). Indexing corrections by first character brings it to **0.23 ms, 18x faster than upstream**, with the collapse, order-independence and whole-word tests still passing. |
| High: single-letter words like "a" and "I" are unprotected | **Declined: already handled, one layer up.** `isValidMapping` requires `heard.count >= 2`, so `"a"`→`"uh"` is rejected before `isOrdinaryWord` is ever consulted. The `< 2` rule applies to *tokens within* a phrase, which is what keeps `J Peg`→`JPEG` learnable. Residual: a multi-token phrase of single letters (`"a b"`) escapes the ordinary-speech guard - accepted, since it only fires on that exact sequence. |
| Medium: FIFO eviction drops actively-corrected rules | Adopted. Updating a rule now removes and re-appends it, so the 300-item cap discards stale entries rather than frequently-corrected ones. |
| Medium: mutable `static var wordChecker` will break under Swift 6 | Adopted. Marked `nonisolated(unsafe)` with a comment recording that access is main-actor-only in practice. |
| Low: words with internal punctuation ("state-of-the-art") fail `isKnownWord` | Accepted. They are classified non-ordinary and stay learnable, which is the safe direction: the guard's job is to block rules on *plainly ordinary* words. |

**Review findings addressed (Gemini, round 4 — 0 Blocker, 1 High, 1 Medium, 3 Low; review
opened "the findings below are minor"):**

| Finding | Resolution |
|---|---|
| High: corrections longer than 4 words are dropped silently, and the toast will not say why | **Declined: pre-existing and unchanged.** The `removed.count <= 4` limit is upstream's (`LearnedStore.swift:187`); this PR neither adds nor widens it, and "Transcript updated." remains truthful because nothing was learned. Noted as a follow-up, since it is a genuine gap in the inline-feedback promise. |
| Medium: a future caller could invoke `add` off the main actor and race `wordChecker` | Accepted as documented. `nonisolated(unsafe)` plus the doc comment is the appropriate weight for a bug-fix PR; a real fix means annotating `LearnedStore` `@MainActor`, which upstream should decide. |
| Low: `SystemWordChecker` caches the locale until relaunch | Accepted. Matches how the rest of `Settings` is read, and the app already requires a relaunch for several preferences. |
| Low: `FixedWordChecker` word lists are duplicated across Task 1 and Task 2 tests | Accepted. Each task's list is deliberately self-contained so a task can be implemented and verified in isolation. |
| Low: `apply` degrades to O(words x rules) if every rule shares a first letter | Accepted as theoretical. Requires all 300 rules to begin with the same character; worst case remains bounded by the pre-existing 300-rule cap. |

**Follow-ups deliberately out of scope for this PR** (all pre-existing, all verified
against upstream's current code): contraction-boundary matching, case preservation of
the matched text, and silent rejection of corrections longer than four words.

**Type consistency check:** `isUsefulMapping` takes `existing:`/`checker:` in Tasks 2
and is called with both in Task 2's test. `add` returns `Bool` in Task 2 and is consumed
as `Bool` in Task 4. `LearnOutcome.summary` is defined in Task 4 and used in Task 4's
MainView change. `apply(in:using:)` is defined in Task 3 and used in Task 3's tests only.
No forward references to undefined types.
