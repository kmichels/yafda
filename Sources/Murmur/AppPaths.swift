import Foundation

enum AppPaths {
    static var supportDirectory: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("Murmur", isDirectory: true)

        // One-time migration from the app's pre-rename data folder, so
        // history, dictionary, snippets and scratchpad survive.
        let legacy = base.appendingPathComponent("WhisperFlow", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path),
           FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.moveItem(at: legacy, to: directory)
        }

        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        return directory
    }

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
        let alreadyExisted = FileManager.default.fileExists(atPath: directory.path)
        if !alreadyExisted {
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
        }
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        if !alreadyExisted {
            syncedDirectoryWasJustCreated = true
        }
        return directory
    }

    /// True when this process created the CloudDocs/Murmur folder itself this
    /// launch. A just-created folder is indistinguishable from one whose iCloud
    /// listing has not materialized yet, so `.missing` inside it must not
    /// authorize seeding — the other Mac's files may simply not be visible yet.
    /// A genuinely-first machine defers its initial seed to its second launch
    /// as a consequence.
    ///
    /// Only `syncedDirectory` may set this to true; only tests reset it to
    /// false after simulating the just-created state.
    static var syncedDirectoryWasJustCreated = false

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
        guard manager.fileExists(atPath: url.path) else {
            // fileExists cannot distinguish "absent" from "permission denied", and
            // .missing is the signal that authorizes seeding local data over the
            // remote. Only report it when the parent directory is provably
            // listable — any doubt resolves to .notDownloaded (skip this cycle).
            guard (try? FileManager.default.contentsOfDirectory(
                atPath: url.deletingLastPathComponent().path)) != nil else {
                return .notDownloaded
            }
            return .missing
        }

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
        return coordinationError == nil ? result : .notDownloaded
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
}
