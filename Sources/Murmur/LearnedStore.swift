import Foundation

struct LearnedCorrection: Codable, Identifiable, Equatable {
    var id = UUID()
    /// What the recognizer heard.
    var heard: String
    /// What the user actually said.
    var intended: String
    var timesSeen: Int = 1
}

struct LearnedData: Codable {
    var corrections: [LearnedCorrection] = []
    /// Words/phrases the user has taught (used for recognition biasing
    /// even when no correction mapping is needed).
    var terms: [String] = []
}

/// Murmur's pronunciation memory. Populated by the Voice Training page and
/// by corrections the user makes to transcripts in History. Used two ways:
/// 1. `apply(in:)` fixes known mishearings in every transcript.
/// 2. `biasTerms()` feeds the user's vocabulary into the speech model
///    before recognition (AnalysisContext contextual strings).
enum LearnedStore {
    static var fileURL: URL {
        AppPaths.supportDirectory.appendingPathComponent("learned.json")
    }

    /// Checker used to decide whether an automatically-diffed mapping is safe
    /// to store. Overridable so self-tests are deterministic.
    ///
    /// Only ever touched from the main actor (transcript fixes and Voice
    /// Training are both UI actions); marked explicitly so a future move to
    /// Swift 6 language mode does not turn this into a build error.
    nonisolated(unsafe) static var wordChecker: WordChecker = SystemWordChecker()

    static func load() -> LearnedData {
        guard let data = try? Data(contentsOf: fileURL),
              let learned = try? JSONDecoder().decode(LearnedData.self, from: data)
        else { return LearnedData() }
        return learned
    }

