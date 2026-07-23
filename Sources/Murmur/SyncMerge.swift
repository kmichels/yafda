import Foundation

enum SyncMerge {
    // MARK: - Self test

    static func runSelfTest() -> Bool {
        var passed = true

        // iCloud Drive may or may not exist on the machine running the tests, so
        // assert the contract rather than a particular answer.
        let synced = AppPaths.syncedDirectory
        let syncedOK = synced == nil || synced?.lastPathComponent == "Murmur"
        if !syncedOK { passed = false }
        print("\(syncedOK ? "PASS" : "FAIL"): syncedDirectory = " +
              "\(synced?.path ?? "nil (iCloud Drive unavailable)")")

        let baseOK = AppPaths.syncBaseURL.lastPathComponent == "sync-base.json"
            && AppPaths.syncBaseURL.deletingLastPathComponent().path
                == AppPaths.supportDirectory.path
        if !baseOK { passed = false }
        print("\(baseOK ? "PASS" : "FAIL"): syncBaseURL is local, not in iCloud")

        // An absent file must report .missing, never .ready(empty).
        let missing = AppPaths.supportDirectory
            .appendingPathComponent("definitely-not-here.json")
        var missingOK = false
        if case .missing = AppPaths.readShared(missing) { missingOK = true }
        if !missingOK { passed = false }
        print("\(missingOK ? "PASS" : "FAIL"): absent file reports .missing")

        // A placeholder must report .notDownloaded, NOT .missing - seeding an
        // evicted file from local data would destroy the other Mac's changes.
        let evicted = AppPaths.supportDirectory
            .appendingPathComponent("evicted-probe.json")
        let evictedPlaceholder = AppPaths.supportDirectory
            .appendingPathComponent(".evicted-probe.json.icloud")
        try? Data("placeholder".utf8).write(to: evictedPlaceholder)
        var evictedOK = false
        if case .notDownloaded = AppPaths.readShared(evicted) { evictedOK = true }
        try? FileManager.default.removeItem(at: evictedPlaceholder)
        if !evictedOK { passed = false }
        print("\(evictedOK ? "PASS" : "FAIL"): evicted file reports .notDownloaded")

        // The paths that actually move bytes: writeShared then readShared must
        // round-trip exact data as .ready. Uses supportDirectory (always
        // present) so the test runs even when iCloud Drive is absent.
        let probeURL = AppPaths.supportDirectory
            .appendingPathComponent("sync-write-probe.json")
        let probeData = Data(#"{"probe":true}"#.utf8)
        let wrote = AppPaths.writeShared(probeData, to: probeURL)
        var roundTrip = false
        if case .ready(let got) = AppPaths.readShared(probeURL), got == probeData {
            roundTrip = true
        }
        try? FileManager.default.removeItem(at: probeURL)
        let writeOK = wrote && roundTrip
        if !writeOK { passed = false }
        print("\(writeOK ? "PASS" : "FAIL"): writeShared/readShared round-trip .ready")

        return passed
    }
}
