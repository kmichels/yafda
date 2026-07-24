import AVFAudio
import Foundation
import Speech

/// Wraps Apple's on-device SpeechAnalyzer/SpeechTranscriber (macOS 26+).
/// Fully local — the language model asset is downloaded once by macOS itself.
final class Transcriber {
    let locale: Locale

    init(locale: Locale = Locale(identifier: "en-US")) {
        self.locale = locale
    }

    /// Downloads the on-device speech model for the locale if missing.
    func ensureModelInstalled() async throws {
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        if await SpeechTranscriber.installedLocales.contains(where: {
            $0.identifier(.bcp47) == locale.identifier(.bcp47)
        }) {
            return
        }
        FileHandle.standardError.write(
            Data("Downloading on-device speech model for \(locale.identifier)…\n".utf8))
        if let request = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }

    /// Transcribes an audio file and returns the raw text.
    /// `biasTerms` predisposes the on-device model toward the user's own
    /// vocabulary (names, jargon) via contextual strings.
    func transcribe(fileAt url: URL, biasTerms: [String] = []) async throws -> String {
        try await ensureModelInstalled()

        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !biasTerms.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings = [.general: biasTerms]
            try await analyzer.setContext(context)
        }
        let audioFile = try AVAudioFile(forReading: url)

        async let transcript: AttributedString = transcriber.results
            .reduce(into: AttributedString("")) { partial, result in
                partial.append(result.text)
                partial.append(AttributedString(" "))
            }

        if let last = try await analyzer.analyzeSequence(from: audioFile) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }

        return String((try await transcript).characters)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
