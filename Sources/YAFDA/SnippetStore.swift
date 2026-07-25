import Foundation
import os

struct Snippet: Codable, Identifiable, Equatable {
    var id = UUID()
    /// What you say during dictation.
    var trigger: String
    /// What gets inserted instead (exact casing preserved).
    var expansion: String
}

/// Voice shortcuts: saying a trigger phrase mid-dictation inserts the saved
/// text block — like Wispr Flow's Snippets.
enum SnippetStore {
    private static let log = Logger(subsystem: "local.yafda", category: "SnippetStore")

    /// Tests point this at a temp directory so self-tests (including the
    /// serialization self-test in `StoreOwner`) never touch the user's real
    /// snippets.json. nil in normal operation.
    static var directoryOverride: URL?

    static var fileURL: URL {
        (directoryOverride ?? AppPaths.supportDirectory)
            .appendingPathComponent("snippets.json")
    }

    static func load() -> [Snippet] {
        StoreOwner.sync {
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                return []   // fresh start, nothing to preserve
            }
            guard let data = try? Data(contentsOf: fileURL),
                  let snippets = try? JSONDecoder().decode([Snippet].self, from: data)
            else {
                // Same contract as LearnedStore/VocabularyStore: an
                // undecodable store must never present as fresh-and-writable
                // (release-hardening.md).
                preserveCorruptFile()
                return []
            }
            return snippets
        }
    }

    /// Moves an unreadable snippets.json aside as `snippets.json.corrupt` so
    /// it is never overwritten by a later save. Mirrors `VocabularyStore`.
    private static func preserveCorruptFile() {
        let backup = fileURL.appendingPathExtension("corrupt")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: fileURL, to: backup)
        log.error("snippets.json was unreadable; moved to snippets.json.corrupt and started empty")
    }

    // MARK: - Self test

    static func runSelfTest() -> Bool {
        var passed = true

        // MARK: Corrupt snippets.json is preserved, not silently overwritten
        // Same contract as LearnedStore/VocabularyStore (release-hardening.md):
        // an undecodable store must never present as fresh-and-writable.
        do {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("yafda-selftest-snippets-\(UUID().uuidString)",
                                        isDirectory: true)
            try? FileManager.default.createDirectory(
                at: tmp, withIntermediateDirectories: true)
            directoryOverride = tmp
            defer {
                directoryOverride = nil
                try? FileManager.default.removeItem(at: tmp)
            }

            let backup = fileURL.appendingPathExtension("corrupt")
            let garbage = Data("[{broken".utf8)
            try? garbage.write(to: fileURL)
            let loaded = load()
            let preserved = (try? Data(contentsOf: backup)) == garbage
            save([Snippet(trigger: "sig", expansion: "Best, K")])
            let backupUntouched = (try? Data(contentsOf: backup)) == garbage
            let ok = loaded.isEmpty && preserved && backupUntouched
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): corrupt snippets.json -> empty load, " +
                  "preserved as .corrupt (\(preserved)), survives a save (\(backupUntouched))")

            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: backup)
            let freshOK = load().isEmpty
                && !FileManager.default.fileExists(atPath: backup.path)
            if !freshOK { passed = false }
            print("\(freshOK ? "PASS" : "FAIL"): missing snippets.json loads empty " +
                  "with no .corrupt created")
        }

        return passed
    }

    /// - Note: skips the after-write debounce trigger during a sync cycle's
    ///   own write-back - see `LearnedStore.save`.
    @discardableResult
    static func save(_ snippets: [Snippet]) -> Bool {
        StoreOwner.sync {
            guard let data = try? JSONEncoder().encode(snippets) else { return false }
            do {
                try data.write(to: fileURL, options: .atomic)
                if !StoreOwner.isRunningSyncCycle {
                    SyncScheduler.triggerDebounced(reason: "snippets.json write")
                }
                return true
            } catch {
                return false
            }
        }
    }

    /// Replaces spoken trigger phrases with their expansions.
    /// Longest triggers win so overlapping phrases behave predictably.
    static func expand(in text: String) -> String {
        var result = text
        let snippets = load()
            .filter { !$0.trigger.trimmingCharacters(in: .whitespaces).isEmpty }
            .sorted { $0.trigger.count > $1.trigger.count }
        for snippet in snippets {
            let escaped = NSRegularExpression.escapedPattern(
                for: snippet.trigger.trimmingCharacters(in: .whitespaces))
            // Case-insensitive whole-phrase match; expansion keeps saved casing.
            result = result.replacingOccurrences(
                of: "(?i)\\b\(escaped)\\b",
                with: NSRegularExpression.escapedTemplate(for: snippet.expansion),
                options: .regularExpression)
        }
        return result
    }
}
