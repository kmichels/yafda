import Foundation

struct HistoryEntry: Codable, Identifiable, Equatable {
    let text: String
    let date: Date
    /// Length of the recording, if known. Used for words-per-minute stats.
    var duration: TimeInterval?

    var id: String { "\(date.timeIntervalSince1970)-\(text.hashValue)" }

    var wordCount: Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
}

/// Persists the most recent transcripts, like Wispr Flow's history panel.
final class HistoryStore {
    private(set) var entries: [HistoryEntry] = []
    private let limit = 50
    private var fileURL: URL {
        AppPaths.supportDirectory.appendingPathComponent("history.json")
    }

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = saved
        }
    }

    func add(_ text: String, duration: TimeInterval? = nil) {
        entries.insert(HistoryEntry(text: text, date: Date(), duration: duration), at: 0)
        if entries.count > limit {
            entries.removeLast(entries.count - limit)
        }
        save()
    }

    func delete(id: String) {
        entries.removeAll { $0.id == id }
        save()
    }

    func update(id: String, text: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index] = HistoryEntry(
            text: text, date: entries[index].date, duration: entries[index].duration)
        save()
    }

    func clear() {
        entries = []
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
