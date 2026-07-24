import AppKit
import Foundation

/// Watches the chosen modifier key globally.
/// - Hold = push-to-talk (release stops).
/// - Double-tap = hands-free toggle (tap again to stop).
/// Requires Accessibility permission for global key monitoring.
final class HotkeyMonitor {

    enum Hotkey: String, CaseIterable {
        case fn
        case rightOption

        var displayName: String {
            switch self {
            case .fn: return "fn (Globe)"
            case .rightOption: return "Right Option (⌥)"
            }
        }

        var keyCode: UInt16 {
            switch self {
            case .fn: return 63
            case .rightOption: return 61
            }
        }

        var flag: NSEvent.ModifierFlags {
            switch self {
            case .fn: return .function
            case .rightOption: return .option
            }
        }
    }

    var hotkey: Hotkey
    var onStart: (() -> Void)?
    /// Called when dictation should stop and be transcribed.
    var onStop: (() -> Void)?
    /// Called when a too-short press should be discarded.
    var onCancel: (() -> Void)?
    var onHandsFreeChange: ((Bool) -> Void)?

    private(set) var isHandsFree = false
    private var monitor: Any?
    private var keyIsDown = false
    private var pressStartedAt: Date?
    private var lastTapEndedAt: Date?

    /// Presses shorter than this count as taps, not push-to-talk.
    private let tapThreshold: TimeInterval = 0.35
    private let doubleTapWindow: TimeInterval = 0.5

    init(hotkey: Hotkey = .fn) {
        self.hotkey = hotkey
    }

    func startMonitoring() {
        stopMonitoring()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) {
            [weak self] event in
            self?.handle(event)
        }
    }

    func stopMonitoring() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    private func handle(_ event: NSEvent) {
        guard event.keyCode == hotkey.keyCode else { return }
        let pressed = event.modifierFlags.contains(hotkey.flag)
        if pressed, !keyIsDown {
            keyIsDown = true
            keyDown()
        } else if !pressed, keyIsDown {
            keyIsDown = false
            keyUp()
        }
    }

    private func keyDown() {
        if isHandsFree {
            // Any press while hands-free stops the session.
            isHandsFree = false
            onHandsFreeChange?(false)
            onStop?()
            pressStartedAt = nil
            lastTapEndedAt = nil
            return
        }
        pressStartedAt = Date()
        onStart?()
    }

    private func keyUp() {
        guard let startedAt = pressStartedAt else { return }
        pressStartedAt = nil
        let holdDuration = Date().timeIntervalSince(startedAt)

        if holdDuration >= tapThreshold {
            // Push-to-talk: release ends dictation.
            lastTapEndedAt = nil
            onStop?()
            return
        }

        // Short press: tap. Two taps in quick succession → hands-free.
        if let lastTap = lastTapEndedAt,
           Date().timeIntervalSince(lastTap) <= doubleTapWindow {
            lastTapEndedAt = nil
            isHandsFree = true
            onHandsFreeChange?(true)
            // Keep recording; it started on this key-down.
        } else {
            lastTapEndedAt = Date()
            onCancel?()
        }
    }
}
