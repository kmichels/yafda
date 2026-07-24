import Accelerate
import AppKit
import AVFoundation
import Foundation
import os

/// Live input level for the microphone settings view.
///
/// A picker alone cannot answer "is this microphone actually hearing me",
/// which is the question that matters when several are connected. This taps
/// the selected device and publishes a level, writing nothing to disk.
///
/// A shared instance rather than one per view: only one meter can hold the
/// input device, and `AudioRecorder` has to be able to make it yield
/// **synchronously** before starting its own engine.
@MainActor
final class MicMonitor: ObservableObject {
    static let shared = MicMonitor()

    /// 0...1, suitable for a bar.
    @Published private(set) var level: Float = 0

    private let engine = AVAudioEngine()
    private var running = false
    private var suspended = false
    /// Set by the settings view. Without it, a dictation that ends after the
    /// view closed would restart the meter invisibly in the background.
    private var isVisible = false
    /// Set while the dashboard window is closed or minimised.
    ///
    /// Deliberately separate from `isVisible`. The window is created once and
    /// retained (`isReleasedWhenClosed = false`), so closing it does **not**
    /// tear down the SwiftUI view tree and `.onDisappear` never fires — the
    /// meter would otherwise keep the microphone open forever, with the system
    /// recording indicator lit and no window on screen to explain why.
    ///
    /// All three of `suspended`, `isVisible` and `windowHidden` can be set
    /// independently, and each must be able to hold the microphone off alone.
    private var windowHidden = false
    private var deviceUID: String?
    private var poll: Timer?
    private var configObserver: NSObjectProtocol?

    /// Written on the audio render thread, read on the main thread.
    ///
    /// A lock rather than hopping to the main actor per buffer: spawning a
    /// Task inside the tap allocates on a real-time thread and invites
    /// priority inversion and dropouts.
    private let latestRMS = OSAllocatedUnfairLock(initialState: Float(0))

    /// dBFS window the bar spans. Speech sits near -30 dBFS, so a linear RMS
    /// scale would look dead.
    private nonisolated static let floorDB: Float = -60

    nonisolated static func normalizedLevel(rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        guard db > floorDB else { return 0 }
        return min(1, db / -floorDB + 1)
    }

