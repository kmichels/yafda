import Foundation
import os

/// Decides WHEN a sync cycle runs - quit, wake, activation, a debounced
/// window after a local write, and an hourly backstop - and coalesces the
/// triggers that ask for one. All the actual store I/O still happens through
/// `SyncedStore`/`StoreOwner`; this only owns timing, so it stays testable
/// with an injected clock and cycle instead of real sleeps or real iCloud.
enum SyncScheduler {
    private static let log = Logger(subsystem: "local.yafda", category: "sync")
    private static let queue = DispatchQueue(label: "local.yafda.sync-scheduler")

    /// Tests inject their own clock so rate-limit cases never depend on
    /// wall-clock sleeps.
    static var now: () -> Date = { Date() }
    /// Tests inject a stand-in cycle so coalescing/rate-limit cases never
    /// touch the real store or require iCloud.
    static var runCycle: () -> Void = { SyncedStore.syncAll() }
    /// Tests inject a synchronous stand-in that captures the scheduled work
    /// instead of really waiting `debounceInterval` seconds.
    static var scheduleAfterDelay: (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// A few seconds' grace after a write, so several rapid mutations
    /// coalesce into one sync instead of one per edit.
    static let debounceInterval: TimeInterval = 3
    /// Activation/wake are Cmd-Tab-frequent; skip when the last cycle
    /// finished more recently than this.
    static let minimumInterval: TimeInterval = 300

    /// Read by the settings UI (main thread) while the scheduler's queue
    /// writes it, so access goes through its own lock — NOT `queue.sync`,
    /// which would park the main thread behind an in-flight sync cycle.
    static var lastCycleAt: Date? {
        lastCycleLock.lock()
        defer { lastCycleLock.unlock() }
        return _lastCycleAt
    }
    private static let lastCycleLock = NSLock()
    private static var _lastCycleAt: Date?
    private static func setLastCycleAt(_ date: Date?) {
        lastCycleLock.lock()
        defer { lastCycleLock.unlock() }
        _lastCycleAt = date
    }
    private static var debounceGeneration = 0

    /// The sync row's caption. Pure so it is testable; state comes from the
    /// caller because the truth lives in three places (the toggle, iCloud
    /// availability, this scheduler) and the caption must reflect all three,
    /// never just the toggle position.
    static func statusDescription(
        enabled: Bool, cloudAvailable: Bool, lastCycleAt: Date?, now: Date
    ) -> String {
        guard enabled else {
            return "Shares your dictionary, learned corrections and snippets " +
                   "between your Macs through a YAFDA folder in iCloud Drive. " +
                   "The first sync completes on the next launch."
        }
        guard cloudAvailable else {
            return "Waiting for iCloud Drive — sign in (or let it finish " +
                   "syncing) and YAFDA will pick it up."
        }
        guard let lastCycleAt else {
            return "On — not yet synced this launch."
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let relative = formatter.localizedString(for: lastCycleAt, relativeTo: now)
        return "On — last synced \(relative)."
    }

    /// Resets all scheduler state. Test-only: production never needs to
    /// forget history mid-run.
    static func resetForTesting() {
        now = { Date() }
        runCycle = { SyncedStore.syncAll() }
        scheduleAfterDelay = { delay, work in queue.asyncAfter(deadline: .now() + delay, execute: work) }
        setLastCycleAt(nil)
        debounceGeneration = 0
    }

    /// Test-only: blocks until every currently-queued trigger has finished
    /// running, so self-tests can assert state deterministically instead of
    /// racing the scheduler's own background queue.
    static func waitUntilIdle() {
        queue.sync {}
    }

    private static func runNow(reason: String) {
        log.info("sync trigger (\(reason, privacy: .public)): running")
        runCycle()
        setLastCycleAt(now())
    }

    /// Quit, and the hourly backstop: always runs, no rate limit.
    static func triggerUnconditional(reason: String) {
        queue.async { runNow(reason: reason) }
    }

    /// Wake and activation: skip when the last cycle is still recent, so
    /// Cmd-Tab-heavy use does not turn into a sync storm.
    static func triggerRateLimited(reason: String) {
        queue.async {
            if let last = lastCycleAt {
                let elapsed = now().timeIntervalSince(last)
                guard elapsed >= minimumInterval else {
                    log.info("""
                        sync trigger (\(reason, privacy: .public)): skipped - \
                        last cycle \(Int(elapsed), privacy: .public)s ago
                        """)
                    return
                }
            }
            runNow(reason: reason)
        }
    }

    /// After-write: schedules a cycle `debounceInterval` out. A later call
    /// before that fires supersedes it, so N rapid writes coalesce into one
    /// cycle instead of N. Coalescing is done with a generation counter
    /// rather than `DispatchWorkItem.cancel()`: the counter is trivial to
    /// drive from a test's injected `scheduleAfterDelay` (which never really
    /// waits), where cancelling a stored work item would not be.
    static func triggerDebounced(reason: String) {
        queue.async {
            debounceGeneration += 1
            let thisGeneration = debounceGeneration
            scheduleAfterDelay(debounceInterval) {
                queue.async {
                    // A later write bumped the generation while this one was
                    // waiting out its delay - that later write's own timer
                    // will run the cycle, so this stale one is a no-op.
                    guard thisGeneration == debounceGeneration else { return }
                    runNow(reason: reason)
                }
            }
        }
    }

    /// Quit: runs a cycle now, bounded so a slow or stuck iCloud coordinator
    /// can never hang app termination. Mirrors the bounded-wait model
    /// `AppPaths.readShared` already uses against the same daemon - this is
    /// the outer bound at the trigger level, not a replacement for it.
    static func runFinalSyncBeforeQuit(timeout: TimeInterval = 5) {
        let semaphore = DispatchSemaphore(value: 0)
        queue.async {
            runNow(reason: "quit")
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + timeout)
    }

    // MARK: - Self test

    static func runSelfTest() -> Bool {
        var passed = true

        // MARK: statusDescription reflects real state, not the toggle
        do {
            let now = Date(timeIntervalSince1970: 2_000_000)
            let recent = now.addingTimeInterval(-120)
            let cases: [(name: String, got: String, want: (String) -> Bool)] = [
                ("disabled invites and names iCloud Drive",
                 statusDescription(enabled: false, cloudAvailable: true,
                                   lastCycleAt: nil, now: now),
                 { $0.contains("iCloud Drive") }),
                ("enabled without iCloud says waiting",
                 statusDescription(enabled: true, cloudAvailable: false,
                                   lastCycleAt: recent, now: now),
                 { $0.localizedCaseInsensitiveContains("waiting") }),
                ("enabled before first cycle says not yet",
                 statusDescription(enabled: true, cloudAvailable: true,
                                   lastCycleAt: nil, now: now),
                 { $0.localizedCaseInsensitiveContains("not yet") }),
                ("enabled after a cycle gives a relative time",
                 statusDescription(enabled: true, cloudAvailable: true,
                                   lastCycleAt: recent, now: now),
                 { $0.localizedCaseInsensitiveContains("ago") }),
            ]
            for testCase in cases {
                let ok = testCase.want(testCase.got)
                if !ok { passed = false }
                print("\(ok ? "PASS" : "FAIL"): sync status/\(testCase.name) = " +
                      "\"\(testCase.got)\"")
            }
        }

        // MARK: Debounce coalesces rapid mutations into one scheduled cycle
        do {
            resetForTesting()
            var cycleCount = 0
            runCycle = { cycleCount += 1 }
            var capturedWork: [() -> Void] = []
            scheduleAfterDelay = { _, work in capturedWork.append(work) }

            for _ in 0..<5 {
                triggerDebounced(reason: "test-write")
            }
            waitUntilIdle()
            let scheduledCount = capturedWork.count
            // Fire every captured closure, as if all five delays had
            // elapsed - only the most recent one should still count.
            capturedWork.forEach { $0() }
            waitUntilIdle()

            let coalescedOK = scheduledCount == 5 && cycleCount == 1
            if !coalescedOK { passed = false }
            print("\(coalescedOK ? "PASS" : "FAIL"): debounce/5 rapid writes schedule " +
                  "\(scheduledCount) attempt(s) but coalesce to \(cycleCount) run(s)")
        }

        // MARK: Rate limit skips inside the window, runs outside it
        do {
            resetForTesting()
            var cycleCount = 0
            runCycle = { cycleCount += 1 }
            var clock = Date(timeIntervalSince1970: 1_000_000)
            now = { clock }

            triggerRateLimited(reason: "activate")
            waitUntilIdle()
            let firstRan = cycleCount == 1

            clock = clock.addingTimeInterval(60)   // inside the 5-minute window
            triggerRateLimited(reason: "activate")
            waitUntilIdle()
            let insideSkipped = cycleCount == 1

            clock = clock.addingTimeInterval(400)  // outside the 5-minute window
            triggerRateLimited(reason: "activate")
            waitUntilIdle()
            let outsideRan = cycleCount == 2

            let ok = firstRan && insideSkipped && outsideRan
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): rate limit: first=\(firstRan) " +
                  "insideWindowSkipped=\(insideSkipped) outsideWindowRan=\(outsideRan)")
        }

        resetForTesting()
        return passed
    }
}
