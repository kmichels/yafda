# iCloud Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Share learned corrections, vocabulary, the personal dictionary and snippets between two Macs through iCloud Drive, without re-teaching anything and without one machine silently clobbering the other.

**Architecture:** Each machine keeps a local snapshot of the state it last synced. At launch, every shared store is merged three ways — base vs local vs remote — then written to local, to iCloud, and back to the base. Deletion falls out of the diff, so no tombstones and no schema changes. `SyncMerge` is pure and carries the logic; `SyncedStore` does the file plumbing.

**Tech Stack:** Swift 6.2 (language mode v5), SwiftPM, Foundation. No new dependencies.

**Spec:** `.planning/design/learning-guardrails-and-icloud-sync.md`

## Global Constraints

- **Local branch only.** This ships on `local/main` and must never reach `fix/learning-guardrails` or upstream PR #1.
- **No change to any on-disk format upstream owns.** `learned.json`, `dictionary.json`, `snippets.json` keep their exact current shapes. The only new file is `sync-base.json`, which is ours.
- Sync covers `learned.json`, `dictionary.json`, `snippets.json`. **Not** `history.json`, **not** `scratchpad.txt`, **not** `whisper-models/`.
- No new third-party dependencies.
- Tests extend the repo's existing `runSelfTest() -> Bool` convention wired to `--selftest`.
- The base snapshot is local-only and never written to iCloud — it records what *this machine* last saw.
- iCloud Drive absent, logged out, or a file not yet downloaded must degrade to local-only, silently. **Never treat a not-yet-downloaded file as empty** — that would merge to empty and write the emptiness back over both copies.
- Build and test with: `swift build -c release && ./.build/release/Murmur --selftest`
- Baseline before this plan: **57 PASS / 0 FAIL**. The four `LearnedStore` `diff(...)` invariants must stay green throughout.

## File Structure

| File | Responsibility |
|---|---|
| `Sources/Murmur/SyncMerge.swift` (create) | Pure three-way merge over keyed collections, plus term union. No I/O. |
| `Sources/Murmur/SyncedStore.swift` (create) | `SyncBase` model, iCloud file plumbing, `syncAll()`. |
| `Sources/Murmur/AppPaths.swift` (modify) | `syncedDirectory`, `syncBaseURL`, eviction-aware read helper. |
| `Sources/Murmur/Main.swift:105-110` (modify) | Call `SyncedStore.syncAll()` once at launch. |

`LearnedStore.swift` is already 784 lines; none of this goes in it.

---

### Task 1: iCloud paths and eviction-aware reads

**Files:**
- Modify: `Sources/Murmur/AppPaths.swift`

**Interfaces:**
- Produces: `AppPaths.syncedDirectory: URL?`, `AppPaths.syncBaseURL: URL`, `AppPaths.RemoteFile`, `AppPaths.readShared(_:) -> RemoteFile`, `AppPaths.writeShared(_:to:) -> Bool`

- [ ] **Step 1: Write the failing test**

Create `Sources/Murmur/SyncMerge.swift` with only a self-test stub for now, so `--selftest` has somewhere to call:

```swift
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

        return passed
    }
}
```

Wire it into `Main.swift`, replacing the two-line selftest body at `Main.swift:42-45`:

```swift
        case .selftest:
            let formatterPassed = TextFormatter.runSelfTest()
            let learnedPassed = LearnedStore.runSelfTest()
            let syncPassed = SyncMerge.runSelfTest()
            exit(formatterPassed && learnedPassed && syncPassed ? 0 : 1)
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift build -c release 2>&1 | tail -5`
Expected: FAIL to compile — `type 'AppPaths' has no member 'syncedDirectory'`

- [ ] **Step 3: Write the implementation**

Add to `AppPaths.swift`, inside `enum AppPaths`:

