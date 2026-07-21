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
