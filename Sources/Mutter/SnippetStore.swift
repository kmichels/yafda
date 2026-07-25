import Foundation

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
            guard let data = try? Data(contentsOf: fileURL),
                  let snippets = try? JSONDecoder().decode([Snippet].self, from: data)
            else { return [] }
            return snippets
        }
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
