import AppKit
import Foundation
import os

/// Refuses to run alongside another YAFDA under a different bundle id.
///
/// Dev (`local.mutter`) and release (`com.konradmichels.mutter`) builds are
/// different bundle ids, so `LSMultipleInstancesProhibited` no longer
/// prevents one of each running at once - while both share the same data
/// folder (keyed on app NAME, deliberately: dogfooding is the QA) and the
/// same sync files. Two live instances means two event monitors, double
/// paste keystrokes, and a second process `StoreOwner` cannot serialize
/// against. One of them has to stand down; the one launching second does.
enum InstanceGuard {
    private static let log = Logger(subsystem: "local.yafda", category: "InstanceGuard")

    struct AppDescriptor {
        var executableName: String?
        var bundleID: String?
        var isSelf: Bool
    }

    /// The pure decision: the first running app that is also named YAFDA
    /// under a DIFFERENT bundle id, self excluded. Same name + same id is
    /// not a conflict here - that is `LSMultipleInstancesProhibited`'s job.
    static func conflictingApp(
        myBundleID: String?, apps: [AppDescriptor]) -> AppDescriptor? {
        apps.first { app in
            !app.isSelf
                && app.executableName == "YAFDA"
                && app.bundleID != myBundleID
        }
    }

    /// Scans running applications and, on conflict, alerts and terminates
    /// this instance. Called first from `applicationDidFinishLaunching`,
    /// before sync triggers or monitors start.
    @MainActor
    static func enforceAtLaunch() {
        let descriptors = NSWorkspace.shared.runningApplications.map {
            AppDescriptor(
                executableName: $0.executableURL?.lastPathComponent,
                bundleID: $0.bundleIdentifier,
                isSelf: $0.processIdentifier == ProcessInfo.processInfo.processIdentifier)
        }
        guard let other = conflictingApp(
            myBundleID: Bundle.main.bundleIdentifier, apps: descriptors)
        else { return }
        log.error("""
            Another YAFDA is already running \
            (\(other.bundleID ?? "unknown bundle id", privacy: .public)); quitting.
            """)
        let alert = NSAlert()
        alert.messageText = "Another YAFDA is already running"
        alert.informativeText = """
            A YAFDA with a different bundle id \
            (\(other.bundleID ?? "unknown")) is already running - probably a \
            dev build alongside the installed release. Both share the same \
            data, so only one can run. This copy will quit; close the other \
            one first if you meant to run this one.
            """
        alert.runModal()
        NSApp.terminate(nil)
    }

    // MARK: - Self test

    static func runSelfTest() -> Bool {
        var passed = true
        let releaseID = "com.konradmichels.mutter"
        let devID = "local.mutter"
        let cases: [(name: String, apps: [AppDescriptor], expectConflict: Bool)] = [
            ("dev running, release launching",
             [AppDescriptor(executableName: "YAFDA", bundleID: devID, isSelf: false)],
             true),
            ("same bundle id is not this guard's job",
             [AppDescriptor(executableName: "YAFDA", bundleID: releaseID, isSelf: false)],
             false),
            ("other apps never conflict",
             [AppDescriptor(executableName: "Safari", bundleID: "com.apple.Safari",
                            isSelf: false)],
             false),
            ("self is excluded even under another id",
             [AppDescriptor(executableName: "YAFDA", bundleID: devID, isSelf: true)],
             false),
        ]
        for testCase in cases {
            let got = conflictingApp(myBundleID: releaseID, apps: testCase.apps) != nil
            let ok = got == testCase.expectConflict
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): instance guard/\(testCase.name) = \(got)")
        }
        return passed
    }
}
