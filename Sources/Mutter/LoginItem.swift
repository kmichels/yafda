import Foundation
import ServiceManagement
import os

/// Registers Mutter to start at login.
///
/// A menu-bar app with `LSUIElement` has no Dock icon and no window when it is
/// not running, so after a reboot the dictation key simply does nothing and
/// there is nothing on screen to explain why. That failure is more likely to
/// strand a new user than the Accessibility grant everyone worries about.
enum LoginItem {
    private static let log = Logger(subsystem: "local.mutter", category: "LoginItem")

    /// What macOS currently believes, which is not always what we asked for —
    /// the user can revoke a login item in System Settings behind our back.
    static var isRegistered: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// True when the user disabled it in System Settings rather than in Mutter.
    /// Worth surfacing: the in-app toggle would otherwise look broken.
    static var wasDeniedBySystem: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                // register() throws if it is already registered; that is a
                // success from the caller's point of view, not a failure.
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
            Settings.launchAtLogin = enabled
            return true
        } catch {
            log.error("""
                Failed to \(enabled ? "register" : "unregister", privacy: .public) \
                login item: \(error.localizedDescription, privacy: .public)
                """)
            return false
        }
    }

    /// Reconciles macOS's view with ours at launch. If the user turned the
    /// login item off in System Settings, the in-app toggle must follow rather
    /// than silently disagree.
    static func synchronize() {
        let system = isRegistered
        if Settings.launchAtLogin != system {
            log.notice("""
                Login item is \(system ? "on" : "off", privacy: .public) in System \
                Settings but \(Settings.launchAtLogin ? "on" : "off", privacy: .public) \
                here; following the system.
                """)
            Settings.launchAtLogin = system
        }
    }
}
