import AVFoundation
import Foundation

/// Captures microphone audio into a temporary file while the hotkey is held.
///
/// Deliberately simple: the engine starts on key-down and stops on release.
/// Two "improvements" were tried and reverted after breaking things:
/// - setVoiceProcessingEnabled: its echo canceller ducks/mutes other apps'
///   audio system-wide and can feed the recognizer silence.
/// - A warm always-on engine with a pre-roll ring buffer: wedged the engine
///   so recording never started.
final class AudioRecorder {
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private(set) var currentFileURL: URL?
    private(set) var isRecording = false

    /// Human-readable name of the device the last recording used, for the UI.
    private(set) var activeDeviceDescription = "System default"

    static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    func start() throws {
        guard !isRecording else { return }

        // The meter in the settings view may be holding the device. Make it
        // yield synchronously - a notification would let us start first.
        MainActor.assumeIsolated { MicMonitor.shared.suspendForRecording() }
        // The engine is reused across recordings, and changing an
        // already-configured audio unit's device can fail silently.
        engine.reset()
        let input = engine.inputNode
        // Select the device BEFORE reading the format: the format belongs to
        // the selected device, so choosing afterwards would record at the
        // previous device's sample rate.
        activeDeviceDescription = Self.selectInputDevice(on: input)
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(
                domain: "Murmur", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No microphone input available"])
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-\(UUID().uuidString).caf")
        let audioFile = try AVAudioFile(forWriting: url, settings: format.settings)

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            try? self?.file?.write(from: buffer)
        }

        file = audioFile
        currentFileURL = url
        engine.prepare()
        try engine.start()
        isRecording = true
    }

    /// Stops recording and returns the captured audio file URL,
    /// or nil if nothing was recorded.
    @discardableResult
    func stop() -> URL? {
        guard isRecording else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        MainActor.assumeIsolated { MicMonitor.shared.resumeAfterRecording() }
        isRecording = false
        file = nil
        let url = currentFileURL
        currentFileURL = nil
        return url
    }

    /// Stops and deletes the in-progress recording.
    func cancel() {
        if let url = stop() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Points `input` at the user's chosen microphone when one is set and
    /// present. Falls back to the system default in every failure case -
    /// device selection must never stop a recording from happening.
    /// - Returns: a description of what was actually selected.
    private static func selectInputDevice(on input: AVAudioInputNode) -> String {
        guard let uid = Settings.inputDeviceUID else {
            return AudioDevices.systemDefaultInput().map { "\($0.name) (system default)" }
                ?? "System default"
        }
        guard let device = AudioDevices.device(uid: uid) else {
            return "Chosen microphone unavailable — using system default"
        }
        do {
            try input.auAudioUnit.setDeviceID(device.id)
            return device.name
        } catch {
            // Leaving the unit on a device that failed to select would record
            // from nothing. Put it back on the system default explicitly.
            if let fallback = AudioDevices.systemDefaultInput() {
                try? input.auAudioUnit.setDeviceID(fallback.id)
            }
            return "\(device.name) unavailable — using system default"
        }
    }
}