```swift
    /// Folder shared between this user's Macs, or nil when iCloud Drive is
    /// unavailable.
    ///
    /// A plain path under CloudDocs works because Murmur is unsandboxed and
    /// carries no entitlements; a real ubiquity container would require a paid
    /// signing identity.
    static var syncedDirectory: URL? {
        let cloud = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs",
                                    isDirectory: true)
        guard FileManager.default.fileExists(atPath: cloud.path) else { return nil }
        let directory = cloud.appendingPathComponent("Murmur", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        return directory
    }

    /// Snapshot of the state this machine last synced. Deliberately local: it
    /// records what *this* Mac saw, so it must not travel with the shared files.
    static var syncBaseURL: URL {
        supportDirectory.appendingPathComponent("sync-base.json")
    }

    /// Whether a shared file can be read right now.
    ///
    /// `.notDownloaded` is deliberately distinct from `.missing`. A file iCloud
    /// has evicted still exists on the other Mac, so seeding it from local data
    /// would destroy that machine's changes. Only `.missing` is safe to
    /// overwrite. Collapsing these two into one "nil" is the single most
    /// destructive mistake available in this design.
    enum RemoteFile {
        case ready(Data)
        case missing
        case notDownloaded
    }

    /// Reads a shared file, asking iCloud to materialise it first if it has
    /// been evicted to a placeholder.
    static func readShared(_ url: URL) -> RemoteFile {
        let manager = FileManager.default
        // iCloud replaces an evicted file with ".<name>.icloud".
        let placeholder = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).icloud")
        if manager.fileExists(atPath: placeholder.path) {
            try? manager.startDownloadingUbiquitousItem(at: url)
            return .notDownloaded
        }
        guard manager.fileExists(atPath: url.path) else { return .missing }

        var coordinationError: NSError?
        // Default to .notDownloaded so a failed read skips the cycle rather
        // than looking like an empty remote.
        var result: RemoteFile = .notDownloaded
        NSFileCoordinator().coordinate(
            readingItemAt: url, options: [], error: &coordinationError) { readURL in
            if let data = try? Data(contentsOf: readURL) {
                result = .ready(data)
            }
        }
        return result
    }

    /// Atomically writes a shared file, coordinating with the iCloud daemon so
    /// the write does not collide with `bird` syncing the same path.
    @discardableResult
    static func writeShared(_ data: Data, to url: URL) -> Bool {
        var coordinationError: NSError?
        var wrote = false
        NSFileCoordinator().coordinate(
            writingItemAt: url, options: .forReplacing,
            error: &coordinationError) { writeURL in
            // No .atomic here: the coordinator already provides safe
            // replacement, and a temp-file-plus-rename writes to a path the
            // coordinator did not lock.
            wrote = (try? data.write(to: writeURL)) != nil
        }
        return wrote && coordinationError == nil
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift build -c release && ./.build/release/Murmur --selftest`
Expected: 60 PASS, 0 FAIL, exit 0 (57 baseline + 3 new). The four `diff(...)` invariants still PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Murmur/AppPaths.swift Sources/Murmur/SyncMerge.swift Sources/Murmur/Main.swift
git commit -m "Add iCloud sync paths with eviction-aware reads"
```

---

### Task 2: The three-way merge

**Files:**
- Modify: `Sources/Murmur/SyncMerge.swift`

**Interfaces:**
- Produces: `SyncMerge.merge(base:local:remote:resolve:) -> [String: Value]`, `SyncMerge.mergeTerms(base:local:remote:) -> [String]`

- [ ] **Step 1: Write the failing test**

Add to `SyncMerge.runSelfTest()`, before `return passed`:

```swift
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
            ("re-added after delete survives",
             merged(["a": "1"], ["a": "2"], [:]), ["a": "2"]),
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift build -c release 2>&1 | tail -5`
Expected: FAIL to compile — `type 'SyncMerge' has no member 'merge'`

- [ ] **Step 3: Write the implementation**

Add to `SyncMerge`, above the self test:

```swift
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
```

`base` is unused by `mergeTerms` and that is deliberate — keep the parameter so the call sites read uniformly, and the doc comment explains why it is ignored.

- [ ] **Step 4: Run to verify it passes**

Run: `swift build -c release && ./.build/release/Murmur --selftest`
Expected: 71 PASS, 0 FAIL, exit 0 (60 + 10 merge cases + 1 terms case). The four `diff(...)` invariants still PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Murmur/SyncMerge.swift
git commit -m "Add three-way merge so deletions need no tombstones"
```