    static func save(_ learned: LearnedData) {
        if let data = try? JSONEncoder().encode(learned) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: - Recording new knowledge

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

    /// Remembers a term for recognition biasing without any mapping.
    static func addTerm(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var learned = load()
        appendTerm(trimmed, to: &learned)
        save(learned)
    }

    private static func appendTerm(_ term: String, to learned: inout LearnedData) {
        guard !term.isEmpty,
              !learned.terms.contains(where: { $0.lowercased() == term.lowercased() })
        else { return }
        learned.terms.append(term)
        if learned.terms.count > 300 {
            learned.terms.removeFirst(learned.terms.count - 300)
        }
    }

    /// Learns from a user-corrected transcript: extracts word-level
    /// substitutions and stores each. Returns how many were learned.
    @discardableResult
    static func learn(original: String, corrected: String) -> Int {
        let pairs = extractCorrections(original: original, corrected: corrected)
        for pair in pairs {
            add(heard: pair.heard, intended: pair.intended)
        }
        return pairs.count
    }

    // MARK: - Using the knowledge

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

    /// Vocabulary handed to the speech model before recognition:
    /// taught terms, learned spellings, dictionary spellings, snippet triggers.
    static func biasTerms() -> [String] {
        var terms: [String] = []
        var seen = Set<String>()
        func insert(_ term: String) {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = trimmed.lowercased()
            guard !trimmed.isEmpty, trimmed.count > 1, !seen.contains(key)
            else { return }
            seen.insert(key)
            terms.append(trimmed)
        }
        let learned = load()
        learned.terms.forEach(insert)
        learned.corrections.map(\.intended).forEach(insert)
        TextFormatter.loadDictionary().values.forEach(insert)
        SnippetStore.load().map(\.trigger).forEach(insert)
        return Array(terms.prefix(300))
    }

    // MARK: - Diff extraction

    /// Word-level diff between the original transcript and the user's
    /// correction. Returns substituted runs (up to 4 words long) as candidate
    /// heard -> intended pairs. Candidates are not yet validated; `add` applies
    /// the guards and reports which were rejected.
    static func extractCorrections(
        original: String, corrected: String) -> [(heard: String, intended: String)] {
        let originalWords = tokenize(original)
        let correctedWords = tokenize(corrected)
        guard !originalWords.isEmpty, !correctedWords.isEmpty else { return [] }

        // Longest common subsequence over normalized tokens.
        let n = originalWords.count
        let m = correctedWords.count
        var lcs = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                if originalWords[i].key == correctedWords[j].key {
                    lcs[i][j] = lcs[i + 1][j + 1] + 1
                } else {
                    lcs[i][j] = max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }

        var pairs: [(heard: String, intended: String)] = []
        var i = 0
        var j = 0
        while i < n, j < m {
            if originalWords[i].key == correctedWords[j].key {
                i += 1
                j += 1
                continue
            }
            // Collect one substituted run on each side.
            var removed: [String] = []
            var added: [String] = []
            while i < n, j < m, originalWords[i].key != correctedWords[j].key {
                if lcs[i + 1][j] >= lcs[i][j + 1] {
                    removed.append(originalWords[i].raw)
                    i += 1
                } else {
                    added.append(correctedWords[j].raw)
                    j += 1
                }
                // A pure insertion or deletion isn't a pronunciation fix.
                if i >= n || j >= m { break }
            }
            if !removed.isEmpty, !added.isEmpty,
               removed.count <= 4, added.count <= 4 {
                let heard = normalizePhrase(removed.joined(separator: " "))
                let intended = added.joined(separator: " ")
                    .trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
                if !heard.isEmpty, !intended.isEmpty {
                    pairs.append((heard, intended))
                }
            }
        }
        return pairs
    }

    private static func tokenize(_ text: String) -> [(raw: String, key: String)] {
        text.split(whereSeparator: { $0.isWhitespace }).map { token in
            let raw = String(token)
            let key = raw.lowercased()
                .trimmingCharacters(in: .punctuationCharacters)
            return (raw, key)
        }
    }

    private static func normalizePhrase(_ phrase: String) -> String {
        phrase
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:"))
    }

    /// Whether a mapping is safe to store as a global rewrite rule.
    ///
    /// - Parameters:
    ///   - existing: corrections already stored, used to refuse the second half
    ///     of an A -> B / B -> A pair, which would otherwise collapse both
    ///     words into one.
    ///   - checker: injectable so self-tests do not depend on the user's
    ///     spelling dictionary.
    private static func isUsefulMapping(heard: String, intended: String,
                                        existing: [LearnedCorrection],
                                        checker: WordChecker?) -> Bool {
        let checker = checker ?? wordChecker
        guard isValidMapping(heard: heard, intended: intended) else { return false }

        // A correction fires as a global whole-word rewrite. If the misheard
        // side is made entirely of ordinary words, it rewrites speech the user
        // never meant to change. The exception is a genuine re-segmentation of
        // the same sounds ("base ten" -> "Baseten"); a same-boundary
        // punctuation edit ("its" -> "it's") is not, and neither is a split
        // whose joined form is itself a real word ("set up" -> "setup") - both
        // would rewrite ordinary speech wherever it occurs.
        if checker.isOrdinaryPhrase(heard),
           !isResegmentation(of: heard, to: intended, checker: checker) {
            return false
        }

        if isReverseOfExistingMapping(heard: heard, intended: intended, existing: existing) {
            return false
        }
        return true
    }

    /// The structural checks every mapping must pass, guards aside.
    private static func isValidMapping(heard: String, intended: String) -> Bool {
        heard.count >= 2 && !intended.isEmpty
            && heard.lowercased() != intended.lowercased()
    }

    /// Whether `add` should store this mapping given what is already stored.
    ///
    /// Updating a rule that already exists adds no new exposure - there is
    /// still exactly one rule for that phrase. Refusing the update would trap
    /// anyone whose store was poisoned before these guards existed, leaving the
    /// Voice Training delete button as their only escape. That bypass only
    /// applies to the ordinary-phrase guard, though: the reverse-mapping check
    /// runs unconditionally, since letting an update recreate an A -> B / B ->
    /// A pair would still collapse both terms in `apply`.
    private static func shouldStore(heard: String, intended: String,
                                    existing: [LearnedCorrection],
                                    checker: WordChecker? = nil) -> Bool {
        guard isValidMapping(heard: heard, intended: intended) else { return false }
        if isReverseOfExistingMapping(heard: heard, intended: intended, existing: existing) {
            return false
        }
        if existing.contains(where: { $0.heard.lowercased() == heard.lowercased() }) {
            return true
        }
        return isUsefulMapping(heard: heard, intended: intended,
                               existing: existing, checker: checker)
    }

    /// A -> B alongside B -> A rewrites every occurrence of both to one value.
    private static func isReverseOfExistingMapping(
        heard: String, intended: String, existing: [LearnedCorrection]) -> Bool {
        existing.contains(where: {
            $0.heard.lowercased() == intended.lowercased()
                && $0.intended.lowercased() == heard.lowercased()
        })
    }

    /// A re-segmentation moves word boundaries without changing the sounds, and
    /// lands on something that is not itself ordinary language ("base ten" ->
    /// "Baseten"). That only ever happens as a join: the recognizer split one
    /// term across a whitespace boundary, so the intended side must have
    /// fewer tokens than the heard side. Expanding one ordinary word into
    /// several ("apart" -> "a part") is never a re-segmentation, no matter
    /// how it normalizes - a single common word is the highest-exposure
    /// rewrite key there is, and treating its expansion as a join would learn
    /// it globally forever. A same-boundary punctuation edit ("its" -> "it's")
    /// is not a re-segmentation either, and neither is a split whose joined
    /// form is a real word ("set up" -> "setup") - both would rewrite
    /// ordinary speech wherever it occurs.
    private static func isResegmentation(of heard: String, to intended: String,
                                         checker: WordChecker) -> Bool {
        normalizedForComparison(heard) == normalizedForComparison(intended)
            && heard.split(whereSeparator: { $0.isWhitespace }).count
                > intended.split(whereSeparator: { $0.isWhitespace }).count
            && !checker.isOrdinaryPhrase(intended)
    }

    /// Lowercased with every non-alphanumeric character removed, so that
    /// "base ten" and "Baseten" compare equal.
    private static func normalizedForComparison(_ text: String) -> String {
        String(String.UnicodeScalarView(
            text.lowercased().unicodeScalars.filter {
                CharacterSet.alphanumerics.contains($0)
            }))
    }

    // MARK: - Self test

    static func runSelfTest() -> Bool {
        let cases: [(original: String, corrected: String,
                     expected: [(String, String)])] = [
            ("Send it to Soren today.", "Send it to Søren today.",
             [("Soren", "Søren")]),
            ("The base ten pipeline is fast.", "The Baseten pipeline is fast.",
             [("base ten", "Baseten")]),
            ("Hello world.", "Hello world.", []),
            ("I met so ren and Anna.", "I met Søren and Anna.",
             [("so ren", "Søren")]),
        ]
        var passed = true
        for testCase in cases {
            let got = extractCorrections(
                original: testCase.original, corrected: testCase.corrected)
            let ok = got.count == testCase.expected.count
                && zip(got, testCase.expected).allSatisfy {
                    $0.0.heard == $0.1.0 && $0.0.intended == $0.1.1
                }
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): diff(\"\(testCase.original)\" → " +
                  "\"\(testCase.corrected)\") = \(got)")
        }

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

        // MARK: Mapping guards
        let guardChecker = FixedWordChecker(words: [
            "have", "work", "he", "caught", "base", "ten", "so", "my", "a", "focus", "its",
            "set", "up", "setup", "apart", "part",
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
            ("its", "it's", false, "punctuation edit on an ordinary word is not a re-segmentation"),
            ("set up", "setup", false, "a split whose joined form is a real word is not a re-segmentation"),
            ("apart", "a part", false, "expanding one ordinary word is not a re-segmentation"),
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

        // The existing-rule bypass must not skip the reverse guard: with
        // alpha -> beta and beta -> gamma already stored, beta -> alpha shares
        // its `heard` with the second rule (bypass-eligible) but is also the
        // reverse of the first, which apply() would collapse together.
        let chained = [
            LearnedCorrection(heard: "alpha", intended: "beta"),
            LearnedCorrection(heard: "beta", intended: "gamma"),
        ]
        let reverseGuardCases: [(heard: String, intended: String, store: Bool, why: String)] = [
            ("beta", "alpha", false, "reverse guard survives the existing-rule bypass"),
        ]
        for testCase in reverseGuardCases {
            let got = LearnedStore.shouldStore(
                heard: testCase.heard, intended: testCase.intended,
                existing: chained, checker: guardChecker)
            let ok = got == testCase.store
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): shouldStore(\"\(testCase.heard)\" -> " +
                  "\"\(testCase.intended)\") = \(got) [\(testCase.why)]")
        }

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

        return passed
    }
}
