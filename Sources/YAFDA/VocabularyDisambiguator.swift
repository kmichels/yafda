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
        clearly means the custom term. Never replace a word that already is \
        one of the custom terms. Change nothing else: do not rephrase, \
        add, remove, reorder, or repunctuate words. If nothing should change, \
        return the text exactly as given.
        Output ONLY the resulting text — no preamble, no quotes, no explanations.
        """

        let input = transcript
        let candidate = await Self.firstResult(within: Self.timeout) {
            let session = LanguageModelSession(instructions: instructions)
            guard let response = try? await session.respond(to: input) else { return nil }
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let candidate,
              let safe = Self.sanitized(
                  original: transcript, candidate: candidate, vocabulary: vocabulary)
        else { return transcript }
        return safe
    }

    /// Runs `operation`, returning its result, or nil if `timeout` elapses first.
    /// Unlike a TaskGroup, this does NOT wait for a still-running operation after
    /// the timeout: the operation task is cancelled and abandoned, so a
    /// non-cancellable hung model call cannot make this exceed `timeout`.
    private static func firstResult(
        within timeout: Duration,
        _ operation: @escaping @Sendable () async -> String?
    ) async -> String? {
        let gate = ResumeOnce()
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let work = Task {
                let result = await operation()
                gate.finish(result, continuation)
            }
            Task {
                try? await Task.sleep(for: timeout)
                gate.finish(nil, continuation)
                work.cancel()
            }
        }
    }

    /// Structural safety net, and the ONLY text that may reach the user. The
    /// model's candidate is used solely as a list of substitution decisions;
    /// the returned string is rebuilt from the ORIGINAL transcript's words, so
    /// nothing the model adds around a word — markdown emphasis, quotes,
    /// stray punctuation — can ever be inserted. (The 2026-07-25 "**repo**"
    /// bug: the old Bool gate compared punctuation-stripped cores but then
    /// shipped the model's raw text, so `**repo**` passed as "unchanged".)
    ///
    /// Returns nil when the candidate is not a pure 1:1 whole-word
    /// substitution toward vocabulary terms — rephrase, insertion, deletion,
    /// reorder, recasing of a non-vocab word, newline injection, or a
    /// substitution to a non-vocab word — and the caller keeps the raw
    /// transcript. Multi-word vocab terms fall back (v1 is 1:1 only).
    ///
    /// For an accepted substitution the output word is the vocabulary term in
    /// its canonical casing, wrapped in the ORIGINAL word's surrounding
    /// punctuation — so "focus." becomes "Phocus." even when the model
    /// answered "**Phocus**" or dropped the period.
    static func sanitized(
        original: String, candidate: String, vocabulary: [String]
    ) -> String? {
        // Split on any whitespace (spaces, tabs, newlines), not just U+0020,
        // so punctuation stripping and matching don't break on a stray newline.
        let originalWords = original.split(whereSeparator: \.isWhitespace).map(String.init)
        let candidateWords = candidate.split(whereSeparator: \.isWhitespace).map(String.init)
        guard originalWords.count == candidateWords.count else { return nil }
        // Reject whitespace injection the token split is blind to: the split
        // collapses whitespace runs, so a newline the model added (which could
        // submit a form or break insertion) would otherwise pass. The raw
        // transcript has no newlines at this pre-format stage.
        if candidate.contains(where: \.isNewline), !original.contains(where: \.isNewline) {
            return nil
        }
        // Word core: strip surrounding punctuation but KEEP case, so a
        // sentence-final "Phocus." matches the term while an unrequested
        // capitalization change ("macbook" -> "MacBook") still counts as a real
        // change that must justify itself against the vocabulary (closing the
        // "the model may recase anything" loophole).
        func core(_ word: String) -> String {
            String(word.trimmingCharacters(in: .punctuationCharacters))
        }
        // Canonical casing per term, keyed case-insensitively. First entry
        // wins if the user somehow has two casings of the same term.
        var canonical: [String: String] = [:]
        for term in vocabulary {
            let key = term.lowercased()
            if canonical[key] == nil { canonical[key] = term }
        }
        var rebuilt: [String] = []
        var substituted = false
        for (originalWord, candidateWord) in zip(originalWords, candidateWords) {
            if core(originalWord) == core(candidateWord) {
                // Unchanged core: the original word is authoritative. Any
                // decoration the model added dies here.
                rebuilt.append(originalWord)
                continue
            }
            // A word that already IS a vocabulary term is correct by
            // definition and is never substituted away (the Neil->amux bug:
            // with both in the vocabulary, the model "corrected" one taught
            // word into another). The prompt forbids this too, but prompt
            // compliance is probabilistic; this is the deterministic guard.
            // Per-word and case-insensitive: keep the original, keep going.
            if canonical[core(originalWord).lowercased()] != nil {
                rebuilt.append(originalWord)
                continue
            }
            // A changed word is allowed only if it IS a vocabulary term
            // (matched case-insensitively). A multi-word vocab term is one
            // dictionary entry and never equals a single token, so multi-word
            // substitutions fall back — v1 is 1:1 whole-word substitution only.
            guard let term = canonical[core(candidateWord).lowercased()] else {
                return nil
            }
            let prefix = originalWord.prefix { $0.isPunctuation }
            let suffix = String(
                originalWord.reversed().prefix { $0.isPunctuation }.reversed())
            rebuilt.append(String(prefix) + term + suffix)
            substituted = true
        }
        // No real substitution: return the original transcript itself, not a
        // re-join, so its exact whitespace survives.
        guard substituted else { return original }
        return rebuilt.joined(separator: " ")
    }
}

/// Ensures a checked continuation is resumed exactly once when two racing tasks
/// may both try to finish it.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    func finish(_ value: String?, _ continuation: CheckedContinuation<String?, Never>) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        continuation.resume(returning: value)
    }
}