---

### Task 3: Sync learned.json

**Files:**
- Create: `Sources/Murmur/SyncedStore.swift`
- Modify: `Sources/Murmur/Main.swift:105-110`

**Interfaces:**
- Consumes: `SyncMerge.merge`, `SyncMerge.mergeTerms`, `AppPaths.syncedDirectory`, `AppPaths.readShared`, `AppPaths.writeShared`, `LearnedStore.load()`, `LearnedStore.save(_:)`
- Produces: `struct SyncBase: Codable, Equatable`, `SyncedStore.syncAll()`, `SyncedStore.loadBase()`, `SyncedStore.saveBase(_:)`

- [ ] **Step 1: Write the failing test**

Add to `SyncMerge.runSelfTest()`, before `return passed`:

```swift
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift build -c release 2>&1 | tail -5`
Expected: FAIL to compile — `cannot find 'SyncedStore' in scope`

- [ ] **Step 3: Write the implementation**

Create `Sources/Murmur/SyncedStore.swift`:

```swift
import Foundation
import os

/// State this machine saw at its last successful sync, keyed per store.
///
/// Nothing upstream owns changes shape; this snapshot is what makes deletion
/// detectable, so no tombstones are needed anywhere.
struct SyncBase: Codable, Equatable {
    var corrections: [String: LearnedCorrection] = [:]
    var terms: [String] = []
    var dictionary: [String: String] = [:]
    var snippets: [String: Snippet] = [:]
}

/// Shares learned data between this user's Macs through iCloud Drive.
///
/// Runs once at launch. Single-user, never-concurrent use is assumed, but the
/// merge is order-independent so simultaneous use degrades to a conflict on
/// individual entries rather than a lost file.
enum SyncedStore {
    private static let log = Logger(subsystem: "local.murmur", category: "sync")

    // MARK: - Keying

    /// Corrections key on the misheard phrase alone, matching
    /// `LearnedStore.merging`, which already allows only one rule per phrase.
    static func key(for correction: LearnedCorrection) -> String {
        correction.heard.lowercased()
    }

    static func key(for snippet: Snippet) -> String {
        snippet.trigger.lowercased()
    }

    /// The more-confirmed correction wins; ties keep the local one.
    static func resolve(_ local: LearnedCorrection,
                        _ remote: LearnedCorrection) -> LearnedCorrection {
        remote.timesSeen > local.timesSeen ? remote : local
    }

    // MARK: - Base snapshot

    /// - Note: a missing or corrupt base returns an empty snapshot, which makes
    ///   the next merge a plain union. That errs toward keeping data: it can
    ///   resurrect entries deleted since the last sync, but it can never delete
    ///   anything. Resurrection is recoverable with the delete button; deletion
    ///   is not recoverable at all.
    static func loadBase() -> SyncBase {
        guard let data = try? Data(contentsOf: AppPaths.syncBaseURL),
              let base = try? JSONDecoder().decode(SyncBase.self, from: data)
        else { return SyncBase() }
        return base
    }

    static func saveBase(_ base: SyncBase) {
        guard let data = try? JSONEncoder().encode(base) else { return }
        try? data.write(to: AppPaths.syncBaseURL, options: .atomic)
    }

    // MARK: - Sync

    /// Merges every shared store with its iCloud copy. Silently does nothing
    /// when iCloud Drive is unavailable.
    static func syncAll() {
        guard let remoteDirectory = AppPaths.syncedDirectory else {
            log.info("iCloud Drive unavailable; running local-only")
            return
        }
        var base = loadBase()
        syncLearned(in: remoteDirectory, base: &base)
        saveBase(base)
    }

    private static func syncLearned(in remoteDirectory: URL, base: inout SyncBase) {
        let remoteURL = remoteDirectory.appendingPathComponent("learned.json")
        let local = LearnedStore.load()
        let localCorrections = Dictionary(
            local.corrections.map { (key(for: $0), $0) },
            uniquingKeysWith: { first, _ in first })

        // The three remote states are NOT interchangeable. Seeding on
        // .notDownloaded would overwrite a file that exists on the other Mac.
        let remoteData: Data
        switch AppPaths.readShared(remoteURL) {
        case .notDownloaded:
            log.warning("""
                learned.json is in iCloud but not downloaded yet; skipping so the \
                other Mac's copy is not overwritten. Local changes stay local \
                until it materialises.
                """)
            return
        case .missing:
            log.info("learned.json absent remotely; seeding from local")
            write(local, to: remoteURL)
            base.corrections = localCorrections
            base.terms = local.terms
            return
        case .ready(let data):
            remoteData = data
        }
        guard let remote = try? JSONDecoder().decode(LearnedData.self, from: remoteData)
        else {
            log.error("remote learned.json is unreadable; keeping local untouched")
            return
        }
        let remoteCorrections = Dictionary(
            remote.corrections.map { (key(for: $0), $0) },
            uniquingKeysWith: { first, _ in first })

        let mergedCorrections = SyncMerge.merge(
            base: base.corrections, local: localCorrections,
            remote: remoteCorrections, resolve: resolve)
        let mergedTerms = SyncMerge.mergeTerms(
            base: base.terms, local: local.terms, remote: remote.terms)

        guard !isTotalWipe(base: base.corrections, merged: mergedCorrections) else {
            log.error("""
                merge would delete every correction; aborting so the iCloud copy \
                survives. learned.json was probably removed or corrupted locally.
                """)
            return
        }

        var merged = LearnedData()
        merged.corrections = mergedCorrections.values.sorted { $0.heard < $1.heard }
        merged.terms = mergedTerms

        log.info("""
            learned.json merged: \(localCorrections.count) local, \
            \(remoteCorrections.count) remote, \(merged.corrections.count) merged
            """)

        LearnedStore.save(merged)
        write(merged, to: remoteURL)
        base.corrections = mergedCorrections
        base.terms = mergedTerms
    }

    /// Whether a merge would empty a store that was not empty before.
    ///
    /// `LearnedStore.load()` returns an empty store both when the user really
    /// deleted everything and when `learned.json` was removed in Finder or
    /// failed to decode. Those are indistinguishable, and the second is far more
    /// likely - so refuse to propagate a total wipe rather than mirroring the
    /// damage onto the other Mac.
    private static func isTotalWipe<Value>(base: [String: Value],
                                           merged: [String: Value]) -> Bool {
        !base.isEmpty && merged.isEmpty
    }

    /// Encodes and writes through `AppPaths.writeShared`, which coordinates
    /// with the iCloud daemon. A failed write is logged and the base is still
    /// advanced only by the caller, so the next launch retries.
    private static func write<T: Encodable>(_ value: T, to url: URL) {
        guard let encoded = try? JSONEncoder().encode(value) else { return }
        if !AppPaths.writeShared(encoded, to: url) {
            log.error("failed writing \(url.path, privacy: .public)")
        }
    }
}
```

