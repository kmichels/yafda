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

        let input = transcript
        let candidate = await Self.firstResult(within: Self.timeout) {
            let session = LanguageModelSession(instructions: instructions)
            guard let response = try? await session.respond(to: input) else { return nil }
            return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let candidate,
              Self.accept(original: transcript, candidate: candidate, vocabulary: vocabulary)
        else { return transcript }
        return candidate
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
        // Reject whitespace injection the token split is blind to: the split
        // collapses whitespace runs, so a newline the model added (which could
        // submit a form or break insertion) would otherwise pass. The raw
        // transcript has no newlines at this pre-format stage.
        if candidate.contains(where: \.isNewline), !original.contains(where: \.isNewline) {
            return false
        }
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
