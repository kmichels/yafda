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

    init() {}

    private enum CodingKeys: String, CodingKey {
        case corrections, terms, vocabulary, snippets
    }

    // Synthesized Decodable fails the whole decode on any missing key, even
    // though every property here has a default - property defaults don't
    // apply to decoding. Without this, adding a field to SyncBase would make
    // every existing sync-base.json on disk fail to decode, loadBase() would
    // fall back to empty, and the next merge would read every prior sync as
    // a union with nothing - resurrecting anything since deleted.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        corrections = try container.decodeIfPresent(
            [String: LearnedCorrection].self, forKey: .corrections) ?? [:]
        terms = try container.decodeIfPresent([String].self, forKey: .terms) ?? []
        vocabulary = try container.decodeIfPresent(
            [String: VocabularyEntry].self, forKey: .vocabulary) ?? [:]
        snippets = try container.decodeIfPresent(
            [String: Snippet].self, forKey: .snippets) ?? [:]
    }
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

    /// Content key for a vocabulary entry: the case-insensitive (word, misheard)
    /// pair — the same identity `VocabularyStore.migrate` dedups by. NEVER the
    /// UUID: each machine mints its own ids for the same logical entry.
    static func key(for entry: VocabularyEntry) -> String {
        entry.word.lowercased() + "\u{0}"
            + (entry.misheard ?? "").lowercased()
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
        syncVocabulary(in: remoteDirectory, base: &base)
        syncSnippets(in: remoteDirectory, base: &base)
        saveBase(base)
    }

    static func syncLearned(in remoteDirectory: URL, base: inout SyncBase) {
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
        //
        // A corrupt or missing local file loads as empty, which the diff would
        // read as "user deleted everything" and propagate. If this machine has
        // synced data before (non-empty base), refuse to sync this store unless
        // the local file is present and decodes. A genuine delete-everything
        // leaves a well-formed (possibly empty) file and still propagates -
        // only damage is refused. Checked here, before the merge, rather than
        // only when the merge result happens to be empty: even one surviving
        // remote entry would previously skip this check while every base entry
        // was still misread as a local deletion and pruned everywhere.
        if !base.corrections.isEmpty || !base.terms.isEmpty {
            guard localIsIntact(LearnedStore.fileURL, as: LearnedData.self) else {
                log.error("local learned.json is missing or unreadable; skipping sync to protect the remote")
                return
            }
        }

        let local = LearnedStore.load()
        let localCorrections = keyed(local.corrections)
        let remoteCorrections = keyed(remote.corrections)

        let mergedCorrections = SyncMerge.merge(
            base: base.corrections, local: localCorrections,
            remote: remoteCorrections, resolve: resolve)
        let mergedTerms = SyncMerge.mergeTerms(
            base: base.terms, local: local.terms, remote: remote.terms)

        var merged = LearnedData()
        merged.corrections = mergedCorrections.values.sorted { $0.heard < $1.heard }
        merged.terms = mergedTerms

        log.info("""
            learned.json merged: \(localCorrections.count) local, \
            \(remoteCorrections.count) remote, \(merged.corrections.count) merged
            """)

        // Neither write may be skipped when gating the base advance: a base
        // ahead of either copy makes the next launch read that copy's
        // never-persisted entries as local deletions and prune them.
        guard LearnedStore.save(merged) else {
            log.error("local learned.json write failed; base left untouched so the next launch retries")
            return
        }
        guard write(merged, to: remoteURL) else {
            log.error("remote write failed; base left untouched so the next launch retries")
            return
        }
        base.corrections = mergedCorrections
        base.terms = mergedTerms
    }

    private static func syncVocabulary(in remoteDirectory: URL, base: inout SyncBase) {
        let remoteURL = remoteDirectory.appendingPathComponent("vocabulary.json")
        // Read the REMOTE first: the coordinated iCloud read can block, and a
        // local snapshot taken before it would overwrite anything the user
        // adds meanwhile (same race Task 3 fixed in syncLearned). Snapshot
        // local only after the blocking read returns.
        let remoteData: Data
        switch AppPaths.readShared(remoteURL) {
        case .notDownloaded:
            log.info("vocabulary.json not downloaded yet; skipping this cycle")
            return
        case .missing:
            let seed = VocabularyStore.load()
            log.info("vocabulary.json absent remotely; seeding from local")
            let seedKeyed = Dictionary(
                seed.map { (key(for: $0), $0) }, uniquingKeysWith: { first, _ in first })
            // Seed sorted, matching what every subsequent merge writes.
            let sorted = seed.sorted { $0.word.lowercased() < $1.word.lowercased() }
            guard write(sorted, to: remoteURL) else { return }
            base.vocabulary = seedKeyed
            return
        case .ready(let data):
            remoteData = data
        }
        guard let remoteList = try? JSONDecoder().decode([VocabularyEntry].self, from: remoteData)
        else {
            log.error("remote vocabulary.json is unreadable; keeping local untouched")
            return
        }

        // Blocking read is behind us: snapshot local now, so an entry the
        // user added while we waited is merged instead of destroyed.
        //
        // A corrupt or missing local file loads as empty, which the diff would
        // read as "user deleted everything" and propagate. If this machine has
        // synced data before (non-empty base), refuse to sync this store unless
        // the local file is present and decodes. A genuine delete-everything
        // leaves a well-formed (possibly empty) file and still propagates -
        // only damage is refused. Checked here, before the merge, rather than
        // only when the merge result happens to be empty.
        //
        // Note: VocabularyStore.load() on a corrupt file preserves it as
        // .corrupt and returns [], removing vocabulary.json in the process.
        // localIsIntact then finds no file at all and reports false, so this
        // guard still catches it even though load() already "handled" it.
        if !base.vocabulary.isEmpty {
            guard localIsIntact(VocabularyStore.fileURL, as: [VocabularyEntry].self) else {
                log.error("local vocabulary.json is missing or unreadable; skipping sync to protect the remote")
                return
            }
        }

        let localEntries = Dictionary(
            VocabularyStore.load().map { (key(for: $0), $0) },
            uniquingKeysWith: { first, _ in first })
        let remoteEntries = Dictionary(
            remoteList.map { (key(for: $0), $0) }, uniquingKeysWith: { first, _ in first })
        let merged = SyncMerge.merge(
            base: base.vocabulary, local: localEntries,
            remote: remoteEntries) { localValue, _ in localValue }

        let ordered = merged.values.sorted { $0.word.lowercased() < $1.word.lowercased() }
        log.info("vocabulary.json merged: \(ordered.count) entries")

        // Neither write may be skipped when gating the base advance: a base
        // ahead of either copy makes the next launch read that copy's
        // never-persisted entries as local deletions and prune them.
        guard VocabularyStore.save(ordered) else {
            log.error("local vocabulary.json write failed; base left untouched so the next launch retries")
            return
        }
        guard write(ordered, to: remoteURL) else {
            log.error("remote write failed; base left untouched so the next launch retries")
            return
        }
        base.vocabulary = merged
    }

    private static func syncSnippets(in remoteDirectory: URL, base: inout SyncBase) {
        let remoteURL = remoteDirectory.appendingPathComponent("snippets.json")
        // Remote first, local snapshot after — same race fix as syncLearned
        // and syncVocabulary: the coordinated read can block, and a pre-read
        // local snapshot would overwrite a snippet added meanwhile.
        let remoteData: Data
        switch AppPaths.readShared(remoteURL) {
        case .notDownloaded:
            log.info("snippets.json not downloaded yet; skipping this cycle")
            return
        case .missing:
            let seed = SnippetStore.load()
            log.info("snippets.json absent remotely; seeding from local")
            let seedKeyed = Dictionary(
                seed.map { (key(for: $0), $0) }, uniquingKeysWith: { first, _ in first })
            let sorted = seed.sorted { $0.trigger < $1.trigger }
            guard write(sorted, to: remoteURL) else { return }
            base.snippets = seedKeyed
            return
        case .ready(let data):
            remoteData = data
        }
        guard let remoteList = try? JSONDecoder().decode([Snippet].self, from: remoteData)
        else {
            log.error("remote snippets.json is unreadable; keeping local untouched")
            return
        }

        // Blocking read is behind us: snapshot local now, so a snippet the
        // user added while we waited is merged instead of destroyed. See
        // syncVocabulary/syncLearned for why this check runs before the merge.
        if !base.snippets.isEmpty {
            guard localIsIntact(SnippetStore.fileURL, as: [Snippet].self) else {
                log.error("local snippets.json is missing or unreadable; skipping sync to protect the remote")
                return
            }
        }

        let localSnippets = Dictionary(
            SnippetStore.load().map { (key(for: $0), $0) },
            uniquingKeysWith: { first, _ in first })
        let remoteSnippets = Dictionary(
            remoteList.map { (key(for: $0), $0) }, uniquingKeysWith: { first, _ in first })
        let merged = SyncMerge.merge(
            base: base.snippets, local: localSnippets,
            remote: remoteSnippets) { localValue, _ in localValue }

        let ordered = merged.values.sorted { $0.trigger < $1.trigger }
        log.info("snippets.json merged: \(ordered.count) snippets")

        guard SnippetStore.save(ordered) else {
            log.error("local snippets.json write failed; base left untouched so the next launch retries")
            return
        }
        guard write(ordered, to: remoteURL) else {
            log.error("remote write failed; base left untouched so the next launch retries")
            return
        }
        base.snippets = merged
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