No transcript, correction or vocabulary text is ever logged — only counts and paths.

Then in `Main.swift`, change the `.app` case (currently `Main.swift:105-110`) to sync before the delegate reads anything:

```swift
        case .app:
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let delegate = AppDelegate()
            app.delegate = delegate
            // Merge with the other Mac off the main thread. A coordinated read
            // can block on the iCloud daemon, and a hang before `run()` would
            // leave Murmur bouncing in the Dock with no UI at all.
            DispatchQueue.global(qos: .userInitiated).async {
                SyncedStore.syncAll()
            }
            app.run()
```

Dictation reads the store fresh on every transcript (`LearnedStore.load()` inside
`apply(in:)`), so merged corrections take effect as soon as the sync finishes — which is
well before the user can hold the hotkey and speak. The only staleness window is the
dashboard, if it is opened within the first moment of launch; reopening it re-reads.

Reads and writes race only at whole-file granularity, and both sides write atomically,
so the worst case is a read of the pre-merge file, never a torn one.

- [ ] **Step 4: Run to verify it passes**

Run: `swift build -c release && ./.build/release/Murmur --selftest`
Expected: 74 PASS, 0 FAIL, exit 0. The four `diff(...)` invariants still PASS.

Then confirm the real store is untouched by a sync when nothing has changed:

```bash
shasum ~/Library/Application\ Support/Murmur/learned.json
./.build/release/Murmur --selftest >/dev/null
shasum ~/Library/Application\ Support/Murmur/learned.json
```
Expected: identical hashes — `--selftest` must not mutate user data.

- [ ] **Step 5: Commit**

```bash
git add Sources/Murmur/SyncedStore.swift Sources/Murmur/Main.swift
git commit -m "Sync learned corrections through iCloud Drive"
```

---

### Task 4: Sync the dictionary and snippets

**Files:**
- Modify: `Sources/Murmur/SyncedStore.swift`

**Interfaces:**
- Consumes: `TextFormatter.dictionaryURL`, `TextFormatter.loadDictionary()`, `SnippetStore.load()`, `SnippetStore.save(_:)`
- Produces: `SyncedStore.syncAll()` also covering `dictionary.json` and `snippets.json`

- [ ] **Step 1: Write the failing test**

Add to `SyncMerge.runSelfTest()`, before `return passed`:

```swift
        // MARK: Snippet keying
        let snippetA = Snippet(trigger: "Sig Block", expansion: "Konrad")
        let snippetB = Snippet(trigger: "sig block", expansion: "Konrad M")
        let snippetKeyOK = SyncedStore.key(for: snippetA) == SyncedStore.key(for: snippetB)
        if !snippetKeyOK { passed = false }
        print("\(snippetKeyOK ? "PASS" : "FAIL"): snippet key ignores trigger case")

        // A dictionary entry deleted here must not return from the other Mac.
        let dictionaryMerged = SyncMerge.merge(
            base: ["X2D2": "X2D II", "stale": "gone"],
            local: ["X2D2": "X2D II"],
            remote: ["X2D2": "X2D II", "stale": "gone"]) { l, _ in l }
        let dictionaryOK = dictionaryMerged == ["X2D2": "X2D II"]
        if !dictionaryOK { passed = false }
        print("\(dictionaryOK ? "PASS" : "FAIL"): deleted dictionary entry stays " +
              "deleted = \(dictionaryMerged)")
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift build -c release 2>&1 | tail -5`
Expected: FAIL to compile — `incorrect argument label` or `no exact matches in call to static method 'key'` (the `Snippet` overload does not exist yet if Task 3 omitted it; if it compiles, the test still fails on the dictionary case)

- [ ] **Step 3: Write the implementation**

Add to `SyncedStore`, and call both from `syncAll` after `syncLearned`:

