import Foundation

/// Rule-based cleanup of raw transcripts: filler removal, spoken layout
/// commands, spacing/capitalization fixes, and personal-dictionary
/// substitutions. Mirrors Wispr Flow's "AI edits" with local rules.
struct TextFormatter {

    /// Filler words removed when they appear as standalone tokens.
    static let fillers: Set<String> = [
        "um", "umm", "uh", "uhh", "uhm", "er", "erm", "ehm", "mhm", "hmm",
    ]

    var dictionary: [String: String]

    init(dictionary: [String: String] = TextFormatter.loadDictionary()) {
        self.dictionary = dictionary
    }

    static var dictionaryURL: URL {
        AppPaths.supportDirectory.appendingPathComponent("dictionary.json")
    }

    static func loadDictionary() -> [String: String] {
        guard let data = try? Data(contentsOf: dictionaryURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return dict
    }

    func format(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "" }

        text = removeFillers(from: text)
        text = applySpokenCommands(to: text)
        text = applyDictionary(to: text)
        text = tidyWhitespaceAndPunctuation(in: text)
        text = capitalizeSentences(in: text)
        text = ensureTerminalPunctuation(in: text)
        return text
    }

    // MARK: - Passes

    private func removeFillers(from text: String) -> String {
        var result = text
        for filler in Self.fillers {
            // Filler optionally followed by a comma, as its own word.
            let pattern = "(?i)(^|\\s)\(filler)[,.]?(?=\\s|$)"
            result = result.replacingOccurrences(
                of: pattern, with: "$1", options: .regularExpression)
        }
        return result
    }

    private func applySpokenCommands(to text: String) -> String {
        var result = text
        let commands: [(pattern: String, replacement: String)] = [
            ("(?i)[,.]?\\s*\\bnew paragraph[,.]?\\s*", "\n\n"),
            ("(?i)[,.]?\\s*\\bnew ?line[,.]?\\s*", "\n"),
        ]
        for command in commands {
            result = result.replacingOccurrences(
                of: command.pattern, with: command.replacement,
                options: .regularExpression)
        }
        return result
    }

    private func applyDictionary(to text: String) -> String {
        var result = text
        for (spoken, replacement) in dictionary {
            let escaped = NSRegularExpression.escapedPattern(for: spoken)
            result = result.replacingOccurrences(
                of: "(?i)\\b\(escaped)\\b", with: replacement,
                options: .regularExpression)
        }
        return result
    }

    private func tidyWhitespaceAndPunctuation(in text: String) -> String {
        var result = text
        // Collapse runs of spaces/tabs (not newlines).
        result = result.replacingOccurrences(
            of: "[ \\t]+", with: " ", options: .regularExpression)
        // No space before closing punctuation.
        result = result.replacingOccurrences(
            of: " +([,.;:!?])", with: "$1", options: .regularExpression)
        // Collapse duplicate punctuation like ",." or ".." left by edits.
        result = result.replacingOccurrences(
            of: "([,.;:!?])[,.]", with: "$1", options: .regularExpression)
        // Trim each line.
        result = result
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
        // At most one blank line in a row.
        result = result.replacingOccurrences(
            of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func capitalizeSentences(in text: String) -> String {
        guard !text.isEmpty else { return text }
        var characters = Array(text)
        var capitalizeNext = true
        for index in characters.indices {
            let character = characters[index]
            if capitalizeNext, character.isLetter {
                characters[index] = Character(character.uppercased())
                capitalizeNext = false
            } else if ".!?\n".contains(character) {
                capitalizeNext = true
            } else if !character.isWhitespace, !"\"'([{".contains(character) {
                capitalizeNext = false
            }
        }
        return String(characters)
    }

    private func ensureTerminalPunctuation(in text: String) -> String {
        guard let last = text.last else { return text }
        if last.isLetter || last.isNumber {
            return text + "."
        }
        return text
    }

    // MARK: - Insertion

    /// The text as it should land at the cursor.
    ///
    /// `format()` trims trailing whitespace, which is right for everything that
    /// gets *stored* — history, correction diffing, Voice Profile word counts —
    /// but wrong for what gets *pasted*: the cursor ends flush against the full
    /// stop, so dictating twice in a row produces "…done.Next sentence…".
    ///
    /// Kept separate from `format()` precisely so the space never reaches the
    /// stored copy. Trailing whitespace in the learning corpus is how junk
    /// correction rules get taught.
    ///
    /// Appends nothing when the text is empty (never paste a lone space) or
    /// already ends in whitespace — including the newline left by "new
    /// paragraph", where the cursor is already at the start of a fresh line.
    static func forInsertion(_ text: String, appendTrailingSpace: Bool) -> String {
        guard appendTrailingSpace, !text.isEmpty else { return text }
        guard let last = text.last, !last.isWhitespace else { return text }
        return text + " "
    }

    // MARK: - Self test

    static func runSelfTest() -> Bool {
        let formatter = TextFormatter(dictionary: ["jira": "Jira", "claude code": "Claude Code"])
        let cases: [(input: String, expected: String)] = [
            ("um hello world", "Hello world."),
            ("this is, uh, a test", "This is, a test."),
            ("first line new line second line", "First line\nSecond line."),
            ("intro new paragraph details here", "Intro\n\nDetails here."),
            ("file a ticket in jira today", "File a ticket in Jira today."),
            ("i use claude code daily", "I use Claude Code daily."),
            ("hello world. this is fine", "Hello world. This is fine."),
            ("  spaced   out   words ", "Spaced out words."),
            ("already punctuated!", "Already punctuated!"),
            ("", ""),
        ]
        var passed = true
        for testCase in cases {
            let got = formatter.format(testCase.input)
            let ok = got == testCase.expected
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): \"\(testCase.input)\" -> \"\(got)\"" +
                  (ok ? "" : " (expected \"\(testCase.expected)\")"))
        }

        // MARK: Trailing space for insertion
        // format() trims trailing whitespace, so without this the cursor lands
        // hard against the full stop and consecutive dictations run together.
        let insertionCases: [(text: String, append: Bool, expected: String)] = [
            ("Hello world.", true, "Hello world. "),
            ("no punctuation", true, "no punctuation "),
            // Never double up - the style rewrite and snippet expansion can
            // both hand back trailing whitespace.
            ("already spaced ", true, "already spaced "),
            // "new paragraph" leaves the cursor at the start of a fresh line,
            // where a leading space would be wrong.
            ("Intro\n\nDetails\n", true, "Intro\n\nDetails\n"),
            // Empty in, empty out - never paste a lone space.
            ("", true, ""),
            ("Hello world.", false, "Hello world."),
            ("", false, ""),
            // Interior whitespace is not this function's business.
            ("First\nSecond.", true, "First\nSecond. "),
        ]
        for testCase in insertionCases {
            let got = forInsertion(testCase.text, appendTrailingSpace: testCase.append)
            let ok = got == testCase.expected
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): forInsertion(\"\(testCase.text)\", " +
                  "append: \(testCase.append)) -> \"\(got)\"" +
                  (ok ? "" : " (expected \"\(testCase.expected)\")"))
        }

        return passed
    }
}
