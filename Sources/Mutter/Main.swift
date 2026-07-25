import AppKit
import Foundation

@main
struct MutterMain {
    @MainActor
    static func main() async {
        Settings.migrateLegacyDefaults()
        var arguments = Array(CommandLine.arguments.dropFirst()).makeIterator()
        var mode: Mode = .app
        var localeIdentifier = "en-US"
        var engineName = "apple"
        var whisperModel = Settings.whisperModel

        while let argument = arguments.next() {
            switch argument {
            case "--transcribe":
                guard let path = arguments.next() else { usageAndExit() }
                mode = .transcribe(path)
            case "--engine":
                engineName = arguments.next() ?? engineName
            case "--whisper-model":
                whisperModel = arguments.next() ?? whisperModel
            case "--format":
                guard let text = arguments.next() else { usageAndExit() }
                mode = .format(text)
            case "--transform":
                guard let text = arguments.next() else { usageAndExit() }
                mode = .transform(text)
            case "--selftest":
                mode = .selftest
            case "--locale":
                localeIdentifier = arguments.next() ?? localeIdentifier
            case "--help", "-h":
                usageAndExit()
            default:
                // An argument this parser has never seen must not be able to
                // kill a GUI launch. LaunchServices, login items, `open --args`
                // and Automator wrappers can all introduce one; exiting here
                // makes the app vanish with status 0 and no window, which the
                // user cannot distinguish from a crash and cannot report.
                // Anything not spelled --like-this is treated as launch noise
                // and ignored; a malformed --flag still gets usage, because
                // that is a person at a terminal making a typo.
                if isLaunchNoise(argument) { continue }
                usageAndExit()
            }
        }

        switch mode {
        case .selftest:
            let formatterPassed = TextFormatter.runSelfTest()
            let learnedPassed = await LearnedStore.runSelfTest()
            let syncPassed = SyncMerge.runSelfTest()
            let micPassed = MicMonitor.runSelfTest()
            let historyPassed = HistoryStore.runSelfTest()
            let storeOwnerPassed = StoreOwner.runSelfTest()
            let schedulerPassed = SyncScheduler.runSelfTest()
            exit(formatterPassed && learnedPassed && syncPassed && micPassed
                 && historyPassed && storeOwnerPassed && schedulerPassed ? 0 : 1)

        case .format(let text):
            // Same pipeline as live dictation: format, apply learned
            // corrections, then expand snippets.
            print(SnippetStore.expand(
                in: LearnedStore.apply(in: TextFormatter().format(text))))
            exit(0)

        case .transform(let text):
            let engine = RewriteEngine()
            if let note = engine.availabilityNote {
                FileHandle.standardError.write(Data("Unavailable: \(note)\n".utf8))
                exit(1)
            }
            do {
                let polished = try await engine.rewrite(
                    text, instructions: Transform.all[0].instructions)
                print(polished)
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("Failed: \(error)\n".utf8))
                exit(1)
            }

        case .transcribe(let path):
            do {
                let raw: String
                if engineName == "whisper" {
                    let whisper = WhisperEngine()
                    whisper.onStatus = { status in
                        if let status {
                            FileHandle.standardError.write(Data("\(status)\n".utf8))
                        }
                    }
                    raw = try await whisper.transcribe(
                        fileAt: URL(fileURLWithPath: path),
                        model: whisperModel,
                        localeID: localeIdentifier,
                        biasTerms: LearnedStore.biasTerms())
                } else {
                    let transcriber = Transcriber(
                        locale: Locale(identifier: localeIdentifier))
                    raw = try await transcriber.transcribe(
                        fileAt: URL(fileURLWithPath: path),
                        biasTerms: LearnedStore.biasTerms())
                }
                // Full live-dictation pipeline: format → learned corrections
                // → snippet expansion.
                let formatted = SnippetStore.expand(
                    in: LearnedStore.apply(in: TextFormatter().format(raw)))
                print("RAW: \(raw)")
                print("FORMATTED: \(formatted)")
                exit(0)
            } catch {
                FileHandle.standardError.write(
                    Data("Transcription failed: \(error)\n".utf8))
                exit(1)
            }

        case .app:
            let app = NSApplication.shared
            // Regular, not accessory: Cmd-Tab must reach the dashboard
            // (removing LSUIElement from the plist is not enough - this call
            // overrides it). Explicit rather than plist-defaulted so the bare
            // .build binary a dev launches gets UI capability too.
            app.setActivationPolicy(.regular)
            let delegate = AppDelegate()
            app.delegate = delegate
            // Merge with the other Mac off the main thread, via the same
            // scheduler every later trigger uses. A coordinated read can
            // block on the iCloud daemon, and a hang before `run()` would
            // leave Mutter bouncing in the Dock with no UI at all. Routing
            // through SyncScheduler (rather than calling SyncedStore.syncAll
            // directly) also sets `lastCycleAt`, so the activation trigger
            // NSApp fires moments later during `showMainWindow()` correctly
            // rate-limits against this launch sync instead of double-firing.
            SyncScheduler.triggerUnconditional(reason: "launch")
            app.run()
        }
    }

    private enum Mode {
        case app
        case transcribe(String)
        case format(String)
        case transform(String)
        case selftest
    }

    /// True when an unrecognised argument looks like something the system
    /// passed us rather than something a person typed.
    ///
    /// Process serial numbers (`-psn_0_12345`), file paths from a drag-onto-icon,
    /// and `-NSFoo` style defaults overrides all arrive without a `--` prefix.
    /// None of them should stop the app from launching.
    static func isLaunchNoise(_ argument: String) -> Bool {
        !argument.hasPrefix("--")
    }

    private static func usageAndExit() -> Never {
        print("""
        Mutter — local dictation (hold fn to talk, release to paste)

        Usage:
          Mutter                      run as menu bar app
          Mutter --transcribe <file>  transcribe an audio file
                                      [--locale en-US] [--engine apple|whisper]
                                      [--whisper-model base|small|large-v3-v20240930_turbo]
          Mutter --format "<text>"    run the text formatter on a string
          Mutter --selftest           run formatter self-tests
        """)
        exit(0)
    }
}