    private init() {
        // Unplugging the active microphone changes the engine's topology.
        // Without this the engine can fault while the settings view is open.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.running else { return }
                    let uid = self.deviceUID
                    self.stop()
                    self.start(deviceUID: uid)
                }
            }
    }

    // MARK: - View lifecycle

    func viewAppeared(deviceUID: String?) {
        isVisible = true
        start(deviceUID: deviceUID)
    }

    func viewDisappeared() {
        isVisible = false
        stop()
    }

    /// Window notifications that must close the microphone, and the one that
    /// may reopen it. Named constants so the self-test drives the same list the
    /// app registers, rather than a copy that can drift.
    static let hidingNotifications: [Notification.Name] = [
        NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification,
    ]
    static let showingNotification = NSWindow.didDeminiaturizeNotification

    private var windowObservers: [NSObjectProtocol] = []

    /// Registers the window notifications that gate the microphone.
    ///
    /// Owned here rather than in `AppDelegate` so the wiring itself is
    /// testable. The gate is only as good as its trigger: the shipped bug was
    /// correct logic that nothing ever called.
    ///
    /// `queue: nil` deliberately — the block then runs synchronously on the
    /// posting thread, so the microphone closes as part of the window closing
    /// rather than a runloop turn later. The same asynchronous-delivery hazard
    /// is already documented for the recording handover below.
    func observeVisibility(of object: AnyObject) {
        let center = NotificationCenter.default
        windowObservers.forEach(center.removeObserver)
        windowObservers = Self.hidingNotifications.map { name in
            center.addObserver(forName: name, object: object, queue: nil) { _ in
                MainActor.assumeIsolated {
                    MicMonitor.shared.windowVisibilityChanged(visible: false)
                }
            }
        }
        windowObservers.append(
            center.addObserver(forName: Self.showingNotification,
                               object: object, queue: nil) { _ in
                MainActor.assumeIsolated {
                    MicMonitor.shared.windowVisibilityChanged(visible: true)
                }
            })
    }

    /// Called from AppKit when the dashboard window opens, closes or is
    /// minimised. SwiftUI's own lifecycle cannot be trusted here — see
    /// `windowHidden`.
    func windowVisibilityChanged(visible: Bool) {
        windowHidden = !visible
        if visible {
            start(deviceUID: deviceUID)
        } else {
            stop()
        }
    }

    /// True when the microphone should be open right now. Exposed so the
    /// self-test can assert the guard conditions without touching hardware.
    var shouldBeRunning: Bool {
        isVisible && !suspended && !windowHidden
    }

    // MARK: - Self test

    /// Asserts the gating logic only. Never starts the engine, so it is safe to
    /// run headless and leaves the singleton as it found it.
    static func runSelfTest() -> Bool {
        var passed = true
        let mic = MicMonitor.shared
        let restore = mic.isVisible

        mic.viewDisappeared()
        mic.windowVisibilityChanged(visible: true)
        let cardHidden = !mic.shouldBeRunning

        mic.viewAppeared(deviceUID: nil)
        let cardShown = mic.shouldBeRunning

        // The case that shipped broken: the window is retained across closes,
        // so the card never "disappears" and only this can shut the mic off.
        mic.windowVisibilityChanged(visible: false)
        let windowClosed = !mic.shouldBeRunning

        mic.windowVisibilityChanged(visible: true)
        mic.suspendForRecording()
        let recording = !mic.shouldBeRunning
        mic.resumeAfterRecording()
        let resumed = mic.shouldBeRunning

        // A close during recording must still leave it off once recording ends.
        mic.windowVisibilityChanged(visible: false)
        mic.suspendForRecording()
        mic.resumeAfterRecording()
        let closedDuringRecording = !mic.shouldBeRunning

        // The notifications must actually be wired. Without this, deleting the
        // registration leaves every test above passing and reintroduces the
        // exact bug: correct gating logic that nothing ever calls.
        let probe = NSObject()
        mic.observeVisibility(of: probe)
        mic.windowVisibilityChanged(visible: true)
        mic.viewAppeared(deviceUID: nil)
        var wiredClose = true
        for name in MicMonitor.hidingNotifications {
            mic.windowVisibilityChanged(visible: true)
            NotificationCenter.default.post(name: name, object: probe)
            wiredClose = wiredClose && !mic.shouldBeRunning
        }
        NotificationCenter.default.post(
            name: MicMonitor.showingNotification, object: probe)
        let wiredOpen = mic.shouldBeRunning

        mic.windowVisibilityChanged(visible: true)
        mic.viewDisappeared()
        if restore { mic.viewAppeared(deviceUID: nil) }

        for (label, ok) in [
            ("every hiding notification closes the mic", wiredClose),
            ("deminiaturising reopens it", wiredOpen),
            ("card hidden keeps it off", cardHidden),
            ("card shown with window open turns it on", cardShown),
            ("closing the window turns it off even with the card shown",
             windowClosed),
            ("recording handover turns it off", recording),
            ("resuming after recording turns it back on", resumed),
            ("a window closed mid-recording stays off afterwards",
             closedDuringRecording),
        ] {
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): mic/\(label)")
        }
        return passed
    }

    // MARK: - Recording handover
    //
    // Called DIRECTLY by AudioRecorder, not through NotificationCenter: an
    // observer registered with `queue: .main` runs asynchronously, so the
    // recorder could start its engine before this one had released the
    // device, and both would contend for the hardware.

    func suspendForRecording() {
        suspended = true
        stop()
    }

    func resumeAfterRecording() {
        suspended = false
        guard isVisible else { return }
        start(deviceUID: deviceUID)
    }

    // MARK: - Engine

    func start(deviceUID: String?) {
        self.deviceUID = deviceUID
        guard !running, shouldBeRunning else { return }
        let input = engine.inputNode
        if let deviceUID, let device = AudioDevices.device(uid: deviceUID) {
            try? input.auAudioUnit.setDeviceID(device.id)
        } else if let defaultDevice = AudioDevices.systemDefaultInput() {
            try? input.auAudioUnit.setDeviceID(defaultDevice.id)
        }
        // Microphone access may not be granted yet; starting the engine
        // without it fails and would leave the meter dead with no explanation.
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        else { return }

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return }
        // Interleaved buffers pack channels together, so read every Nth sample
        // rather than refusing - some USB interfaces only offer interleaved,
        // and bailing would show a dead meter on a working microphone.
        let stride = vDSP_Stride(format.isInterleaved ? Int(format.channelCount) : 1)

        let store = latestRMS
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            // Render thread: no allocation, no actor hops, no logging.
            guard let channel = buffer.floatChannelData?[0] else { return }
            let frames = vDSP_Length(buffer.frameLength)
            guard frames > 0 else { return }
            var rms: Float = 0
            vDSP_rmsqv(channel, stride, &rms, frames)
            store.withLock { $0 = rms }
        }
        do {
            try engine.start()
            running = true
            startPolling()
        } catch {
            input.removeTap(onBus: 0)
        }
    }

    func stop() {
        poll?.invalidate()
        poll = nil
        level = 0
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        running = false
    }

    /// Reads the shared value on a timer instead of pushing from the tap, so
    /// UI updates happen at a display-friendly rate rather than per buffer.
    private func startPolling() {
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let rms = self.latestRMS.withLock { $0 }
                let target = MicMonitor.normalizedLevel(rms: rms)
                // Fast attack, slow decay: track speech, do not flicker.
                self.level = target > self.level
                    ? target
                    : self.level * 0.85 + target * 0.15
            }
        }
    }
}
