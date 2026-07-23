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
