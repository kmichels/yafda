import Foundation

enum SyncMerge {
    /// Three-way merge of one keyed collection.
    ///
    /// `base` is what this machine saw at its last successful sync, so a key
    /// present in `base` and absent in `local` was deleted here rather than
    /// merely missing. That is what lets deletion propagate without tombstones.
    ///
    /// - Parameter resolve: called only when both sides changed the same key to
    ///   different non-nil values.
    static func merge<Value: Equatable>(
        base: [String: Value], local: [String: Value], remote: [String: Value],
        resolve: (Value, Value) -> Value) -> [String: Value] {
        var result = local
        for key in Set(base.keys).union(local.keys).union(remote.keys) {
            let baseValue = base[key]
            let localValue = local[key]
            let remoteValue = remote[key]
            switch (localValue != baseValue, remoteValue != baseValue) {
            case (false, false):
                break                                   // nobody touched it
            case (true, false):
                result[key] = localValue                // nil here means we deleted it
            case (false, true):
                result[key] = remoteValue               // nil here means they deleted it
            case (true, true):
                // An edit beats a delete: losing an edit is unrecoverable,
                // whereas an unwanted entry can be deleted again.
                switch (localValue, remoteValue) {
                case let (localValue?, remoteValue?):
                    result[key] = resolve(localValue, remoteValue)
                case let (localValue?, nil):
                    result[key] = localValue
                case let (nil, remoteValue?):
                    result[key] = remoteValue
                case (nil, nil):
                    result[key] = nil
                }
            }
        }
        return result
    }

    /// Unions vocabulary terms, case-insensitively, keeping first-seen casing.
    ///
    /// Terms are union-only on purpose: the UI has no way to delete one, so a
    /// term missing on one machine means it was never learned there, not that
    /// it was removed.
    static func mergeTerms(base: [String], local: [String],
                           remote: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for term in local + remote {
            let key = term.lowercased()
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(term)
        }
        if result.count > 300 { result.removeFirst(result.count - 300) }
        return result
    }

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

        // MARK: Three-way merge
        // Values are plain strings; `resolve` prefers local on a real conflict.
        func merged(_ base: [String: String], _ local: [String: String],
                    _ remote: [String: String]) -> [String: String] {
            SyncMerge.merge(base: base, local: local, remote: remote) { l, _ in l }
        }
        let mergeCases: [(name: String, got: [String: String], expected: [String: String])] = [
            ("unchanged",
             merged(["a": "1"], ["a": "1"], ["a": "1"]), ["a": "1"]),
            ("disjoint additions keep both",
             merged([:], ["a": "1"], ["b": "2"]), ["a": "1", "b": "2"]),
            // The regression this design exists to prevent.
            ("local delete is not resurrected",
             merged(["a": "1"], [:], ["a": "1"]), [:]),
            ("remote delete propagates",
             merged(["a": "1"], ["a": "1"], [:]), [:]),
            ("delete loses to a concurrent edit (remote deleted)",
             merged(["a": "1"], ["a": "2"], [:]), ["a": "2"]),
            ("delete loses to a concurrent edit (local deleted)",
             merged(["a": "1"], [:], ["a": "9"]), ["a": "9"]),
            ("remote edit wins when local untouched",
             merged(["a": "1"], ["a": "1"], ["a": "9"]), ["a": "9"]),
            ("local edit wins when remote untouched",
             merged(["a": "1"], ["a": "9"], ["a": "1"]), ["a": "9"]),
            ("both edited resolves to local",
             merged(["a": "1"], ["a": "L"], ["a": "R"]), ["a": "L"]),
            // Seeding the second machine: no base means union, never deletion.
            ("missing base unions",
             merged([:], ["a": "1"], ["b": "2"]), ["a": "1", "b": "2"]),
            ("both deleted stays deleted",
             merged(["a": "1"], [:], [:]), [:]),
        ]
        for testCase in mergeCases {
            let ok = testCase.got == testCase.expected
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): merge/\(testCase.name) = \(testCase.got)" +
                  (ok ? "" : " (expected \(testCase.expected))"))
        }

        // Terms have no delete UI, so a removal must never be inferred.
        let termsGot = SyncMerge.mergeTerms(
            base: ["Phocus"], local: ["Phocus", "Lightroom"], remote: ["phocus", "JPEG"])
        let termsOK = termsGot == ["Phocus", "Lightroom", "JPEG"]
        if !termsOK { passed = false }
        print("\(termsOK ? "PASS" : "FAIL"): mergeTerms = \(termsGot)")

        return passed
    }
}
