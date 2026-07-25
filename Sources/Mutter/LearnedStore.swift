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

/// One rule that fired during a single `applyReportingMatches` pass, and how
/// many occurrences it replaced. AMUX-755: `apply(in:)` rewrites used to be
/// invisible, so a poisoned rule took hours to diagnose - this is what lets
/// History show which rule fired on a given transcript.
struct AppliedCorrection: Codable, Equatable {
    var heard: String
    var intended: String
    var count: Int
}

/// What a transcript fix taught Mutter, and what it declined to learn.
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
                + " — Mutter won’t rewrite \(skipped.count == 1 ? "that" : "those")"
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

/// Mutter's pronunciation memory. Populated by the Voice Training page and
/// by corrections the user makes to transcripts in History. Used two ways:
/// 1. `apply(in:)` fixes known mishearings in every transcript.
/// 2. `biasTerms()` feeds the user's vocabulary into the speech model
///    before recognition (AnalysisContext contextual strings).
enum LearnedStore {
    /// Tests point this at a temp directory; nil in normal operation.
    static var directoryOverride: URL?
    static var fileURL: URL {
        (directoryOverride ?? AppPaths.supportDirectory).appendingPathComponent("learned.json")
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

    @discardableResult
    static func save(_ learned: LearnedData) -> Bool {
        guard let data = try? JSONEncoder().encode(learned) else { return false }
        do {
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Recording new knowledge

    /// Applies one mapping to an in-memory store.
    /// - Parameter taughtWords: words the user explicitly taught (a
    ///   `VocabularyStore` snapshot, in production), unioned here with
    ///   `learned.terms` before being checked. Non-nil only on the automatic
    ///   path (`learn()`) - the explicit path (`add()`, driven by Voice
    ///   Training and Dictionary corrections) never passes it, which is what
    ///   keeps that path unaffected by the taught-word guard.
    /// - Returns: whether the mapping was stored. A rejected mapping still
    ///   contributes its intended wording as a recognition-bias term.
    static func record(heard: String, intended: String,
                       in learned: inout LearnedData,
                       checker: WordChecker? = nil,
                       taughtWords: Set<String>? = nil) -> Bool {
        let heardTrimmed = normalizePhrase(heard)
        let intendedTrimmed = intended.trimmingCharacters(in: .whitespacesAndNewlines)
        guard shouldStore(heard: heardTrimmed, intended: intendedTrimmed,
                          existing: learned.corrections, checker: checker,
                          taughtWords: taughtWords.map { $0.union(learned.terms) }) else {
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

    /// Removes a taught term case-insensitively. The Training page's delete
    /// button drives this directly, so it reloads and saves like `addTerm`
    /// rather than taking an inout store - callers never see a stale copy.
    /// - Returns: whether a term was actually removed.
    @discardableResult
    static func removeTerm(_ term: String) -> Bool {
        var learned = load()
        let key = term.lowercased()
        let countBefore = learned.terms.count
        learned.terms.removeAll { $0.lowercased() == key }
        guard learned.terms.count != countBefore else { return false }
        save(learned)
        return true
    }

    /// Learns from a user-corrected transcript: extracts word-level
    /// substitutions and stores those that pass the guards.
    /// - Parameter taughtWords: words the user explicitly taught, for the
    ///   taught-word guard. Defaults to the real `VocabularyStore` snapshot -
    ///   self-tests must always inject their own so they never read
    ///   vocabulary.json.
    /// - Returns: the mappings learned and those skipped.
    @discardableResult
    static func learn(original: String, corrected: String,
                      checker: WordChecker? = nil,
                      taughtWords: Set<String>? = nil) -> LearnOutcome {
        // learn() is the automatic path, so it always guards against taught
        // words - unlike record()'s default, where nil means "skip the
        // guard" (the explicit path's contract).
        let effectiveTaughtWords = taughtWords ?? Set(VocabularyStore.words())
        var outcome = LearnOutcome()
        var learned = load()
        for candidate in extractCorrections(original: original, corrected: corrected) {
            let pair = LearnedPair(heard: candidate.heard, intended: candidate.intended)
            if record(heard: candidate.heard, intended: candidate.intended, in: &learned,
                     checker: checker, taughtWords: effectiveTaughtWords) {
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
    /// `text` is rewritten more than once. Thin wrapper over
    /// `applyReportingMatches`, which holds the walk - AMUX-755 added match
    /// reporting without giving the single-pass logic a second home.
    static func apply(in text: String, using corrections: [LearnedCorrection]) -> String {
        applyReportingMatches(in: text, using: corrections).text
    }

    /// Same single-pass walk as `apply(in:using:)`, additionally reporting
    /// which rules fired and how many occurrences each replaced - AMUX-755:
    /// a poisoned rule ("Konrad" -> "laptop") took hours to diagnose because
    /// transcripts arrived wrong with no trace of which rule fired.
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
    static func applyReportingMatches(
        in text: String, using corrections: [LearnedCorrection]
    ) -> (text: String, applied: [AppliedCorrection]) {
        guard !corrections.isEmpty else { return (text, []) }
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
        // Keyed by `id` rather than the (heard, intended) pair so this stays
        // correct even if a caller ever passed two rules for the same heard
        // phrase - `LearnedStore.merging` normally guarantees only one.
        // `matchOrder` preserves first-fired order, which is the order
        // History shows: whichever rule a transcript hit first, first.
        var matchOrder: [UUID] = []
        var matchedRule: [UUID: LearnedCorrection] = [:]
        var matchCounts: [UUID: Int] = [:]
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
                    if matchCounts[correction.id] == nil {
                        matchOrder.append(correction.id)
                        matchedRule[correction.id] = correction
                    }
                    matchCounts[correction.id, default: 0] += 1
                    break
                }
            }
            if !matched {
                result.append(text[index])
                index = text.index(after: index)
            }
        }
        let applied = matchOrder.compactMap { id -> AppliedCorrection? in
            guard let rule = matchedRule[id], let count = matchCounts[id] else { return nil }
            return AppliedCorrection(heard: rule.heard, intended: rule.intended, count: count)
        }
        return (result, applied)
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
        VocabularyStore.words().forEach(insert)
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
    ///
    /// - Parameter taughtWords: non-nil only on the automatic path (see
    ///   `record()`). AMUX-754: the taught-word check below runs before the
    ///   existing-rule bypass, and deliberately does not share its escape
    ///   hatch. Without that ordering, a pre-guardrail mislearned rule like
    ///   "Konrad" -> "laptop" would keep itself alive forever - every fresh
    ///   diff that reproduced it would find a rule already stored for that
    ///   `heard` phrase and slip through as an "update" rather than a refused
    ///   new rule. The explicit path never supplies `taughtWords`, so a
    ///   deliberate re-teach of a taught word's pronunciation (or a poisoned
    ///   store repair) still reaches the bypass unchanged.
    private static func shouldStore(heard: String, intended: String,
                                    existing: [LearnedCorrection],
                                    checker: WordChecker? = nil,
                                    taughtWords: Set<String>? = nil) -> Bool {
        guard isValidMapping(heard: heard, intended: intended) else { return false }
        if let taughtWords, containsTaughtWord(heard, taughtWords: taughtWords) {
            return false
        }
        if isReverseOfExistingMapping(heard: heard, intended: intended, existing: existing) {
            return false
        }
        if existing.contains(where: { $0.heard.lowercased() == heard.lowercased() }) {
            return true
        }
        return isUsefulMapping(heard: heard, intended: intended,
                               existing: existing, checker: checker)
    }

    /// Whether any whitespace-separated word in `heard` matches, case-
    /// insensitively, a word the user explicitly taught. Each `taughtWords`
    /// entry is itself split into words before comparing, so a multi-word
    /// taught entry ("Apple Vision Pro") still guards each word it contains,
    /// not just the phrase as a whole.
    ///
    /// A multi-word `heard` phrase is refused as soon as any one of its words
    /// is taught: the diff learner that produced the pre-guardrail
    /// "Konrad" -> "laptop" rule would just as readily have produced
    /// "hey Konrad" -> "hey there", and half-guarding that case would leave
    /// the exact bug this exists to close.
    private static func containsTaughtWord(_ heard: String, taughtWords: Set<String>) -> Bool {
        guard !taughtWords.isEmpty else { return false }
        let taughtLowercased = Set(taughtWords.flatMap { entry in
            entry.split(whereSeparator: { $0.isWhitespace }).map {
                $0.trimmingCharacters(in: CharacterSet.alphanumerics.inverted).lowercased()
            }
        })
        let heardWords = heard.split(whereSeparator: { $0.isWhitespace }).map {
            $0.trimmingCharacters(in: CharacterSet.alphanumerics.inverted).lowercased()
        }
        return heardWords.contains { !$0.isEmpty && taughtLowercased.contains($0) }
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

    static func runSelfTest() async -> Bool {
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

        // MARK: Taught-word guard (automatic path only)
        // AMUX-754: a pre-guardrail auto-learned rule "Konrad" -> "laptop"
        // globally rewrote the user's own name because the diff-learning path
        // never checked whether the misheard side was something the user had
        // explicitly taught. `taughtWords` is non-nil only on that automatic
        // path - the explicit path (Voice Training's add(), Dictionary
        // corrections) never supplies it - so the same heard/existing
        // combination must behave differently depending on which caller is
        // driving `shouldStore`.
        let taughtGuardCases: [(heard: String, intended: String, taughtWords: Set<String>?,
                                existing: [LearnedCorrection], store: Bool, why: String)] = [
            ("Konrad", "laptop", ["Konrad"], [], false,
             "automatic path refuses a taught heard word"),
            ("Konrad friend", "buddy pal", ["Konrad"], [], false,
             "multi-word heard refused when any constituent word is taught"),
            ("Lightrim", "Lightroom", ["Konrad"], [], true,
             "heard side is not taught, stored as before"),
            ("Konrad", "laptop", ["Konrad"],
             [LearnedCorrection(heard: "Konrad", intended: "friend")], false,
             "taught-word refusal runs before the existing-rule escape hatch"),
            ("Konrad", "laptop", nil,
             [LearnedCorrection(heard: "Konrad", intended: "friend")], true,
             "explicit path (no taughtWords) leaves the escape hatch intact"),
        ]
        for testCase in taughtGuardCases {
            let got = LearnedStore.shouldStore(
                heard: testCase.heard, intended: testCase.intended,
                existing: testCase.existing, checker: guardChecker,
                taughtWords: testCase.taughtWords)
            let ok = got == testCase.store
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): shouldStore(\"\(testCase.heard)\" -> " +
                  "\"\(testCase.intended)\", taught: " +
                  "\(testCase.taughtWords?.sorted() ?? [])) = \(got) [\(testCase.why)]")
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

        // MARK: applyReportingMatches - observability for AMUX-755
        // Same single-pass walk as apply(in:using:), additionally reporting
        // which rules fired and how many occurrences each replaced. Text
        // output must match apply(in:using:) exactly for identical input -
        // that identity is itself part of what each case asserts.
        let reportingCases: [(name: String, text: String, corrections: [LearnedCorrection],
                              expectedText: String, expectedApplied: [AppliedCorrection])] = [
            ("multi-occurrence of one rule",
             "Ask Konrad. Also tell Konrad.",
             [LearnedCorrection(heard: "Konrad", intended: "laptop")],
             "Ask laptop. Also tell laptop.",
             [AppliedCorrection(heard: "Konrad", intended: "laptop", count: 2)]),
            ("overlapping rules counted separately, in first-match order",
             "focus Phocus focus",
             [LearnedCorrection(heard: "focus", intended: "Phocus"),
              LearnedCorrection(heard: "Phocus", intended: "focus")],
             "Phocus focus Phocus",
             [AppliedCorrection(heard: "focus", intended: "Phocus", count: 2),
              AppliedCorrection(heard: "Phocus", intended: "focus", count: 1)]),
            ("no matches reports empty applied",
             "Hello world.", [LearnedCorrection(heard: "Konrad", intended: "laptop")],
             "Hello world.", []),
            ("empty corpus reports empty applied",
             "untouched", [], "untouched", []),
        ]
        for testCase in reportingCases {
            let got = LearnedStore.applyReportingMatches(
                in: testCase.text, using: testCase.corrections)
            let plain = LearnedStore.apply(in: testCase.text, using: testCase.corrections)
            let ok = got.text == testCase.expectedText
                && got.applied == testCase.expectedApplied
                && got.text == plain
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): applyReportingMatches/\(testCase.name) = " +
                  "text: \"\(got.text)\", applied: \(got.applied)" +
                  (ok ? "" : " (expected text: \"\(testCase.expectedText)\", " +
                        "applied: \(testCase.expectedApplied))"))
        }

        // MARK: Outcome summaries
        let summaryCases: [(outcome: LearnOutcome, expected: String)] = [
            (LearnOutcome(), "Transcript updated."),
            (LearnOutcome(learned: [LearnedPair(heard: "Lightrim", intended: "Lightroom")],
                          skipped: []),
             "Learned “Lightrim” → “Lightroom”."),
            (LearnOutcome(learned: [],
                          skipped: [LearnedPair(heard: "have", intended: "work")]),
             "Skipped “have” — Mutter won’t rewrite that automatically."),
            (LearnOutcome(learned: [LearnedPair(heard: "JPIG", intended: "JPEG")],
                          skipped: [LearnedPair(heard: "my", intended: "a")]),
             "Learned “JPIG” → “JPEG”. Skipped “my” — Mutter won’t rewrite that automatically."),
            (LearnOutcome(learned: [],
                          skipped: [LearnedPair(heard: "have", intended: "work"),
                                    LearnedPair(heard: "my", intended: "a")]),
             "Skipped “have” and “my” — Mutter won’t rewrite those automatically."),
            // A heavily rewritten transcript must not produce an unbounded toast.
            (LearnOutcome(learned: [], skipped: [
                LearnedPair(heard: "my", intended: "a"),
                LearnedPair(heard: "have", intended: "work"),
                LearnedPair(heard: "God", intended: "guide"),
                LearnedPair(heard: "form", intended: "forum"),
             ]),
             "Skipped “my”, “have” and 2 more — Mutter won’t rewrite those automatically."),
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

        // MARK: removeTerm (AMUX-753 trained-words list)
        // The Training page's delete button drives removeTerm directly against
        // disk, so the round trip through load()/save() is the contract that
        // matters, not just an in-memory array shuffle.
        do {
            let termsTmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("mutter-selftest-terms", isDirectory: true)
            try? FileManager.default.removeItem(at: termsTmp)
            try? FileManager.default.createDirectory(at: termsTmp, withIntermediateDirectories: true)
            LearnedStore.directoryOverride = termsTmp
            defer {
                LearnedStore.directoryOverride = nil
                try? FileManager.default.removeItem(at: termsTmp)
            }

            LearnedStore.addTerm("Søren")
            LearnedStore.addTerm("Baseten")
            let removedMixedCase = LearnedStore.removeTerm("søren")
            let mixedCaseOK = removedMixedCase
                && !LearnedStore.load().terms.contains { $0.lowercased() == "søren" }
                && LearnedStore.load().terms.contains("Baseten")
            if !mixedCaseOK { passed = false }
            print("\(mixedCaseOK ? "PASS" : "FAIL"): removeTerm is case-insensitive and " +
                  "persists across load() = \(removedMixedCase), terms = " +
                  "\(LearnedStore.load().terms)")

            let beforeAbsent = LearnedStore.load().terms
            let removedAbsent = LearnedStore.removeTerm("nonexistent")
            let absentOK = !removedAbsent && LearnedStore.load().terms == beforeAbsent
            if !absentOK { passed = false }
            print("\(absentOK ? "PASS" : "FAIL"): removeTerm of an absent term returns " +
                  "false and leaves terms unchanged")
        }

        // The taught-word guard only fires when `taughtWords` is supplied -
        // exactly the automatic path's contract. A refused mapping still
        // biases recognition toward the intended wording, same as any other
        // reason a mapping is skipped.
        var taughtRecordLearned = LearnedData()
        let taughtRecordResult = LearnedStore.record(
            heard: "Konrad", intended: "laptop",
            in: &taughtRecordLearned, checker: recordChecker, taughtWords: ["Konrad"])
        let taughtRecordOK = !taughtRecordResult
            && !taughtRecordLearned.corrections.contains { $0.heard == "Konrad" }
            && taughtRecordLearned.terms.contains("laptop")
        if !taughtRecordOK { passed = false }
        print("\(taughtRecordOK ? "PASS" : "FAIL"): record(\"Konrad\" -> \"laptop\", " +
              "taught: [\"Konrad\"]) = \(taughtRecordResult), terms = " +
              "\(taughtRecordLearned.terms)")

        // The explicit path (add(), driven by Voice Training and Dictionary
        // corrections) never supplies taughtWords - mirrored here by omitting
        // it: the same mapping the automatic path just refused is stored
        // normally.
        var explicitRecordLearned = LearnedData()
        let explicitRecordResult = LearnedStore.record(
            heard: "Konrad", intended: "laptop",
            in: &explicitRecordLearned, checker: recordChecker)
        let explicitRecordOK = explicitRecordResult
            && explicitRecordLearned.corrections.contains {
                $0.heard == "Konrad" && $0.intended == "laptop"
            }
        if !explicitRecordOK { passed = false }
        print("\(explicitRecordOK ? "PASS" : "FAIL"): record(\"Konrad\" -> \"laptop\", " +
              "no taughtWords) = \(explicitRecordResult), corrections = " +
              "\(explicitRecordLearned.corrections.map { "\($0.heard)->\($0.intended)" })")

        // A word already learned as an intended term (`learned.terms`) counts
        // as taught too, not just words injected via `taughtWords` - a name
        // the user fixed once must guard itself on the very next diff, even
        // before it ever makes it into VocabularyStore.
        var termsGuardLearned = LearnedData(terms: ["Estefan"])
        let termsGuardResult = LearnedStore.record(
            heard: "Estefan", intended: "guessing",
            in: &termsGuardLearned, checker: recordChecker, taughtWords: [])
        let termsGuardOK = !termsGuardResult
            && !termsGuardLearned.corrections.contains { $0.heard == "Estefan" }
        if !termsGuardOK { passed = false }
        print("\(termsGuardOK ? "PASS" : "FAIL"): record(\"Estefan\" -> \"guessing\", " +
              "taught via learned.terms) = \(termsGuardResult)")

        // End to end through learn(): the diff-learning path AppDelegate
        // drives from a History correction. Isolated to a temp learned.json
        // so this never touches the user's real store.
        do {
            let learnedTempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("mutter-selftest-learned-taught", isDirectory: true)
            try? FileManager.default.removeItem(at: learnedTempDir)
            try? FileManager.default.createDirectory(
                at: learnedTempDir, withIntermediateDirectories: true)
            LearnedStore.directoryOverride = learnedTempDir
            defer {
                LearnedStore.directoryOverride = nil
                try? FileManager.default.removeItem(at: learnedTempDir)
            }

            // This is the exact shape of the bug: the user said "laptop", the
            // biased recognizer wrote "Konrad", the user fixed it in History,
            // and the diff must not learn that fix as a global rewrite of a
            // taught name.
            let diffOutcome = LearnedStore.learn(
                original: "Ask Konrad about the export.",
                corrected: "Ask laptop about the export.",
                checker: recordChecker, taughtWords: ["Konrad"])
            let stored = LearnedStore.load()
            let diffOK = diffOutcome.skipped == [LearnedPair(heard: "Konrad", intended: "laptop")]
                && diffOutcome.learned.isEmpty
                && !stored.corrections.contains { $0.heard == "Konrad" }
                && stored.terms.contains("laptop")
            if !diffOK { passed = false }
            print("\(diffOK ? "PASS" : "FAIL"): learn() refuses a taught heard word end to " +
                  "end, outcome = \(diffOutcome)")
        }

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

        // MARK: Input device preference
        // Round-trip the setting without disturbing whatever is really stored.
        let savedUID = Settings.inputDeviceUID
        Settings.inputDeviceUID = nil
        let defaultsToSystem = Settings.inputDeviceUID == nil
        Settings.inputDeviceUID = "test-uid-12345"
        let storesUID = Settings.inputDeviceUID == "test-uid-12345"
        Settings.inputDeviceUID = savedUID
        let restored = Settings.inputDeviceUID == savedUID
        let settingOK = defaultsToSystem && storesUID && restored
        if !settingOK { passed = false }
        print("\(settingOK ? "PASS" : "FAIL"): inputDeviceUID stores, clears and restores")

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

        // File round trip, isolated to a temp dir so the user's real store is untouched.
        do {
            let vocabTempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("mutter-selftest-vocab", isDirectory: true)
            try? FileManager.default.removeItem(at: vocabTempDir)
            try? FileManager.default.createDirectory(at: vocabTempDir, withIntermediateDirectories: true)
            VocabularyStore.directoryOverride = vocabTempDir
            defer {
                VocabularyStore.directoryOverride = nil
                try? FileManager.default.removeItem(at: vocabTempDir)
            }

            VocabularyStore.save(sampleEntries)
            let reloaded = VocabularyStore.load()
            let roundTripOK = reloaded.map(\.word) == ["Phocus", "Hasselblad"]
            if !roundTripOK { passed = false }
            print("\(roundTripOK ? "PASS" : "FAIL"): vocabulary.json round trips words")
        }

        // MARK: Vocabulary feeds bias and formatting
        // Isolated to a temp dir so the assertions are deterministic and the
        // real store is untouched.
        do {
            let vocabTempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("mutter-selftest-vocab", isDirectory: true)
            try? FileManager.default.removeItem(at: vocabTempDir)
            try? FileManager.default.createDirectory(at: vocabTempDir, withIntermediateDirectories: true)
            VocabularyStore.directoryOverride = vocabTempDir
            defer {
                VocabularyStore.directoryOverride = nil
                try? FileManager.default.removeItem(at: vocabTempDir)
            }

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
        }

        // MARK: Corrupt vocabulary.json is preserved, not re-migrated
        do {
            let vocabTempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("mutter-selftest-vocab-corrupt", isDirectory: true)
            try? FileManager.default.removeItem(at: vocabTempDir)
            try? FileManager.default.createDirectory(at: vocabTempDir, withIntermediateDirectories: true)
            VocabularyStore.directoryOverride = vocabTempDir
            defer {
                VocabularyStore.directoryOverride = nil
                try? FileManager.default.removeItem(at: vocabTempDir)
            }
            let corruptURL = vocabTempDir.appendingPathComponent("vocabulary.json")
            try? "{ this is not valid json ][".write(to: corruptURL, atomically: true, encoding: .utf8)
            let loaded = VocabularyStore.load()
            let backupExists = FileManager.default.fileExists(
                atPath: corruptURL.appendingPathExtension("corrupt").path)
            let corruptOK = loaded.isEmpty && backupExists
            if !corruptOK { passed = false }
            print("\(corruptOK ? "PASS" : "FAIL"): corrupt vocabulary.json is preserved, not re-migrated")
        }

        // Migration must keep two colliding-key entries whose replacements differ,
        // and still collapse a genuine duplicate pair.
        let collisionMigrated = VocabularyStore.migrate(from: [
            "base ten": "Baseten", "Base Ten": "Cornstarch", " base ten ": "Baseten",
        ])
        let collisionWords = Set(collisionMigrated.map(\.word))
        let collisionOK = collisionWords == ["Baseten", "Cornstarch"]
        if !collisionOK { passed = false }
        print("\(collisionOK ? "PASS" : "FAIL"): migrate() keeps distinct-value key collisions = \(collisionWords.sorted())")

        // MARK: Vocabulary disambiguation guard
        // The on-device model is not headless-testable, so the structural guard
        // that gates its output carries the weight. It must accept a 1:1
        // substitution toward a vocab term and the no-change case, and reject
        // anything else.
        let disambigGuardCases: [(name: String, vocab: [String],
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
            ("newline injection is rejected", ["Phocus"],
             "send it to focus", "send it to\nPhocus", false),
        ]
        for testCase in disambigGuardCases {
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

        // Disambiguation engine preference round-trips and defaults to off.
        let savedEngine = Settings.disambiguationEngine
        Settings.disambiguationEngine = .onDevice
        let storesEngine = Settings.disambiguationEngine == .onDevice
        Settings.disambiguationEngine = savedEngine
        let engineOK = storesEngine
        if !engineOK { passed = false }
        print("\(engineOK ? "PASS" : "FAIL"): disambiguationEngine stores and restores")

        // The trailing space is on unless deliberately turned off, so an unset
        // key must read as true. UserDefaults.bool(forKey:) returns false for a
        // key that was never written, which would ship the feature off for
        // everyone; this guards that specific trap.
        let savedSpace = UserDefaults.standard.object(forKey: "appendTrailingSpace")
        UserDefaults.standard.removeObject(forKey: "appendTrailingSpace")
        let defaultsOn = Settings.appendTrailingSpace
        Settings.appendTrailingSpace = false
        let storesOff = Settings.appendTrailingSpace == false
        if let savedSpace {
            UserDefaults.standard.set(savedSpace, forKey: "appendTrailingSpace")
        } else {
            UserDefaults.standard.removeObject(forKey: "appendTrailingSpace")
        }
        let spaceOK = defaultsOn && storesOff
        if !spaceOK { passed = false }
        print("\(spaceOK ? "PASS" : "FAIL"): appendTrailingSpace defaults on and " +
              "stores an explicit off")

        return passed
    }
}