```swift
    private static func syncDictionary(in remoteDirectory: URL, base: inout SyncBase) {
        let remoteURL = remoteDirectory.appendingPathComponent("dictionary.json")
        let local = TextFormatter.loadDictionary()
        let remoteData: Data
        switch AppPaths.readShared(remoteURL) {
        case .notDownloaded:
            log.info("dictionary.json not downloaded yet; skipping this cycle")
            return
        case .missing:
            write(local, to: remoteURL)
            base.dictionary = local
            return
        case .ready(let data):
            remoteData = data
        }
        guard let remote = try? JSONDecoder()
            .decode([String: String].self, from: remoteData) else {
            log.error("remote dictionary.json is unreadable; keeping local untouched")
            return
        }
        let merged = SyncMerge.merge(
            base: base.dictionary, local: local, remote: remote) { localValue, _ in
                localValue
            }
        guard !isTotalWipe(base: base.dictionary, merged: merged) else {
            log.error("merge would empty dictionary.json; aborting to protect iCloud")
            return
        }
        log.info("dictionary.json merged: \(merged.count) entries")
        write(merged, to: TextFormatter.dictionaryURL)
        write(merged, to: remoteURL)
        base.dictionary = merged
    }

    private static func syncSnippets(in remoteDirectory: URL, base: inout SyncBase) {
        let remoteURL = remoteDirectory.appendingPathComponent("snippets.json")
        let localSnippets = Dictionary(
            SnippetStore.load().map { (key(for: $0), $0) },
            uniquingKeysWith: { first, _ in first })
        let remoteData: Data
        switch AppPaths.readShared(remoteURL) {
        case .notDownloaded:
            log.info("snippets.json not downloaded yet; skipping this cycle")
            return
        case .missing:
            write(Array(localSnippets.values), to: remoteURL)
            base.snippets = localSnippets
            return
        case .ready(let data):
            remoteData = data
        }
        guard let remoteList = try? JSONDecoder()
            .decode([Snippet].self, from: remoteData) else {
            log.error("remote snippets.json is unreadable; keeping local untouched")
            return
        }
        let remoteSnippets = Dictionary(
            remoteList.map { (key(for: $0), $0) }, uniquingKeysWith: { first, _ in first })
        let merged = SyncMerge.merge(
            base: base.snippets, local: localSnippets,
            remote: remoteSnippets) { localValue, _ in localValue }
        guard !isTotalWipe(base: base.snippets, merged: merged) else {
            log.error("merge would empty snippets.json; aborting to protect iCloud")
            return
        }
        let ordered = merged.values.sorted { $0.trigger < $1.trigger }
        log.info("snippets.json merged: \(ordered.count) snippets")
        SnippetStore.save(ordered)
        write(ordered, to: remoteURL)
        base.snippets = merged
    }

```

`write(_:to:)` already exists from Task 3 — do not redeclare it.

Replace the body of `syncAll` so all three run:

```swift
    static func syncAll() {
        guard let remoteDirectory = AppPaths.syncedDirectory else {
            log.info("iCloud Drive unavailable; running local-only")
            return
        }
        var base = loadBase()
        syncLearned(in: remoteDirectory, base: &base)
        syncDictionary(in: remoteDirectory, base: &base)
        syncSnippets(in: remoteDirectory, base: &base)
        saveBase(base)
    }
```

All three stores now route their remote I/O through `AppPaths.readShared` and
`AppPaths.writeShared`.

- [ ] **Step 4: Run to verify it passes**

