import Foundation

/// Serializes every mutating operation on the three synced stores (learned,
/// vocabulary, snippets) with `SyncedStore.syncAll` and its per-store halves,
/// so a periodic sync cycle can never interleave with a UI-triggered
/// load-modify-save. Before AMUX-756 sync ran once at launch, so the race
/// only existed in a narrow startup window; making sync periodic widens that
/// window to the app's whole lifetime, which is why this exists.
///
/// A synchronous serial `DispatchQueue` rather than an actor: every store is
/// enum-static with synchronous callers on the MainActor (SwiftUI `onAppear`
/// closures, button actions, and the CLI's `--format`/`--transcribe` paths).
/// An actor would force every one of those call sites through `await`, which
/// ripples into MainView's non-async view code for no real benefit here -
/// the work itself is a JSON encode/decode plus a coordinated file write, not
/// something that gains from actor isolation, and a queue keeps every
/// existing synchronous signature intact.
enum StoreOwner {
    private static let key = DispatchSpecificKey<Void>()
    private static let queue: DispatchQueue = {
        let queue = DispatchQueue(label: "local.yafda.store-owner")
        queue.setSpecific(key: key, value: ())
        return queue
    }()

    /// True for the duration of a sync cycle (`syncAll` and its per-store
    /// halves), including every nested store call it makes. Stores check
    /// this before scheduling a debounced sync so a cycle's own write-back
    /// does not schedule its own successor - without this guard every sync
    /// would perpetually re-trigger another one a few seconds later. Only
    /// ever read or written while already running on `queue` (inside `sync`
    /// or `syncCycle`), so the plain static var needs no lock of its own.
    private static var isSyncCycle = false
    static var isRunningSyncCycle: Bool { isSyncCycle }

    /// Runs `body` on the owner queue and returns its result.
    ///
    /// Re-entrancy: a store's own entry point (say `LearnedStore.add`) wraps
    /// its whole load-modify-save in one `sync` call; if that body then
    /// calls another owned entry point (`VocabularyStore.words()`, during
    /// `LearnedStore.learn`'s taught-word lookup, say), a plain serial queue
    /// would deadlock re-entering `queue.sync` from the thread already
    /// running on it. `DispatchSpecificKey` detects that case - `getSpecific`
    /// only returns non-nil on the queue's own thread - and runs the nested
    /// call inline instead of re-entering the queue.
    static func sync<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: key) != nil {
            return body()
        }
        return queue.sync(execute: body)
    }

    /// Same as `sync`, additionally marking the whole call (including every
    /// nested store call it makes) as a sync cycle, so writes inside it skip
    /// the after-write debounce trigger. Nests correctly with a plain `sync`
    /// or another `syncCycle` inside it: the flag is saved and restored
    /// around `body`, and reentrancy is handled the same way as `sync`.
    static func syncCycle<T>(_ body: () -> T) -> T {
        sync {
            let previous = isSyncCycle
            isSyncCycle = true
            defer { isSyncCycle = previous }
            return body()
        }
    }

    // MARK: - Self test

    static func runSelfTest() -> Bool {
        var passed = true

        // MARK: Concurrent mutation + a sync cycle must not lose an update
        // The regression this exists to prevent: periodic sync (AMUX-756)
        // widens the always-existed launch-window race to the whole app
        // lifetime, so mutations racing a sync cycle must serialize instead
        // of interleaving mid load-modify-save.
        do {
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("yafda-selftest-owner-\(UUID().uuidString)",
                                        isDirectory: true)
            let localDir = scratch.appendingPathComponent("local", isDirectory: true)
            let remoteDir = scratch.appendingPathComponent("remote", isDirectory: true)
            try? FileManager.default.createDirectory(
                at: localDir, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(
                at: remoteDir, withIntermediateDirectories: true)
            LearnedStore.directoryOverride = localDir
            defer {
                LearnedStore.directoryOverride = nil
                try? FileManager.default.removeItem(at: scratch)
            }

            let termCount = 20
            let group = DispatchGroup()
            for i in 0..<termCount {
                group.enter()
                DispatchQueue.global().async {
                    LearnedStore.addTerm("term-\(i)")
                    group.leave()
                }
            }
            // A sync cycle runs concurrently with the mutations above - it
            // must not read stale local data mid-write and clobber it.
            group.enter()
            DispatchQueue.global().async {
                var base = SyncBase()
                for _ in 0..<10 {
                    SyncedStore.syncLearned(in: remoteDir, base: &base)
                }
                group.leave()
            }
            group.wait()

            let finalTerms = Set(LearnedStore.load().terms)
            let expectedTerms = Set((0..<termCount).map { "term-\($0)" })
            let noLostUpdate = expectedTerms.isSubset(of: finalTerms)
            let onDiskParses = (try? Data(contentsOf: LearnedStore.fileURL))
                .flatMap { try? JSONDecoder().decode(LearnedData.self, from: $0) } != nil
            let ok = noLostUpdate && onDiskParses
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): concurrent mutation + sync cycle: " +
                  "\(expectedTerms.intersection(finalTerms).count)/\(termCount) terms " +
                  "survived, on-disk parses = \(onDiskParses)")
        }

        return passed
    }
}
