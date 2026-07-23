# iCloud Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Share learned corrections, the vocabulary dictionary and snippets between two Macs through iCloud Drive, without re-teaching anything and without one machine silently clobbering the other.

**Architecture:** Each machine keeps a local snapshot of the state it last synced. At launch, every shared store is merged three ways — base vs local vs remote — then written to local, to iCloud, and back to the base. Deletion falls out of the diff, so no tombstones and no schema changes. `SyncMerge` is pure and carries the logic; `SyncedStore` does the file plumbing.

**Tech Stack:** Swift 6.2 (language mode v5), SwiftPM, Foundation. No new dependencies.

**Spec:** `.planning/design/learning-guardrails-and-icloud-sync.md`

## Global Constraints

- **Local branch only.** This ships on `local/main` and must never reach `fix/learning-guardrails` or upstream PR #1.
- **No change to any on-disk format upstream owns.** `learned.json` and `snippets.json` keep their exact current shapes. `vocabulary.json` is the fork's own format (`[VocabularyEntry]`) and also keeps its shape. The only new file is `sync-base.json`, which is ours.
- Sync covers `learned.json`, `vocabulary.json`, `snippets.json`. **Not** the legacy `dictionary.json` (a frozen one-time migration source superseded by `vocabulary.json` on 2026-07-23), **not** `history.json`, **not** `scratchpad.txt`, **not** `whisper-models/`.
- Local vocabulary is read via `VocabularyStore.load()` (never a raw file decode) so its one-time migration lock and corrupt-file preservation (`vocabulary.json.corrupt`) keep working. Concurrent `load()` from the background sync and the main thread is already safe by construction: the first-run migration is double-checked under an `NSLock`, and all store writes are atomic replaces, so a torn read is impossible. The vocabulary merge keys on the (word, misheard) content pair — `word.lowercased() + "\u{0}" + (misheard ?? "").lowercased()` — NOT the entry `UUID`, because both machines mint different UUIDs for the same logical entry.
- `LearnedStore.runSelfTest()` is now `async` (awaited in `Main.swift`); the new `SyncMerge.runSelfTest()` stays synchronous and is called alongside it.
- No new third-party dependencies.
- Tests extend the repo's existing `runSelfTest() -> Bool` convention wired to `--selftest`.
- The base snapshot is local-only and never written to iCloud — it records what *this machine* last saw.
- iCloud Drive absent, logged out, or a file not yet downloaded must degrade to local-only, silently. **Never treat a not-yet-downloaded file as empty** — that would merge to empty and write the emptiness back over both copies.
- Build and test with: `swift build -c release && ./.build/release/Murmur --selftest`
- Baseline before this plan: **88 PASS / 0 FAIL** (guardrails + mic selector + vocabulary features). The four `LearnedStore` `diff(...)` invariants must stay green throughout.

## File Structure

| File | Responsibility |
|---|---|
| `Sources/Murmur/SyncMerge.swift` (create) | Pure three-way merge over keyed collections, plus term union. No I/O. |
| `Sources/Murmur/SyncedStore.swift` (create) | `SyncBase` model, iCloud file plumbing, `syncAll()`. |
| `Sources/Murmur/AppPaths.swift` (modify) | `syncedDirectory`, `syncBaseURL`, eviction-aware read helper. |
| `Sources/Murmur/Main.swift:105-110` (modify) | Call `SyncedStore.syncAll()` once at launch. |