Run: `swift build -c release && ./.build/release/Murmur --selftest`
Expected: 76 PASS, 0 FAIL, exit 0. The four `diff(...)` invariants still PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Murmur/SyncedStore.swift
git commit -m "Sync the personal dictionary and snippets too"
```

---

### Task 5: Prove it across two simulated machines

**Files:**
- No source changes unless verification finds a defect.

This is the task that actually answers "will my laptop get my learnings", and it must run against real files rather than the pure merge tests.

- [ ] **Step 1: Back up the real store before touching anything**

```bash
cd ~/Library/Application\ Support/Murmur
cp learned.json "learned.json.presync-$(date +%Y%m%d-%H%M%S)"
cp -R . /tmp/murmur-store-backup
ls -la learned.json*
```

- [ ] **Step 2: Confirm a first sync seeds iCloud without changing local data**

```bash
cd /Users/konrad/projects/murmur
shasum ~/Library/Application\ Support/Murmur/learned.json
./.build/release/Murmur --transcribe /dev/null 2>/dev/null; true   # cheap launch path, or run the app briefly
shasum ~/Library/Application\ Support/Murmur/learned.json
ls -la ~/Library/Mobile\ Documents/com~apple~CloudDocs/Murmur/
```
Expected: local hash unchanged; `learned.json`, `dictionary.json`, `snippets.json` now present in iCloud; `sync-base.json` created locally in Application Support.

- [ ] **Step 3: Simulate the second machine**

Move the local store aside so the app looks like a fresh Mac with an existing iCloud folder, then launch:

```bash
cd ~/Library/Application\ Support/Murmur
mv learned.json learned.json.machine-a
mv dictionary.json dictionary.json.machine-a
mv snippets.json snippets.json.machine-a 2>/dev/null || true
mv sync-base.json sync-base.json.machine-a
open /Users/konrad/projects/murmur/build/Murmur.app
sleep 5
python3 -c "import json;d=json.load(open('learned.json'));print(len(d['corrections']),'corrections,',len(d['terms']),'terms')"
```
Expected: the store is repopulated from iCloud with all 13 corrections — this is the "don't re-teach the laptop" case working.

- [ ] **Step 4: Prove a deletion does not come back**

With both machines seeded, delete a correction locally, sync, and confirm it stays gone:

```bash
cd ~/Library/Application\ Support/Murmur
python3 - <<'EOF'
import json
d=json.load(open('learned.json'))
victim=d['corrections'][0]['heard']
d['corrections']=[c for c in d['corrections'] if c['heard']!=victim]
json.dump(d,open('learned.json','w'),indent=2)
print("deleted:",victim)
EOF
open /Users/konrad/projects/murmur/build/Murmur.app; sleep 5
python3 -c "import json;print([c['heard'] for c in json.load(open('learned.json'))['corrections']])"
```
Expected: the deleted phrase is absent both locally and in the iCloud copy. If it reappears, the base snapshot is not being written — stop and investigate before going further.

- [ ] **Step 5: Restore and record**

```bash
cd ~/Library/Application\ Support/Murmur
python3 -c "import json;d=json.load(open('learned.json'));print('final:',len(d['corrections']),'corrections')"
```

If anything went wrong, `/tmp/murmur-store-backup` and the `.presync-*` copy are the recovery path. Record the outcome in `.superpowers/sdd/progress.md`.

- [ ] **Step 6: Gemini panel review**

```bash
cd /Users/konrad/projects/murmur
git diff main..HEAD -- Sources/Murmur/SyncMerge.swift Sources/Murmur/SyncedStore.swift \
    Sources/Murmur/AppPaths.swift > /tmp/murmur-sync.diff
