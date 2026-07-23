import Foundation

/// One dictionary entry. A bare vocabulary word biases recognition toward its
/// spelling. When `misheard` is set, the entry is also a hard correction:
/// the recogniser's `misheard` output is replaced with `word`.
struct VocabularyEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var word: String
    /// nil for a plain vocabulary word; set for a "Correct a misspelling" entry.
    var misheard: String?
}

/// Unified dictionary store, Wispr-style: a list of vocabulary words, some of
/// which also carry a misheard-form correction. Replaces the old
/// replacement-only `dictionary.json`, which it migrates in once.
enum VocabularyStore {
    static var fileURL: URL {
        AppPaths.supportDirectory.appendingPathComponent("vocabulary.json")
    }

    /// Serialises the first-launch migration so a background transcribe task and
    /// the Dictionary UI can't both migrate-and-write at the same instant.
    private static let migrationLock = NSLock()

    /// Loads entries, migrating a legacy `dictionary.json` on first use.
    static func load() -> [VocabularyEntry] {
        if let entries = readFile() { return entries }
        // No vocabulary.json yet: migrate under a lock, double-checking inside
        // it so a concurrent caller that just migrated wins and we don't write
        // twice.
        migrationLock.lock()
        defer { migrationLock.unlock() }
        if let entries = readFile() { return entries }
        // Migrate the legacy dictionary if present, then always write the file
        // so this branch runs exactly once (even with nothing to migrate).
        let migrated = migrate(from: TextFormatter.loadDictionary())
        save(migrated)
        return migrated
    }

    private static func readFile() -> [VocabularyEntry]? {
        guard let data = try? Data(contentsOf: fileURL),
              let entries = try? JSONDecoder().decode([VocabularyEntry].self, from: data)
        else { return nil }
        return entries
    }

    static func save(_ entries: [VocabularyEntry]) {
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: - Pure transforms (unit-tested directly)

    /// Every entry's word, trimmed, de-duplicated, in order. Feeds the
    /// recogniser's bias prompt.
    static func words(from entries: [VocabularyEntry]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for entry in entries {
            let word = entry.word.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = word.lowercased()
            guard !word.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(word)
        }
        return result
    }

    /// Entries that carry a non-empty misheard form, as hard corrections.
    static func corrections(from entries: [VocabularyEntry]) -> [(misheard: String, word: String)] {
        entries.compactMap { entry in
            guard let misheard = entry.misheard?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !misheard.isEmpty else { return nil }
            let word = entry.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty else { return nil }
            return (misheard, word)
        }
    }

    /// Corrections as a `[misheard: word]` map for `TextFormatter`.
    static func correctionMap(from entries: [VocabularyEntry]) -> [String: String] {
        var map: [String: String] = [:]
        for correction in corrections(from: entries) {
            map[correction.misheard] = correction.word
        }
        return map
    }

    /// Converts a legacy `spoken -> replacement` dictionary into corrections.
    /// De-duplicates by lowercased misheard form so a legacy dictionary with
    /// both "focus" and "Focus" produces a single entry.
    static func migrate(from legacy: [String: String]) -> [VocabularyEntry] {
        var seen = Set<String>()
        var entries: [VocabularyEntry] = []
        for (spoken, replacement) in legacy.sorted(by: { $0.key.lowercased() < $1.key.lowercased() }) {
            let spokenTrimmed = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
            let replacementTrimmed = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !spokenTrimmed.isEmpty, !replacementTrimmed.isEmpty else { continue }
            let key = spokenTrimmed.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            entries.append(VocabularyEntry(word: replacementTrimmed, misheard: spokenTrimmed))
        }
        return entries.sorted { $0.word.lowercased() < $1.word.lowercased() }
    }

    // MARK: - Convenience wrappers over the live store

    static func words() -> [String] { words(from: load()) }
    static func correctionMap() -> [String: String] { correctionMap(from: load()) }
}
