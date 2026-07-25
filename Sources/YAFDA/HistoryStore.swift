import Foundation

struct HistoryEntry: Codable, Identifiable, Equatable {
    let text: String
    let date: Date
    /// Length of the recording, if known. Used for words-per-minute stats.
    var duration: TimeInterval?
    /// Which LearnedStore rules fired on this transcript, and how many
    /// occurrences each replaced. AMUX-755: nil for entries written before
    /// this field existed, and for any run where nothing matched - optional
    /// so JSONDecoder tolerates the key being absent in both directions.
    var appliedCorrections: [AppliedCorrection]? = nil

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

    func add(_ text: String, duration: TimeInterval? = nil,
             appliedCorrections: [AppliedCorrection]? = nil) {
        entries.insert(HistoryEntry(
            text: text, date: Date(), duration: duration,
            appliedCorrections: appliedCorrections), at: 0)
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

    // MARK: - Self test

    /// `HistoryEntry`'s Codable conformance is the whole contract here: no
    /// file I/O is needed to exercise it, so this never touches history.json.
    static func runSelfTest() -> Bool {
        var passed = true

        let withCorrections = HistoryEntry(
            text: "Ask laptop about the export.", date: Date(), duration: 12,
            appliedCorrections: [
                AppliedCorrection(heard: "Konrad", intended: "laptop", count: 2),
            ])
        if let data = try? JSONEncoder().encode(withCorrections),
           let decoded = try? JSONDecoder().decode(HistoryEntry.self, from: data) {
            let ok = decoded == withCorrections
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): HistoryEntry round-trips with appliedCorrections" +
                  (ok ? "" : " = \(decoded)"))
        } else {
            passed = false
            print("FAIL: HistoryEntry with appliedCorrections failed to encode/decode")
        }

        let withoutCorrections = HistoryEntry(text: "Hello world.", date: Date(), duration: nil)
        if let data = try? JSONEncoder().encode(withoutCorrections),
           let decoded = try? JSONDecoder().decode(HistoryEntry.self, from: data) {
            let ok = decoded == withoutCorrections && decoded.appliedCorrections == nil
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): HistoryEntry round-trips without appliedCorrections")
        } else {
            passed = false
            print("FAIL: HistoryEntry without appliedCorrections failed to encode/decode")
        }

        // A history.json written before this field existed has no key for it
        // at all - JSONDecoder must tolerate that and decode nil, same as any
        // other build reading a file this build wrote.
        let legacyJSON = """
        {"text":"Send it to Phocus.","date":712345678.0,"duration":8.5}
        """
        if let data = legacyJSON.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(HistoryEntry.self, from: data) {
            let ok = decoded.text == "Send it to Phocus."
                && decoded.duration == 8.5
                && decoded.appliedCorrections == nil
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): legacy history entry without the field decodes")
        } else {
            passed = false
            print("FAIL: legacy history entry failed to decode")
        }

        return passed
    }
}
