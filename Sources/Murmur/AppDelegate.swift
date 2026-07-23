import AppKit
import AVFoundation
import Foundation
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {

    enum UIState {
        case idle, recording, processing
    }

    // Observable state for the dashboard window.
    @Published var uiState: UIState = .idle { didSet { updateIcon() } }
    @Published var isHandsFree = false
    @Published var entries: [HistoryEntry] = []
    @Published var micAuthorized = false
    @Published var axTrusted = false
    @Published var hotkey: HotkeyMonitor.Hotkey = Settings.hotkey
    @Published var localeID: String = Settings.locale.identifier
    @Published var lastError: String?

    private var statusItem: NSStatusItem!
    private var window: NSWindow?
    private let recorder = AudioRecorder()
    private let history = HistoryStore()
    private var transcriber = Transcriber(locale: Settings.locale)
    private lazy var hotkeyMonitor = HotkeyMonitor(hotkey: Settings.hotkey)
    let rewriteEngine = RewriteEngine()
    private let vocabularyDisambiguator = VocabularyDisambiguator()
    let whisperEngine = WhisperEngine()
    @Published var engine: String = Settings.engine
    @Published var whisperModel: String = Settings.whisperModel
    @Published var whisperReady = false
    @Published var voiceProfile: VoiceProfile? = VoiceProfileStore.load()
    private(set) lazy var transformManager = TransformManager(engine: rewriteEngine)

    /// Extra status line shown in the top bar while a transform runs.
    @Published var transformStatus: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        entries = history.entries
        setUpStatusItem()
        refreshPermissions(promptAccessibility: true)
        wireHotkey()
        hotkeyMonitor.startMonitoring()
        transformManager.onStatus = { [weak self] status in
            self?.transformStatus = status
        }
        transformManager.onError = { [weak self] message in
            self?.lastError = message
        }
        transformManager.startMonitoring()
        whisperEngine.onStatus = { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                self.transformStatus = status
                self.whisperReady = self.whisperEngine.isReady(
                    model: Settings.whisperModel)
            }
        }
        if Settings.engine == "whisper" {
            whisperEngine.preload(model: Settings.whisperModel)
        }
        showMainWindow()

        Task {
            micAuthorized = await AudioRecorder.requestMicrophoneAccess()
        }
        // Warm up the on-device speech model in the background.
        Task.detached { [transcriber] in
            try? await transcriber.ensureModelInstalled()
        }
        refreshVoiceProfileIfDue()
    }

    /// Regenerates the Voice Profile persona once enough new dictation has
    /// accumulated. Runs quietly in the background; failures keep the old one.
    func refreshVoiceProfileIfDue(force: Bool = false) {
        let totalWords = entries.reduce(0) { $0 + $1.wordCount }
        guard force || VoiceProfileStore.shouldRefresh(totalWords: totalWords)
        else { return }
        guard totalWords >= VoiceProfileStore.minimumWords else { return }
        let snapshot = entries
        Task { [rewriteEngine] in
            if let profile = await VoiceProfileStore.generate(
                from: snapshot, totalWords: totalWords, engine: rewriteEngine) {
                voiceProfile = profile
            }
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    // MARK: - Main window

    func showMainWindow() {
        if window == nil {
            let hosting = NSHostingController(rootView: MainView(app: self))
            let newWindow = NSWindow(contentViewController: hosting)
            newWindow.title = "Murmur"
            newWindow.styleMask = [
                .titled, .closable, .miniaturizable, .resizable, .fullSizeContentView,
            ]
            newWindow.titleVisibility = .hidden
            newWindow.titlebarAppearsTransparent = true
            newWindow.setContentSize(NSSize(width: 1180, height: 840))
            newWindow.minSize = NSSize(width: 900, height: 600)
            newWindow.isReleasedWhenClosed = false
            newWindow.center()
            window = newWindow
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        refreshPermissions()
    }

    // MARK: - Permissions

    func refreshPermissions(promptAccessibility: Bool = false) {
        if promptAccessibility {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            axTrusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
        } else {
            axTrusted = AXIsProcessTrusted()
        }
        micAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        whisperReady = whisperEngine.isReady(model: Settings.whisperModel)
    }

    // MARK: - Settings changes (from window or menu)

    func setHotkey(_ key: HotkeyMonitor.Hotkey) {
        Settings.hotkey = key
        hotkey = key
        hotkeyMonitor.hotkey = key
        rebuildMenu()
    }

    func setEngine(_ newEngine: String) {
        Settings.engine = newEngine
        engine = newEngine
        if newEngine == "whisper" {
            whisperEngine.preload(model: Settings.whisperModel)
        }
    }

    func setWhisperModel(_ model: String) {
        Settings.whisperModel = model
        whisperModel = model
        if Settings.engine == "whisper" {
            whisperEngine.preload(model: model)
        }
    }

    func setLocale(_ identifier: String) {
        Settings.localeIdentifier = identifier
        localeID = identifier
        transcriber = Transcriber(locale: Locale(identifier: identifier))
        Task.detached { [transcriber] in
            try? await transcriber.ensureModelInstalled()
        }
    }

    func clearHistoryEntries() {
        history.clear()
        entries = []
        rebuildMenu()
    }

    /// Deletes any stale Accessibility grant (recorded against an older
    /// build's signature) and relaunches so macOS asks again — the new grant
    /// is recorded against the stable certificate and survives updates.
    func resetAccessibilityGrant() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = [
            "reset", "Accessibility",
            Bundle.main.bundleIdentifier ?? "local.murmur",
        ]
        try? process.run()
        process.waitUntilExit()
        relaunch()
    }

    /// Starts a fresh instance of the app and quits this one. Needed after
    /// granting Accessibility, which macOS only applies to new processes.
    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    func deleteHistoryEntry(id: String) {
        history.delete(id: id)
        entries = history.entries
        rebuildMenu()
    }

    /// Applies a user correction to a transcript and learns the
    /// misheard -> intended mappings from it.
    /// - Returns: what was learned and what was skipped.
    @discardableResult
    func correctHistoryEntry(id: String, newText: String) -> LearnOutcome {
        guard let entry = history.entries.first(where: { $0.id == id }),
              entry.text != newText else { return LearnOutcome() }
        let outcome = LearnedStore.learn(original: entry.text, corrected: newText)
        history.update(id: id, text: newText)
        entries = history.entries
        rebuildMenu()
        return outcome
    }

    /// Raw transcription without biasing or cleanup — used by Voice Training
    /// to see what the model naturally hears.
    func transcribeRaw(fileAt url: URL) async throws -> String {
        try await transcriber.transcribe(fileAt: url)
    }

    /// Runs the user's chosen recognition engine. Dictation never waits on
    /// Whisper: while its model is still downloading or loading, Apple's
    /// engine handles the dictation, and Whisper takes over once ready.
    /// Whisper failures also fall back to Apple so a keypress always
    /// produces text.
    private func recognize(fileAt url: URL) async throws -> String {
        let biasTerms = LearnedStore.biasTerms()
        if Settings.engine == "whisper" {
            if whisperEngine.isReady(model: Settings.whisperModel) {
                do {
                    return try await whisperEngine.transcribe(
                        fileAt: url, model: Settings.whisperModel,
                        localeID: Settings.localeIdentifier, biasTerms: biasTerms)
                } catch {
                    lastError = "Whisper engine failed " +
                        "(\(error.localizedDescription)) — used Apple engine instead."
                }
            } else {
                whisperEngine.preload(model: Settings.whisperModel)
                lastError = "Whisper model is still preparing — used Apple " +
                    "engine for this dictation. Whisper takes over when ready."
            }
        }
        return try await transcriber.transcribe(fileAt: url, biasTerms: biasTerms)
    }

    // MARK: - Hotkey wiring

    private func wireHotkey() {
        hotkeyMonitor.onStart = { [weak self] in
            DispatchQueue.main.async { self?.startRecording() }
        }
        hotkeyMonitor.onStop = { [weak self] in
            DispatchQueue.main.async { self?.stopAndTranscribe() }
        }
        hotkeyMonitor.onCancel = { [weak self] in
            DispatchQueue.main.async {
                self?.recorder.cancel()
                self?.uiState = .idle
            }
        }
        hotkeyMonitor.onHandsFreeChange = { [weak self] active in
            DispatchQueue.main.async {
                self?.isHandsFree = active
                self?.updateIcon()
                if active { NSSound(named: "Pop")?.play() }
            }
        }
    }

    private var recordingStartedAt: Date?
    private var recordingTargetBundleID: String?

    private func startRecording() {
        guard uiState != .recording else { return }
        do {
            try recorder.start()
            recordingStartedAt = Date()
            recordingTargetBundleID =
                NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            uiState = .recording
            lastError = nil
            NSSound(named: "Pop")?.play()
        } catch {
            lastError = "Could not start recording: \(error.localizedDescription)"
            NSSound(named: "Basso")?.play()
        }
    }

    private func stopAndTranscribe() {
        isHandsFree = false
        guard let url = recorder.stop() else {
            uiState = .idle
            return
        }
        NSSound(named: "Tink")?.play()
        uiState = .processing
        let duration = recordingStartedAt.map { Date().timeIntervalSince($0) }
        recordingStartedAt = nil
        let targetBundleID = recordingTargetBundleID
        recordingTargetBundleID = nil

        Task { [history, rewriteEngine, vocabularyDisambiguator] in
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                let raw = try await recognize(fileAt: url)
                let vocabEntries = VocabularyStore.load()
                // Context disambiguation pass is DISABLED: empirical testing
                // showed Apple's on-device model does not do reliable
                // context-aware homophone substitution — free-text output
                // conversationalises (guard rejects it) and structured output
                // hallucinates wrong 1:1 swaps ("send"->"Phocus") that pass the
                // structural guard. It could turn "I need to focus" into "I need
                // to Phocus". Vocabulary still drives recognition bias
                // (LearnedStore.biasTerms) and hard corrections (below). See
                // vocabularyDisambiguator / .planning for the redesign path.
                _ = vocabularyDisambiguator
                let disambiguated = raw
                var formatted = TextFormatter(
                    dictionary: VocabularyStore.correctionMap(from: vocabEntries)
                ).format(disambiguated)
                formatted = LearnedStore.apply(in: formatted)
                formatted = SnippetStore.expand(in: formatted)

                // Per-app style: rewrite tone on-device (Apple Intelligence).
                let style = StyleSettings.style(forBundleID: targetBundleID)
                if let instructions = style.instructions,
                   !formatted.isEmpty,
                   rewriteEngine.isAvailable {
                    transformStatus = "Applying \(style.displayName) style…"
                    if let rewritten = try? await rewriteEngine.rewrite(
                        formatted, instructions: instructions),
                       !rewritten.isEmpty {
                        formatted = rewritten
                    }
                    transformStatus = nil
                }
                if !formatted.isEmpty {
                    history.add(formatted, duration: duration)
                    entries = history.entries
                    refreshVoiceProfileIfDue()
                    if AXIsProcessTrusted() {
                        TextInserter.insert(formatted)
                    } else {
                        // Can't synthesize ⌘V without Accessibility — never
                        // fail silently: leave the transcript on the clipboard.
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(formatted, forType: .string)
                        lastError = "Accessibility isn't active for this build, " +
                            "so the text was copied to your clipboard instead — " +
                            "press ⌘V to paste it. Fix this in Settings."
                        NSSound(named: "Basso")?.play()
                    }
                    rebuildMenu()
                }
            } catch {
                lastError = "Transcription failed: \(error.localizedDescription)"
                NSSound(named: "Basso")?.play()
            }
            uiState = .idle
        }
    }

    // MARK: - Status item / menu

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateIcon()
        rebuildMenu()
    }

    private func updateIcon() {
        let symbol: String
        switch uiState {
        case .idle: symbol = "mic"
        case .recording: symbol = isHandsFree ? "mic.badge.plus" : "mic.fill"
        case .processing: symbol = "hourglass"
        }
        statusItem.button?.image = NSImage(
            systemSymbolName: symbol, accessibilityDescription: "Murmur")
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let openItem = NSMenuItem(
            title: "Open Murmur…", action: #selector(openMainWindow),
            keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(.separator())

        let hint = NSMenuItem(
            title: "Hold \(hotkeyMonitor.hotkey.displayName) to dictate",
            action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        if history.entries.isEmpty {
            let empty = NSMenuItem(title: "No transcripts yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            let header = NSMenuItem(title: "Recent (click to copy)", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for (index, entry) in history.entries.prefix(8).enumerated() {
                let preview = entry.text.count > 60
                    ? String(entry.text.prefix(57)) + "…" : entry.text
                let item = NSMenuItem(
                    title: preview.replacingOccurrences(of: "\n", with: " "),
                    action: #selector(copyHistoryItem(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: "Quit Murmur", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    // MARK: - Menu actions

    @objc private func openMainWindow() {
        showMainWindow()
    }

    @objc private func copyHistoryItem(_ sender: NSMenuItem) {
        guard sender.tag < history.entries.count else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(history.entries[sender.tag].text, forType: .string)
    }
}

enum Settings {
    private static let defaults = UserDefaults.standard

    /// One-time import of preferences saved under the app's pre-rename
    /// bundle id (local.whisperflow). Call before anything reads Settings.
    static func migrateLegacyDefaults() {
        guard defaults.object(forKey: "hotkey") == nil,
              defaults.object(forKey: "locale") == nil,
              let legacy = UserDefaults(suiteName: "local.whisperflow")
        else { return }
        for key in ["hotkey", "locale", "styleDefault", "styleOverrides"] {
            if defaults.object(forKey: key) == nil,
               let value = legacy.object(forKey: key) {
                defaults.set(value, forKey: key)
            }
        }
    }

    static var hotkey: HotkeyMonitor.Hotkey {
        get {
            HotkeyMonitor.Hotkey(
                rawValue: defaults.string(forKey: "hotkey") ?? "") ?? .fn
        }
        set { defaults.set(newValue.rawValue, forKey: "hotkey") }
    }

    static var localeIdentifier: String {
        get { defaults.string(forKey: "locale") ?? "en-US" }
        set { defaults.set(newValue, forKey: "locale") }
    }

    /// Recognition engine: "apple" (instant) or "whisper" (precise).
    static var engine: String {
        get { defaults.string(forKey: "engine") ?? "apple" }
        set { defaults.set(newValue, forKey: "engine") }
    }

    static var whisperModel: String {
        get { defaults.string(forKey: "whisperModel") ?? "small" }
        set { defaults.set(newValue, forKey: "whisperModel") }
    }

    static var locale: Locale {
        Locale(identifier: localeIdentifier)
    }

    /// UID of the microphone to record from, or nil to follow the system
    /// default. A UID rather than an AudioObjectID because IDs are ephemeral
    /// handles that change between launches.
    static var inputDeviceUID: String? {
        get { defaults.string(forKey: "inputDeviceUID") }
        set { defaults.set(newValue, forKey: "inputDeviceUID") }
    }
}
