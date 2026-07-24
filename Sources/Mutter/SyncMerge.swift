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

        // MARK: Correction keying and conflict resolution
        // Corrections key on `heard` alone, matching LearnedStore.merging,
        // which already enforces one rule per phrase.
        let mine = LearnedCorrection(heard: "Lightrim", intended: "Lightroom", timesSeen: 3)
        let theirs = LearnedCorrection(heard: "lightrim", intended: "Lightroom", timesSeen: 7)
        let keyOK = SyncedStore.key(for: mine) == SyncedStore.key(for: theirs)
        if !keyOK { passed = false }
        print("\(keyOK ? "PASS" : "FAIL"): correction key ignores case")

        let winner = SyncedStore.resolve(mine, theirs)
        let resolveOK = winner.timesSeen == 7
        if !resolveOK { passed = false }
        print("\(resolveOK ? "PASS" : "FAIL"): colliding correction takes higher " +
              "timesSeen = \(winner.timesSeen)")

        // A store deleted on this machine must not come back from the remote.
        let baseCorrections = [
            "have": LearnedCorrection(heard: "have", intended: "work"),
            "lightrim": mine,
        ]
        let survived = SyncMerge.merge(
            base: baseCorrections,
            local: ["lightrim": mine],            // "have" pruned here
            remote: baseCorrections,              // laptop still has it
            resolve: SyncedStore.resolve)
        let prunedOK = survived["have"] == nil && survived["lightrim"] != nil
        if !prunedOK { passed = false }
        print("\(prunedOK ? "PASS" : "FAIL"): pruned rule stays pruned across sync")

        // MARK: Sync composition
        // Composition: a corrupt local store with a previously-synced base must
        // ABORT the sync (protecting the remote), not read as mass deletion.
        do {
            let syncTmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("mutter-selftest-synccomp", isDirectory: true)
            try? FileManager.default.removeItem(at: syncTmp)
            let localDir = syncTmp.appendingPathComponent("local", isDirectory: true)
            let remoteDir = syncTmp.appendingPathComponent("remote", isDirectory: true)
            try? FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: remoteDir, withIntermediateDirectories: true)
            LearnedStore.directoryOverride = localDir
            defer {
                LearnedStore.directoryOverride = nil
                try? FileManager.default.removeItem(at: syncTmp)
            }
            // Local file: corrupt. Base: says this machine had one correction.
            try? "not json ][".write(to: LearnedStore.fileURL, atomically: true, encoding: .utf8)
            // Remote: holds the same correction plus a new one from the other Mac.
            let remoteCorrections = [
                LearnedCorrection(heard: "lightrim", intended: "Lightroom", timesSeen: 2),
                LearnedCorrection(heard: "phocus", intended: "Phocus", timesSeen: 1),
            ]
            var remoteData = LearnedData()
            remoteData.corrections = remoteCorrections
            if let bytes = try? JSONEncoder().encode(remoteData) {
                try? bytes.write(to: remoteDir.appendingPathComponent("learned.json"))
            }
            var base = SyncBase()
            base.corrections = ["lightrim": remoteCorrections[0]]
            let baseBefore = base
            SyncedStore.syncLearned(in: remoteDir, base: &base)
            // Abort means: base unchanged, corrupt local file untouched, remote untouched.
            let localStillCorrupt = (try? String(contentsOf: LearnedStore.fileURL, encoding: .utf8))?.contains("not json") == true
            let compOK = base == baseBefore && localStillCorrupt
            if !compOK { passed = false }
            print("\(compOK ? "PASS" : "FAIL"): corrupt local with synced base aborts, does not mass-delete")
        }

        // MARK: Snippet keying
        let snippetA = Snippet(trigger: "Sig Block", expansion: "Konrad")
        let snippetB = Snippet(trigger: "sig block", expansion: "Konrad M")
        let snippetKeyOK = SyncedStore.key(for: snippetA) == SyncedStore.key(for: snippetB)
        if !snippetKeyOK { passed = false }
        print("\(snippetKeyOK ? "PASS" : "FAIL"): snippet key ignores trigger case")

        // MARK: Vocabulary keying
        // Two machines mint different UUIDs for the same logical entry, so the
        // key must be the (word, misheard) content pair, never the id. Without
        // this, the first merge would duplicate every migrated entry.
        let vocabMine = VocabularyEntry(word: "X2D II", misheard: "X2D2")
        let vocabTheirs = VocabularyEntry(word: "x2d ii", misheard: "x2d2")
        let vocabKeyOK = SyncedStore.key(for: vocabMine) == SyncedStore.key(for: vocabTheirs)
        if !vocabKeyOK { passed = false }
        print("\(vocabKeyOK ? "PASS" : "FAIL"): vocabulary key is the case-insensitive " +
              "(word, misheard) pair, not the UUID")

        // A bare word and a correction with the same word are DIFFERENT entries.
        let bareWord = VocabularyEntry(word: "Phocus", misheard: nil)
        let correction = VocabularyEntry(word: "Phocus", misheard: "focus")
        let vocabDistinctOK = SyncedStore.key(for: bareWord) != SyncedStore.key(for: correction)
        if !vocabDistinctOK { passed = false }
        print("\(vocabDistinctOK ? "PASS" : "FAIL"): bare word and correction do not collide")

        // A vocabulary entry deleted here must not return from the other Mac.
        let vBase = [SyncedStore.key(for: bareWord): bareWord,
                     SyncedStore.key(for: correction): correction]
        let vLocal = [SyncedStore.key(for: bareWord): bareWord]
        let vocabularyMerged = SyncMerge.merge(
            base: vBase, local: vLocal, remote: vBase) { l, _ in l }
        let vocabularyOK = vocabularyMerged.count == 1
            && vocabularyMerged.values.first?.misheard == nil
        if !vocabularyOK { passed = false }
        print("\(vocabularyOK ? "PASS" : "FAIL"): deleted vocabulary entry stays deleted")

        // Same content, different UUIDs (both machines migrated independently)
        // must NOT read as an eternal conflict: local adopts the remote id.
        // Exercised through the SyncedStore normalization helper.
        let idA = VocabularyEntry(word: "X2D II", misheard: "X2D2")
        let idB = VocabularyEntry(word: "X2D II", misheard: "X2D2")
        // ids differ by construction - each init mints a UUID
        let adoptKey = SyncedStore.key(for: idA)
        let adopted = SyncedStore.adoptingRemoteIDs(
            local: [adoptKey: idB], remote: [adoptKey: idA])
        let adoptOK = adopted[adoptKey]?.id == idA.id
            && adopted[adoptKey]?.word == "X2D II"
        if !adoptOK { passed = false }
        print("\(adoptOK ? "PASS" : "FAIL"): content-equal entries adopt the remote id")

        // MARK: Seed guard for a just-created folder
        // A .missing inside a folder we just created must NOT seed (the other
        // Mac's listing may not have materialized). Exercised via syncLearned
        // against temp dirs with the flag forced.
        do {
            let seedTmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("mutter-selftest-seedguard", isDirectory: true)
            try? FileManager.default.removeItem(at: seedTmp)
            let localDir = seedTmp.appendingPathComponent("local", isDirectory: true)
            let remoteDir = seedTmp.appendingPathComponent("remote", isDirectory: true)
            try? FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: remoteDir, withIntermediateDirectories: true)
            LearnedStore.directoryOverride = localDir
            AppPaths.syncedDirectoryWasJustCreated = true
            defer {
                LearnedStore.directoryOverride = nil
                AppPaths.syncedDirectoryWasJustCreated = false
                try? FileManager.default.removeItem(at: seedTmp)
            }
            var learnedData = LearnedData()
            learnedData.corrections = [
                LearnedCorrection(heard: "focust", intended: "Phocus", timesSeen: 1),
            ]
            _ = LearnedStore.save(learnedData)
            var base = SyncBase()
            SyncedStore.syncLearned(in: remoteDir, base: &base)
            let remoteFileExists = FileManager.default.fileExists(
                atPath: remoteDir.appendingPathComponent("learned.json").path)
            let seedGuardOK = !remoteFileExists && base.corrections.isEmpty
            if !seedGuardOK { passed = false }
            print("\(seedGuardOK ? "PASS" : "FAIL"): missing remote in a just-created folder defers the seed")
        }

        return passed
    }
}
