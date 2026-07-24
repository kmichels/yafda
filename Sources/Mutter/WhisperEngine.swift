import AVFAudio
import Foundation
import WhisperKit

/// Mutter's optional "Precise" recognition engine: OpenAI's Whisper model
/// running locally via WhisperKit (CoreML on the Neural Engine). Slower to
/// warm up than Apple's engine but stronger on accents and jargon, and it
/// supports vocabulary biasing through the decoder prompt — the user's
/// dictionary, snippets and learned terms are fed in before recognition.
/// The model downloads once into Application Support; recognition is offline.
@MainActor
final class WhisperEngine {

    static let availableModels: [(id: String, label: String)] = [
        ("base", "Base — fastest, ~150 MB"),
        ("small", "Small — balanced, recommended, ~500 MB"),
        ("distil-whisper_distil-large-v3_turbo",
         "Distil Large v3 — fast + precise, English only, ~600 MB"),
        ("large-v3-v20240930_turbo", "Large v3 Turbo — most precise, slow, ~1.6 GB"),
    ]

    /// Status line for the UI (loading/downloading/transcribing); nil clears.
    var onStatus: ((String?) -> Void)?

    private var loadTask: Task<WhisperKit, Error>?
    private var loadedModel: String?
    /// Set only after the pipeline has fully loaded and prewarmed.
    private var readyModel: String?

    private var modelsDirectory: URL {
        AppPaths.supportDirectory.appendingPathComponent(
            "whisper-models", isDirectory: true)
    }

    /// True once the pipeline is loaded in memory and can transcribe now.
    func isReady(model: String) -> Bool {
        readyModel == model
    }

    /// True once all model files exist locally (no download needed).
    func isModelDownloaded(_ model: String) -> Bool {
        guard let contents = try? FileManager.default.subpathsOfDirectory(
            atPath: modelsDirectory.path) else { return false }
        let required = ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc",
                        "MelSpectrogram.mlmodelc"]
        return required.allSatisfy { component in
            contents.contains {
                $0.contains(model) && $0.contains(component)
                    && $0.hasSuffix("coremldata.bin")
            }
        }
    }

    /// Kicks off model load/download in the background.
    func preload(model: String) {
        Task { _ = try? await self.pipeline(model: model) }
    }

    private func pipeline(model: String) async throws -> WhisperKit {
        if loadedModel == model, let loadTask {
            return try await loadTask.value
        }
        loadTask?.cancel()
        loadedModel = model
        readyModel = nil

        let needsDownload = !isModelDownloaded(model)
        onStatus?(needsDownload
            ? "Downloading Whisper model (one-time)…"
            : "Loading Whisper model…")
        let directory = modelsDirectory
        let task = Task { () -> WhisperKit in
            let config = WhisperKitConfig(
                model: model,
                downloadBase: directory,
                verbose: false,
                logLevel: .error,
                prewarm: true,
                load: true,
                download: true)
            return try await WhisperKit(config)
        }
        loadTask = task
        defer { onStatus?(nil) }
        let pipe = try await task.value
        if loadedModel == model {
            readyModel = model
        }
        return pipe
    }

    func transcribe(
        fileAt url: URL, model: String, localeID: String,
        biasTerms: [String]) async throws -> String {
        let pipe = try await pipeline(model: model)

        var options = DecodingOptions()
        options.language = String(localeID.prefix(while: { $0 != "-" })).lowercased()
        // Timestamps aren't needed for dictation — skipping them trims
        // decoding work. VAD chunking only pays off on long recordings.
        options.withoutTimestamps = true
        if let audioFile = try? AVAudioFile(forReading: url),
           audioFile.fileFormat.sampleRate > 0 {
            let seconds = Double(audioFile.length) / audioFile.fileFormat.sampleRate
            options.chunkingStrategy = seconds > 25 ? .vad : nil
        } else {
            options.chunkingStrategy = .vad
        }

        // Vocabulary biasing: Whisper conditions on a decoder prompt, so
        // listing the user's terms makes it far likelier to spell them right.
        if !biasTerms.isEmpty, let tokenizer = pipe.tokenizer {
            let prompt = "Vocabulary: "
                + biasTerms.prefix(60).joined(separator: ", ") + "."
            let tokens = tokenizer.encode(text: " " + prompt)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            options.promptTokens = Array(tokens.prefix(200))
            options.usePrefillPrompt = true
        }

        onStatus?("Transcribing (Whisper)…")
        defer { onStatus?(nil) }
        let results = try await pipe.transcribe(
            audioPath: url.path, decodeOptions: options)
        return results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