~/.claude/tools/review panel /tmp/murmur-sync.diff
```
Read `/tmp/murmur-sync.diff.panel-review.md`. Fix findings that are ours; pre-existing upstream architecture is out of scope, as it was for PR #1.

- [ ] **Step 7: Confirm nothing leaked toward the PR branch**

```bash
git diff --name-only main..fix/learning-guardrails
```
Expected: exactly the four files of PR #1 — no `SyncMerge.swift`, no `SyncedStore.swift`, no `sync-base` anything.

---

## Self-Review

**Spec coverage:**

| Spec requirement | Task |
|---|---|
| `learned.json`, `dictionary.json`, `snippets.json` shared; history and scratchpad excluded | 3, 4 |
| Merging is non-destructive | 2 |
| A deletion on one machine is not undone by the other | 2 (test), 5 step 4 (end to end) |
| iCloud absent degrades silently to local-only | 1, 3 |
| Evicted file is never treated as empty | 1 |
| No change to any upstream-owned on-disk format | all — only `sync-base.json` is new |
| Base snapshot is local, not synced | 1 |
| Missing base degrades to a union (first-run seeding) | 2 (test), 5 step 3 |
| `os.Logger` with counts only, no user text | 3, 4 |
| Stays off the PR branch | 5 step 7 |

**Review findings addressed (Gemini, round 1 — 0 Blocker, 1 High, 3 Medium, 3 Low):**

| Finding | Resolution |
|---|---|
| **High: an evicted remote file would be overwritten with local data, destroying the other Mac's changes** | **Adopted — this was the most dangerous defect in the plan.** The original `readIfDownloaded` returned `nil` for both "missing" and "evicted", and the seed path wrote local over the remote. Replaced with a tri-state `RemoteFile { ready, missing, notDownloaded }`; `.notDownloaded` aborts that store's sync, only `.missing` seeds. A failed coordinated read also defaults to `.notDownloaded` rather than looking empty. Covered by a new self-test that plants a `.icloud` placeholder. |
| Medium: no `NSFileCoordinator`, so reads and writes can collide with the iCloud daemon | Adopted. Both `readShared` and `writeShared` now coordinate, and `writeShared` reports failure so it can be logged. |
| Medium: Task 5's second-machine simulation moved only `learned.json` | Adopted. It now also moves `dictionary.json` and `snippets.json`, so the simulated machine is genuinely clean. |
| Medium: `syncAll` runs synchronous iCloud I/O on the main thread at launch, risking a watchdog kill if the daemon hangs | Accepted with rationale, not fixed. Backgrounding it introduces a worse bug: the app would read the stores before the merge lands, and a mid-session swap of `learned.json` under a running `MainView` is a real correctness problem. Three small files behind an existence check is the lesser risk. Revisit if a launch hang is ever observed. |
| Low: `mergeTerms` truncation drops the oldest local terms first | Accepted. Matches `LearnedStore.appendTerm`, which already caps with `removeFirst`. Deviating would be the surprise. |
| Low: a corrupt base silently becomes a union, resurrecting deleted entries | Accepted and now documented on `loadBase`. It is the safe direction: resurrection is fixable with the delete button, deletion is not fixable at all. |
| Low: changing only a snippet trigger's casing may be reverted by the merge | Accepted. Case-insensitive keying is what makes the merge agree with `LearnedStore.merging`; a casing-only edit reverting is a cosmetic loss, not data loss. |

**Review findings addressed (Gemini, round 2 — 0 Blocker, 2 High, 3 Medium, 3 Low):**

| Finding | Resolution |
|---|---|
| **High: `NSFileCoordinator` on the main thread before `run()` can hang the launch entirely** | Adopted, reversing my round-1 call. Adding coordination made the hang risk real enough that a Dock-bouncing launch with no UI outweighs the staleness I was protecting against. `syncAll` now runs on a background queue after the delegate is installed. Dictation reads the store fresh per transcript, so merged data lands well before anyone can hold the hotkey; only an immediately-opened dashboard is briefly stale. |
| High: an evicted remote traps local changes until iCloud materialises the file | Adopted as far as it goes. Correct behaviour — the alternative destroys data — but it now logs a `warning` that names the situation, so "why isn't my Mac syncing" is answerable from the log. |
| **Medium: a locally deleted or corrupt store looks like an intentional wipe and would empty iCloud too** | Adopted, and this is the finding I am happiest to have. `LearnedStore.load()` returns empty both when the user deleted everything and when the file was removed in Finder or failed to decode. `isTotalWipe` now aborts any merge that would empty a previously non-empty store, for all three stores. |
| Medium: `.atomic` inside a `.forReplacing` coordination block writes to a path the coordinator did not lock | Adopted. `writeShared` drops `.atomic`; the coordinator provides replacement semantics itself. |
| Medium: an unentitled CloudDocs path gets no guaranteed sync priority from `bird` | Accepted and documented. A ubiquity container needs a paid signing identity, which is the constraint that shaped this whole design. |
| Low: `SyncBase` duplicates all three stores on disk | Accepted. Single-digit KB today. |
| Low: an upstream non-optional field added to `LearnedCorrection`/`Snippet` breaks base decoding | Accepted — it degrades to a union, which cannot delete anything. |
| Low: a casing-only trigger edit may be reverted | Accepted. Case-insensitive keying is what keeps the merge consistent with `LearnedStore.merging`. |

**Known gaps, deliberate:**
- Sync runs at launch only. A machine left running for days will not see the other's changes until relaunch. Accepted in the spec; a file watcher is the escape hatch.
- `syncAll` does synchronous disk I/O at launch. The files are small (single-digit KB), and the Gemini panel's main-thread objection to `LearnedStore` applies here too — accepted on a local branch, unlike in the upstream PR.
- Task 5 simulates the second machine by moving files rather than using the actual laptop. Real cross-machine verification needs the laptop awake and is the one step that cannot be automated from here.
