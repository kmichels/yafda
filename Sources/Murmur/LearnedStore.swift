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
                + " — Murmur won’t rewrite \(skipped.count == 1 ? "that" : "those")"
                + " automatically")
        }
        guard !parts.isEmpty else { return "Transcript updated." }
        return parts.joined(separator: ". ") + "."
    }

    /// Joins up to two items, summarising any remainder as a count.
    private static func list(_ items: [String]) -> String {
        if items.count == 2 { return items.joined(separator: " and ") }
        guard items.count > 2 else { return items.joined(separator: ", ") }
        return items.prefix(2).joined(separator: ", ") + " and \(items.count - 2) more"
    }
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
    /// to store, when no `checker:` is injected. Self-tests never rely on
    /// this default - they always pass their own `FixedWordChecker` instead.
    private static let defaultWordChecker: WordChecker = SystemWordChecker()

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

    /// Applies one mapping to an in-memory store.
    /// - Returns: whether the mapping was stored. A rejected mapping still
    ///   contributes its intended wording as a recognition-bias term.
    static func record(heard: String, intended: String,
                       in learned: inout LearnedData,
                       checker: WordChecker? = nil) -> Bool {
        let heardTrimmed = normalizePhrase(heard)
        let intendedTrimmed = intended.trimmingCharacters(in: .whitespacesAndNewlines)
        guard shouldStore(heard: heardTrimmed, intended: intendedTrimmed,
                          existing: learned.corrections, checker: checker) else {
            // Still worth biasing recognition toward the intended wording.
            appendTerm(intendedTrimmed, to: &learned)
            return false
        }
        learned.corrections = merging(learned.corrections,
                                      heard: heardTrimmed, intended: intendedTrimmed)
        if learned.corrections.count > 300 {
            learned.corrections.removeFirst(learned.corrections.count - 300)
        }
        appendTerm(intendedTrimmed, to: &learned)
        return true
    }

    /// Adds one mapping (merging duplicates) and remembers the intended term.
    /// - Returns: whether the mapping was stored. A rejected mapping still
    ///   contributes its intended wording as a recognition-bias term.
    @discardableResult
    static func add(heard: String, intended: String) -> Bool {
        var learned = load()
        let stored = record(heard: heard, intended: intended, in: &learned)
        save(learned)
        return stored
    }

    /// Folds `heard -> intended` into `corrections`, collapsing every existing
    /// rule for that phrase into one.
    ///
    /// Stores written before these guards existed used (heard, intended) as the
    /// duplicate key, so they can hold several rules for one phrase. Leaving any
    /// behind would let apply() pick a stale rule after the user repairs one.
    static func merging(_ corrections: [LearnedCorrection],
                        heard: String, intended: String) -> [LearnedCorrection] {
        var result = corrections
        var removed: [LearnedCorrection] = []
        var index = 0
        while index < result.count {
            if result[index].heard.lowercased() == heard.lowercased() {
                removed.append(result.remove(at: index))
            } else {
                index += 1
            }
        }
        var merged = LearnedCorrection(heard: heard, intended: intended)
        // Preserve the first removed rule's id so the Voice Training delete
        // button keeps pointing at the same row across a repair.
        if let firstID = removed.first?.id {
            merged.id = firstID
        }
        // Only a removed rule for the same intended phrase speaks to how many
        // times this exact mapping has been confirmed; a rule with a
        // different intended was a different correction entirely.
        if let priorTimesSeen = removed.filter({ $0.intended == intended })
            .map(\.timesSeen).max() {
            merged.timesSeen = priorTimesSeen + 1
        } else {
            merged.timesSeen = 1
        }
        result.append(merged)
        return result
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
    /// substitutions and stores those that pass the guards.
    /// - Returns: the mappings learned and those skipped.
    @discardableResult
    static func learn(original: String, corrected: String) -> LearnOutcome {
        var outcome = LearnOutcome()
        var learned = load()
        for candidate in extractCorrections(original: original, corrected: corrected) {
            let pair = LearnedPair(heard: candidate.heard, intended: candidate.intended)
            if record(heard: candidate.heard, intended: candidate.intended, in: &learned) {
                outcome.learned.append(pair)
            } else {
                outcome.skipped.append(pair)
            }
        }
        save(learned)
        return outcome
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
    /// the few rules that could begin there: on a full 300-rule store, this
    /// makes lookup roughly an order of magnitude faster than an unindexed
    /// single pass, and comfortably faster than the regex implementation it
    /// replaces.
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
        // Narrower than Foundation's case-insensitive match: ß, final sigma ς,
        // and the ﬁ/ﬃ ligatures (compatibility decompositions/case-folding)
        // can be missed - safe since canonical accents (é vs e + ´) hash
        // identically as `Character`, and none of these forms start a dictated word.
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
        let checker = checker ?? defaultWordChecker
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
             "dog"),
            ("ties order independent",
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

        // MARK: Outcome summaries
        let summaryCases: [(outcome: LearnOutcome, expected: String)] = [
            (LearnOutcome(), "Transcript updated."),
            (LearnOutcome(learned: [LearnedPair(heard: "Lightrim", intended: "Lightroom")],
                          skipped: []),
             "Learned “Lightrim” → “Lightroom”."),
            (LearnOutcome(learned: [],
                          skipped: [LearnedPair(heard: "have", intended: "work")]),
             "Skipped “have” — Murmur won’t rewrite that automatically."),
            (LearnOutcome(learned: [LearnedPair(heard: "JPIG", intended: "JPEG")],
                          skipped: [LearnedPair(heard: "my", intended: "a")]),
             "Learned “JPIG” → “JPEG”. Skipped “my” — Murmur won’t rewrite that automatically."),
            (LearnOutcome(learned: [],
                          skipped: [LearnedPair(heard: "have", intended: "work"),
                                    LearnedPair(heard: "my", intended: "a")]),
             "Skipped “have” and “my” — Murmur won’t rewrite those automatically."),
            // A heavily rewritten transcript must not produce an unbounded toast.
            (LearnOutcome(learned: [], skipped: [
                LearnedPair(heard: "my", intended: "a"),
                LearnedPair(heard: "have", intended: "work"),
                LearnedPair(heard: "God", intended: "guide"),
                LearnedPair(heard: "form", intended: "forum"),
             ]),
             "Skipped “my”, “have” and 2 more — Murmur won’t rewrite those automatically."),
        ]
        for testCase in summaryCases {
            let got = testCase.outcome.summary
            let ok = got == testCase.expected
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): summary = \"\(got)\"" +
                  (ok ? "" : " (expected \"\(testCase.expected)\")"))
        }

        // MARK: Merging duplicate rules
        // Stores written before these guards existed used (heard, intended) as
        // the duplicate key, so a store can hold several rules for one heard
        // phrase. merging() must collapse every one of them so apply() cannot
        // pick a stale rule after the user repairs it.
        let mergeCases: [(name: String, before: [LearnedCorrection], heard: String,
                          intended: String, expectedIntended: String,
                          expectedTimesSeen: Int)] = [
            ("legacy duplicates collapse",
             [LearnedCorrection(heard: "have", intended: "work"),
              LearnedCorrection(heard: "have", intended: "halve")],
             "have", "half", "half", 1),
            ("repeat mapping increments",
             [LearnedCorrection(heard: "have", intended: "work")],
             "have", "work", "work", 2),
            ("new phrase appends",
             [], "Lightrim", "Lightroom", "Lightroom", 1),
        ]
        for testCase in mergeCases {
            let merged = LearnedStore.merging(testCase.before, heard: testCase.heard,
                                              intended: testCase.intended)
            let rules = merged.filter { $0.heard.lowercased() == testCase.heard.lowercased() }
            let ok = rules.count == 1
                && rules[0].intended == testCase.expectedIntended
                && rules[0].timesSeen == testCase.expectedTimesSeen
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): merging(\(testCase.name)) = " +
                  "\(merged.map { "\($0.heard)->\($0.intended)(\($0.timesSeen))" })")
        }

        // Unrelated rules must survive a merge targeting a different phrase.
        let unrelatedBefore = [LearnedCorrection(heard: "alpha", intended: "beta"),
                               LearnedCorrection(heard: "have", intended: "work")]
        let unrelatedMerged = LearnedStore.merging(unrelatedBefore, heard: "have", intended: "half")
        let unrelatedOK = unrelatedMerged.contains { $0.heard == "alpha" && $0.intended == "beta" }
        if !unrelatedOK { passed = false }
        print("\(unrelatedOK ? "PASS" : "FAIL"): merging(unrelated rules preserved) = " +
              "\(unrelatedMerged.map { "\($0.heard)->\($0.intended)" })")

        // End-to-end through the real apply: after collapsing legacy
        // duplicates, the repair actually changes what apply() produces -
        // this is the bug the whole fix exists to close.
        let repaired = LearnedStore.apply(in: "I have it", using: LearnedStore.merging(
            [LearnedCorrection(heard: "have", intended: "work"),
             LearnedCorrection(heard: "have", intended: "halve")],
            heard: "have", intended: "half"))
        let repairedOK = repaired == "I half it"
        if !repairedOK { passed = false }
        print("\(repairedOK ? "PASS" : "FAIL"): apply/merged repair = \"\(repaired)\"" +
              (repairedOK ? "" : " (expected \"I half it\")"))

        // MARK: record() - the disk-free core that add() and learn() both drive
        // add() and learn() each hide the in-memory store behind their own
        // load/save, so record() is the only seam where these cases can see
        // the store directly.
        let recordChecker = FixedWordChecker(words: ["have", "work"])

        var storedLearned = LearnedData()
        let storedResult = LearnedStore.record(
            heard: "Lightrim", intended: "Lightroom",
            in: &storedLearned, checker: recordChecker)
        let storedOK = storedResult
            && storedLearned.corrections.contains {
                $0.heard == "Lightrim" && $0.intended == "Lightroom"
            }
        if !storedOK { passed = false }
        print("\(storedOK ? "PASS" : "FAIL"): record(\"Lightrim\" -> \"Lightroom\") = " +
              "\(storedResult), corrections = " +
              "\(storedLearned.corrections.map { "\($0.heard)->\($0.intended)" })")

        // Refused by the ordinary-speech guard: both words are in the
        // checker's dictionary, so this must not become a global rewrite -
        // but the intended wording still gets remembered for bias.
        var refusedLearned = LearnedData()
        let refusedResult = LearnedStore.record(
            heard: "have", intended: "work",
            in: &refusedLearned, checker: recordChecker)
        let refusedOK = !refusedResult
            && !refusedLearned.corrections.contains { $0.heard == "have" }
            && refusedLearned.terms.contains("work")
        if !refusedOK { passed = false }
        print("\(refusedOK ? "PASS" : "FAIL"): record(\"have\" -> \"work\") = " +
              "\(refusedResult), corrections = " +
              "\(refusedLearned.corrections.map { "\($0.heard)->\($0.intended)" })" +
              ", terms = \(refusedLearned.terms)")

        // Two successive calls against the same inout store must accumulate:
        // the second call sees the first's stored mapping and refuses its
        // reverse, exactly as reload-per-candidate would have after the
        // first call's save() landed on disk.
        var accumulating = LearnedData()
        let firstResult = LearnedStore.record(
            heard: "alpha", intended: "beta",
            in: &accumulating, checker: recordChecker)
        let secondResult = LearnedStore.record(
            heard: "beta", intended: "alpha",
            in: &accumulating, checker: recordChecker)
        let accumulatedOK = firstResult && !secondResult
            && accumulating.corrections.count == 1
            && accumulating.corrections.contains {
                $0.heard == "alpha" && $0.intended == "beta"
            }
        if !accumulatedOK { passed = false }
        print("\(accumulatedOK ? "PASS" : "FAIL"): record(\"alpha\"->\"beta\" then " +
              "\"beta\"->\"alpha\") = \(firstResult), \(secondResult), corrections = " +
              "\(accumulating.corrections.map { "\($0.heard)->\($0.intended)" })")

        // MARK: Audio device enumeration
        // CoreAudio results depend on what is plugged in, so assert contracts
        // rather than specific hardware. A machine with no inputs must pass too.
        let devices = AudioDevices.inputDevices()
        let wellFormed = devices.allSatisfy { !$0.uid.isEmpty && !$0.name.isEmpty }
        if !wellFormed { passed = false }
        print("\(wellFormed ? "PASS" : "FAIL"): \(devices.count) input device(s), " +
              "all with a uid and name")

        let uniqueUIDs = Set(devices.map(\.uid)).count == devices.count
        if !uniqueUIDs { passed = false }
        print("\(uniqueUIDs ? "PASS" : "FAIL"): device UIDs are unique")

        // The stored preference is a UID, so this round trip is the contract
        // that makes the setting survive a reboot or a replug.
        let roundTrips = devices.allSatisfy { AudioDevices.device(uid: $0.uid)?.uid == $0.uid }
        if !roundTrips { passed = false }
        print("\(roundTrips ? "PASS" : "FAIL"): every device resolves back by UID")

        let unknownIsNil = AudioDevices.device(uid: "no-such-device-uid") == nil
        if !unknownIsNil { passed = false }
        print("\(unknownIsNil ? "PASS" : "FAIL"): unknown UID resolves to nil")

        let stable = AudioDevices.inputDevices().map(\.uid) == devices.map(\.uid)
        if !stable { passed = false }
        print("\(stable ? "PASS" : "FAIL"): enumeration is stable across calls")

        // MARK: Level normalisation
        // Linear RMS reads near zero for ordinary speech, so the bar maps
        // -60...0 dBFS onto 0...1. These are the boundaries that matter.
        let levelCases: [(name: String, rms: Float, expected: Float)] = [
            ("silence clamps to 0", 0.0, 0.0),
            ("full scale clamps to 1", 1.0, 1.0),
            ("below floor clamps to 0", 0.0001, 0.0),
        ]
        for testCase in levelCases {
            let got = MicMonitor.normalizedLevel(rms: testCase.rms)
            let ok = abs(got - testCase.expected) < 0.001
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): level/\(testCase.name) = \(got)")
        }
        // Quiet speech must land in the visible middle, not pinned at either end.
        let speech = MicMonitor.normalizedLevel(rms: 0.03)   // about -30 dBFS
        let speechOK = speech > 0.3 && speech < 0.7
        if !speechOK { passed = false }
        print("\(speechOK ? "PASS" : "FAIL"): level/speech is mid-scale = \(speech)")

        return passed
    }
}