`LearnedStore.swift` is already ~1000 lines; none of this goes in it.

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
            let learnedPassed = await LearnedStore.runSelfTest()
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
Expected: 91 PASS, 0 FAIL, exit 0 (88 baseline + 3 new). The four `diff(...)` invariants still PASS.

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
Expected: 102 PASS, 0 FAIL, exit 0 (91 + 10 merge cases + 1 terms case). The four `diff(...)` invariants still PASS.

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
    var vocabulary: [String: VocabularyEntry] = [:]
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

    private static func keyed(
        _ corrections: [LearnedCorrection]) -> [String: LearnedCorrection] {
        Dictionary(corrections.map { (key(for: $0), $0) },
                   uniquingKeysWith: { first, _ in first })
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

        // Read the REMOTE first. A coordinated read can block on the iCloud
        // daemon for a long time, and anything the user teaches during that
        // window must join the merge rather than be overwritten by a snapshot
        // taken before the wait.
        //
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
            let seed = LearnedStore.load()
            log.info("learned.json absent remotely; seeding from local")
            guard write(seed, to: remoteURL) else { return }
            base.corrections = keyed(seed.corrections)
            base.terms = seed.terms
            return
        case .ready(let data):
            remoteData = data
        }
        guard let remote = try? JSONDecoder().decode(LearnedData.self, from: remoteData)
        else {
            log.error("remote learned.json is unreadable; keeping local untouched")
            return
        }

        // Blocking read is behind us: snapshot local now, so a correction the
        // user taught while we waited is merged instead of destroyed.
        let local = LearnedStore.load()
        let localCorrections = keyed(local.corrections)
        let remoteCorrections = keyed(remote.corrections)

        let mergedCorrections = SyncMerge.merge(
            base: base.corrections, local: localCorrections,
            remote: remoteCorrections, resolve: resolve)
        let mergedTerms = SyncMerge.mergeTerms(
            base: base.terms, local: local.terms, remote: remote.terms)

        // Refuse a wipe caused by DAMAGE, but allow a real "delete everything".
        if mergedCorrections.isEmpty, !base.corrections.isEmpty,
           !localIsIntact(LearnedStore.fileURL, as: LearnedData.self) {
            log.error("""
                learned.json is missing or unreadable and the merge would empty \
                the store; aborting so the iCloud copy survives.
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
        guard write(merged, to: remoteURL) else {
            log.error("remote write failed; base left untouched so the next launch retries")
            return
        }
        base.corrections = mergedCorrections
        base.terms = mergedTerms
    }

    /// Whether a local store file is present and decodes cleanly.
    ///
    /// The stores all return an empty value both when the user really deleted
    /// everything and when the file was removed in Finder or corrupted. Those
    /// are indistinguishable from the loaded value alone, so ask the file.
    /// An intentional "delete everything" leaves a present, well-formed file and
    /// must still propagate - only damage is refused.
    private static func localIsIntact<T: Decodable>(_ url: URL, as type: T.Type) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        return (try? JSONDecoder().decode(type, from: data)) != nil
    }

    /// Encodes and writes through `AppPaths.writeShared`, which coordinates
    /// with the iCloud daemon.
    ///
    /// - Returns: whether the write landed. Callers MUST NOT advance the base
    ///   snapshot on a false return: a base ahead of the remote makes the next
    ///   merge read the stale remote as a set of deletions and delete this
    ///   Mac's data.
    /// Writes a LOCAL file the way the rest of the app does - a plain atomic
    /// write, no coordination. Mixing coordinated and uncoordinated writes on

    /// Writes a file inside the iCloud folder, coordinated with the daemon.
    @discardableResult
    private static func write<T: Encodable>(_ value: T, to url: URL) -> Bool {
        guard let encoded = try? JSONEncoder().encode(value) else { return false }
        guard AppPaths.writeShared(encoded, to: url) else {
            log.error("failed writing \(url.path, privacy: .public)")
            return false
        }
        return true
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
Expected: 105 PASS, 0 FAIL, exit 0 (102 + 3 Task 3 cases). The four `diff(...)` invariants still PASS.

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

### Task 4: Sync the vocabulary and snippets

**Files:**
- Modify: `Sources/Murmur/SyncedStore.swift`

**Interfaces:**
- Consumes: `VocabularyStore.load()`, `VocabularyStore.save(_:)`, `VocabularyStore.fileURL`, `VocabularyEntry`, `SnippetStore.load()`, `SnippetStore.save(_:)`
- Produces: `SyncedStore.syncAll()` also covering `vocabulary.json` and `snippets.json`; `SyncedStore.key(for: VocabularyEntry)`

- [ ] **Step 1: Write the failing test**

Add to `SyncMerge.runSelfTest()`, before `return passed`:

```swift
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift build -c release 2>&1 | tail -5`
Expected: FAIL to compile — `no exact matches in call to static method 'key'` (neither the `Snippet` nor the `VocabularyEntry` overload exists yet).

- [ ] **Step 3: Write the implementation**

Add the vocabulary key overload to `SyncedStore` (beside the existing `key(for:)` overloads):

```swift
    /// Content key for a vocabulary entry: the case-insensitive (word, misheard)
    /// pair — the same identity `VocabularyStore.migrate` dedups by. NEVER the
    /// UUID: each machine mints its own ids for the same logical entry.
    static func key(for entry: VocabularyEntry) -> String {
        entry.word.lowercased() + "\u{0}"
            + (entry.misheard ?? "").lowercased()
    }
```

Add to `SyncedStore`, and call both from `syncAll` after `syncLearned`:

```swift
    private static func syncVocabulary(in remoteDirectory: URL, base: inout SyncBase) {
        let remoteURL = remoteDirectory.appendingPathComponent("vocabulary.json")
        // Read the REMOTE first: the coordinated iCloud read can block, and a
        // local snapshot taken before it would overwrite anything the user
        // adds meanwhile (same race Task 3 fixed in syncLearned). Snapshot
        // local only after the blocking read returns.
        let remoteData: Data?
        switch AppPaths.readShared(remoteURL) {
        case .notDownloaded:
            log.info("vocabulary.json not downloaded yet; skipping this cycle")
            return
        case .missing:
            remoteData = nil
        case .ready(let data):
            remoteData = data
        }
        // Local snapshot AFTER the blocking remote read. Through
        // VocabularyStore.load(), never a raw decode: it owns the one-time
        // legacy migration (locked) and corrupt-file preservation.
        let localEntries = Dictionary(
            VocabularyStore.load().map { (key(for: $0), $0) },
            uniquingKeysWith: { first, _ in first })
        guard let remoteData else {
            // Seed sorted, matching what every subsequent merge writes.
            let seed = localEntries.values.sorted { $0.word.lowercased() < $1.word.lowercased() }
            guard write(seed, to: remoteURL) else { return }
            base.vocabulary = localEntries
            return
        }
        guard let remoteList = try? JSONDecoder()
            .decode([VocabularyEntry].self, from: remoteData) else {
            log.error("remote vocabulary.json is unreadable; keeping local untouched")
            return
        }
        let remoteEntries = Dictionary(
            remoteList.map { (key(for: $0), $0) }, uniquingKeysWith: { first, _ in first })
        let merged = SyncMerge.merge(
            base: base.vocabulary, local: localEntries,
            remote: remoteEntries) { localValue, _ in localValue }
        if merged.isEmpty, !base.vocabulary.isEmpty,
           !localIsIntact(VocabularyStore.fileURL, as: [VocabularyEntry].self) {
            log.error("vocabulary.json is missing or unreadable; aborting to protect iCloud")
            return
        }
        let ordered = merged.values.sorted { $0.word.lowercased() < $1.word.lowercased() }
        log.info("vocabulary.json merged: \(ordered.count) entries")
        VocabularyStore.save(ordered)
        guard write(ordered, to: remoteURL) else { return }
        base.vocabulary = merged
    }

    private static func syncSnippets(in remoteDirectory: URL, base: inout SyncBase) {
        let remoteURL = remoteDirectory.appendingPathComponent("snippets.json")
        // Remote first, local snapshot after — same race fix as syncLearned
        // and syncVocabulary: the coordinated read can block, and a pre-read
        // local snapshot would overwrite a snippet added meanwhile.
        let remoteData: Data?
        switch AppPaths.readShared(remoteURL) {
        case .notDownloaded:
            log.info("snippets.json not downloaded yet; skipping this cycle")
            return
        case .missing:
            remoteData = nil
        case .ready(let data):
            remoteData = data
        }
        let localSnippets = Dictionary(
            SnippetStore.load().map { (key(for: $0), $0) },
            uniquingKeysWith: { first, _ in first })
        guard let remoteData else {
            // Seed sorted, matching what every subsequent merge writes.
            let seed = localSnippets.values.sorted { $0.trigger < $1.trigger }
            guard write(seed, to: remoteURL) else { return }
            base.snippets = localSnippets
            return
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
        if merged.isEmpty, !base.snippets.isEmpty,
           !localIsIntact(SnippetStore.fileURL, as: [Snippet].self) {
            log.error("snippets.json is missing or unreadable; aborting to protect iCloud")
            return
        }
        let ordered = merged.values.sorted { $0.trigger < $1.trigger }
        log.info("snippets.json merged: \(ordered.count) snippets")
        SnippetStore.save(ordered)
        guard write(ordered, to: remoteURL) else { return }
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
        syncVocabulary(in: remoteDirectory, base: &base)
        syncSnippets(in: remoteDirectory, base: &base)
        saveBase(base)
    }
```

All three stores now route their remote I/O through `AppPaths.readShared` and
`AppPaths.writeShared`.

- [ ] **Step 4: Run to verify it passes**

Run: `swift build -c release && ./.build/release/Murmur --selftest`
Expected: 107 PASS, 0 FAIL, exit 0 (105 + 2 Task 4 cases). The four `diff(...)` invariants still PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Murmur/SyncedStore.swift
git commit -m "Sync the vocabulary and snippets too"
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
Expected: local hash unchanged; `learned.json`, `vocabulary.json`, `snippets.json` now present in iCloud (NO `dictionary.json` — the legacy file is not synced); `sync-base.json` created locally in Application Support.

- [ ] **Step 3: Simulate the second machine**

Move the local store aside so the app looks like a fresh Mac with an existing iCloud folder, then launch:

```bash
cd ~/Library/Application\ Support/Murmur
mv learned.json learned.json.machine-a
mv vocabulary.json vocabulary.json.machine-a
mv dictionary.json dictionary.json.machine-a 2>/dev/null || true   # legacy migration source: hide it too, or load() re-migrates it
mv snippets.json snippets.json.machine-a 2>/dev/null || true
mv sync-base.json sync-base.json.machine-a
open /Users/konrad/projects/murmur/build/Murmur.app
sleep 5
python3 -c "import json;d=json.load(open('learned.json'));print(len(d['corrections']),'corrections,',len(d['terms']),'terms')"
```
Expected: the store is repopulated from iCloud — corrections in learned.json AND the vocabulary entries (X2D II, Phocus) in vocabulary.json. This is the "don't re-teach the laptop" case working. Also verify no duplicate vocabulary entries appeared (the content-pair key must unify the two machines' different UUIDs).

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
| `learned.json`, `vocabulary.json`, `snippets.json` shared; legacy dictionary.json, history and scratchpad excluded | 3, 4 |
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
| **Medium: a locally deleted or corrupt store looks like an intentional wipe and would empty iCloud too** | Adopted, and this is the finding I am happiest to have. `LearnedStore.load()` returns empty both when the user deleted everything and when the file was removed in Finder or failed to decode. Superseded in round 3 by a `localIsIntact` check that asks the *file* rather than the loaded value, so an intentional "delete everything" still propagates. |
| Medium: `.atomic` inside a `.forReplacing` coordination block writes to a path the coordinator did not lock | Adopted. `writeShared` drops `.atomic`; the coordinator provides replacement semantics itself. |
| Medium: an unentitled CloudDocs path gets no guaranteed sync priority from `bird` | Accepted and documented. A ubiquity container needs a paid signing identity, which is the constraint that shaped this whole design. |
| Low: `SyncBase` duplicates all three stores on disk | Accepted. Single-digit KB today. |
| Low: an upstream non-optional field added to `LearnedCorrection`/`Snippet` breaks base decoding | Accepted — it degrades to a union, which cannot delete anything. |
| Low: a casing-only trigger edit may be reverted | Accepted. Case-insensitive keying is what keeps the merge consistent with `LearnedStore.merging`. |

**Review findings addressed (Gemini, round 3 — 0 Blocker, 2 High, 2 Medium, 1 Low):**

| Finding | Resolution |
|---|---|
| **High: a failed iCloud write still advanced the base, so the next merge would read the stale remote as deletions and delete local data** | Adopted. `write(_:to:)` now returns `Bool`, and every base assignment — including both seeding paths — is gated on a successful remote write. This was the same shape as the round-1 High: the sync destroying the data it exists to protect. |
| **High: the wipe guard made it impossible to intentionally delete the last correction or snippet** | Adopted. My guard compared loaded values, which cannot distinguish damage from intent. Replaced with `localIsIntact`, which asks whether the file is present and decodes — a real "delete everything" leaves a well-formed empty file and now propagates, while a missing or corrupt one is refused. |
| Medium: background `syncAll` writes local stores while the UI may read them | Verified rather than changed: `LearnedStore.save`, `SnippetStore.save` and the dictionary write at `MainView.swift:916` all already use `.write(to:options:.atomic)`, so replacement is atomic and a torn read is not possible. Worst case is reading the pre-merge file. |
| Medium: `readShared` reports a genuine read error as `.notDownloaded` | Accepted. The safe default is the right one, and the caller already logs a `warning` naming the skipped store, which is enough to diagnose. Adding a logger to `AppPaths` for this alone is not worth the surface. |
| Low: base duplication, upstream schema drift, casing-only edits | Unchanged from round 2 — all degrade safely. |

**Review findings addressed (Gemini, round 4 — 0 Blocker, 2 High, 2 Medium, 2 Low):**

| Finding | Resolution |
|---|---|
| **High: background sync races the UI — a correction taught while the coordinated iCloud read blocks would be overwritten by the pre-read snapshot** | Adopted. This was introduced by round 3's own fix (moving sync off the main thread), which is worth noting: each structural change here has created a new hazard. `syncLearned` now reads the remote first and snapshots local only after the blocking read returns, shrinking the window to the merge-and-write itself. |
| **High: coordinated writes to a LOCAL file mixed with the app's uncoordinated writes can deadlock** | Adopted, later simplified: after the 2026-07-23 vocabulary reconciliation every local write goes through the store's own plain-atomic `save()` (`LearnedStore.save`, `VocabularyStore.save`, `SnippetStore.save`), so the interim `writeLocal` helper became dead code and was removed. `write` remains reserved strictly for paths inside the iCloud folder. |
| Medium: an unsandboxed app touching CloudDocs triggers a TCC prompt, and a denial fails silently forever | Noted for Task 5 verification — the first launch after this ships will prompt, and a denial surfaces as a permanent `.notDownloaded`. The `warning` log names the store, which is the diagnosis path. |
| Medium: `mergeTerms` truncation favours remote terms over older local ones | Accepted. No timestamp exists to sort by, and the 300 cap plus `removeFirst` matches `LearnedStore.appendTerm`. |
| Low: the iCloud folder is visible in Finder and renaming it silently starts a fresh sync | Accepted and worth telling the user once. Not hidden with a dot prefix, because a visible folder is also how you notice sync is working. |
| Low: a 0-byte store file reads as corrupt and halts propagation | Accepted. `localIsIntact` treats it as damage, which is the safe direction. |

**Known gaps, deliberate:**
- Sync runs at launch only. A machine left running for days will not see the other's changes until relaunch. Accepted in the spec; a file watcher is the escape hatch.
- `syncAll` does synchronous disk I/O at launch. The files are small (single-digit KB), and the Gemini panel's main-thread objection to `LearnedStore` applies here too — accepted on a local branch, unlike in the upstream PR.
- Task 5 simulates the second machine by moving files rather than using the actual laptop. Real cross-machine verification needs the laptop awake and is the one step that cannot be automated from here.
