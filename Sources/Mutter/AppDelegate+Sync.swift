import AppKit
import Foundation

/// The Layer 2 sync triggers (AMUX-756) that don't already live next to an
/// existing delegate method: wake from sleep, the hourly backstop, and a
/// bounded final sync on quit. Activation's trigger stays in
/// `AppDelegate.swift` itself, next to `applicationDidBecomeActive`, since it
/// extends that method rather than adding a new one - only the wiring with
/// nowhere else to go moved here, to keep `AppDelegate.swift` from growing
/// past the project's file-size guidance for a feature that could live
/// self-contained in its own file.
extension AppDelegate {
    /// Registers the wake observer and starts the hourly backstop timer.
    /// Called once from `applicationDidFinishLaunching`.
    func setUpSyncTriggers() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(handleWake),
            name: NSWorkspace.didWakeNotification, object: nil)
        hourlySyncTimer = Timer.scheduledTimer(
            withTimeInterval: 3600, repeats: true) { _ in
            SyncScheduler.triggerUnconditional(reason: "hourly backstop")
        }
    }

    /// The other moment the user likely switched Macs. Rate-limited the same
    /// way as activation.
    @objc func handleWake() {
        SyncScheduler.triggerRateLimited(reason: "wake")
    }

    /// Bounded so a slow or stuck iCloud coordinator can never hang quit.
    func applicationWillTerminate(_ notification: Notification) {
        SyncScheduler.runFinalSyncBeforeQuit()
    }
}
