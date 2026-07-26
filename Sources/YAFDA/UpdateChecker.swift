import Foundation
import os

/// Checks GitHub Releases for a newer YAFDA build and hands back a pointer to
/// it - never a downloader, never an installer. See
/// `.planning/design/update-check.md` for why (no Sparkle: its helper
/// apps/XPC services are a disproportionate signing burden for a named group
/// of users).
enum UpdateChecker {
    private static let log = Logger(subsystem: "local.yafda", category: "UpdateChecker")

    /// The pinned endpoint. Anonymous GET, no token - this is a public repo.
    static let releasesURL = URL(string: "https://api.github.com/repos/kmichels/yafda/releases/latest")!

    static let autoCheckInterval: TimeInterval = 24 * 60 * 60

    struct ReleaseInfo: Equatable {
        let version: String
        let url: URL
    }

    /// Extracts `tag_name` (leading `v` stripped) and `html_url` from a
    /// GitHub releases/latest response. Pure - any malformed shape is a nil,
    /// never a thrown error, so callers never need a catch clause for JSON
    /// GitHub happens to change.
    static func parse(latestReleaseJSON data: Data) -> ReleaseInfo? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String,
              let urlString = object["html_url"] as? String,
              let url = URL(string: urlString)
        else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return ReleaseInfo(version: version, url: url)
    }

    /// Dotted numeric version compare. Missing trailing components read as 0
    /// on the shorter side, so "0.10.2.1" beats "0.10.2". Any non-numeric
    /// component - "abc", "" - fails safe to false rather than guessing:
    /// nagging about a garbage tag is worse than missing a real update.
    static func isNewer(_ remote: String, than local: String) -> Bool {
        func components(_ version: String) -> [Int]? {
            let parts = version.split(separator: ".", omittingEmptySubsequences: false)
            guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
            return parts.map { Int($0) ?? -1 }.contains(-1) ? nil : parts.map { Int($0)! }
        }
        guard let remoteParts = components(remote), let localParts = components(local)
        else { return false }
        let count = max(remoteParts.count, localParts.count)
        for index in 0..<count {
            let remoteValue = index < remoteParts.count ? remoteParts[index] : 0
            let localValue = index < localParts.count ? localParts[index] : 0
            if remoteValue != localValue { return remoteValue > localValue }
        }
        return false
    }

    /// The 24h auto-check throttle. Pure - the manual "Check for Updates…"
    /// menu item bypasses this entirely rather than calling it with a forced
    /// `lastCheckAt` of nil, because an explicit click is its own consent.
    static func shouldAutoCheck(now: Date, lastCheckAt: Date?, enabled: Bool) -> Bool {
        guard enabled else { return false }
        guard let lastCheckAt else { return true }
        return now.timeIntervalSince(lastCheckAt) >= autoCheckInterval
    }

    /// Orchestrates one check: fetch, parse, compare against `localVersion`.
    /// Every failure mode - throw, malformed JSON, remote <= local - folds to
    /// nil so callers never need their own error handling; the one `.info`
    /// log line is the only trace.
    static func check(
        localVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"]
            as? String ?? "0.0.0",
        fetch: (URL) async throws -> Data
    ) async -> ReleaseInfo? {
        let data: Data
        do {
            data = try await fetch(releasesURL)
        } catch {
            log.info("check failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let release = parse(latestReleaseJSON: data) else {
            log.info("check failed: could not parse release JSON")
            return nil
        }
        guard isNewer(release.version, than: localVersion) else {
            log.info("""
                check: up to date (local \(localVersion, privacy: .public), \
                remote \(release.version, privacy: .public))
                """)
            return nil
        }
        log.info("check: update found \(release.version, privacy: .public)")
        return release
    }

    /// Production fetch: anonymous GET, 10s timeout, explicit User-Agent -
    /// GitHub's API rejects UA-less requests, and URLSession's default UA
    /// happens to satisfy it today but that is not a contract to depend on.
    static func urlSessionFetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("YAFDA-update-check", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }

    // MARK: - Self test

    static func runSelfTest() async -> Bool {
        var passed = true

        // MARK: parse - valid JSON, v-prefix stripped
        do {
            let json = Data("""
                {"tag_name": "v0.10.3", "html_url": "https://github.com/kmichels/yafda/releases/tag/v0.10.3"}
                """.utf8)
            let info = parse(latestReleaseJSON: json)
            let ok = info?.version == "0.10.3"
                && info?.url.absoluteString == "https://github.com/kmichels/yafda/releases/tag/v0.10.3"
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): parse strips leading v and extracts html_url, got \(String(describing: info))")
        }

        // MARK: parse - missing fields, non-JSON, empty all -> nil
        do {
            let missingTag = parse(latestReleaseJSON: Data(#"{"html_url": "https://x"}"#.utf8))
            let missingURL = parse(latestReleaseJSON: Data(#"{"tag_name": "v1.0.0"}"#.utf8))
            let nonJSON = parse(latestReleaseJSON: Data("not json".utf8))
            let empty = parse(latestReleaseJSON: Data())
            let ok = missingTag == nil && missingURL == nil && nonJSON == nil && empty == nil
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): parse returns nil for missing tag_name/html_url, " +
                  "non-JSON, and empty data")
        }

        // MARK: isNewer - dotted numeric compare
        do {
            let cases: [(remote: String, local: String, expected: Bool)] = [
                ("0.10.3", "0.10.2", true),
                ("0.11.0", "0.10.9", true),
                ("1.0.0", "0.99.99", true),
                ("0.10.2", "0.10.2", false),
                ("0.10.1", "0.10.2", false),
                ("0.10.2.1", "0.10.2", true),
                ("abc", "0.10.2", false),
                ("", "0.10.2", false),
            ]
            var ok = true
            for testCase in cases {
                let got = isNewer(testCase.remote, than: testCase.local)
                if got != testCase.expected {
                    ok = false
                    print("  isNewer(\(testCase.remote), than: \(testCase.local)) = " +
                          "\(got), expected \(testCase.expected)")
                }
            }
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): isNewer compares dotted numeric versions, " +
                  "garbage never wins")
        }

        // MARK: shouldAutoCheck - 24h throttle
        do {
            let now = Date(timeIntervalSince1970: 1_000_000)
            let neverChecked = shouldAutoCheck(now: now, lastCheckAt: nil, enabled: true)
            let recent = shouldAutoCheck(
                now: now, lastCheckAt: now.addingTimeInterval(-23 * 60 * 60), enabled: true)
            let stale = shouldAutoCheck(
                now: now, lastCheckAt: now.addingTimeInterval(-25 * 60 * 60), enabled: true)
            let disabled = shouldAutoCheck(now: now, lastCheckAt: nil, enabled: false)
            let ok = neverChecked && !recent && stale && !disabled
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): shouldAutoCheck: never=\(neverChecked) " +
                  "23hAgo=\(recent) 25hAgo=\(stale) disabled=\(disabled)")
        }

        // MARK: check() - injected fetch, injected local version
        do {
            var requestedURL: URL?
            let newerJSON = Data("""
                {"tag_name": "v9.9.9", "html_url": "https://github.com/kmichels/yafda/releases/tag/v9.9.9"}
                """.utf8)

            let result = await check(localVersion: "0.10.2") { url in
                requestedURL = url
                return newerJSON
            }
            let foundNewer = result?.version == "9.9.9"
            let hitPinnedURL = requestedURL == releasesURL
            if !(foundNewer && hitPinnedURL) { passed = false }
            print("\(foundNewer && hitPinnedURL ? "PASS" : "FAIL"): check() surfaces a newer " +
                  "release from injected fetch and requests the pinned URL")
        }
        do {
            let equalJSON = Data("""
                {"tag_name": "v0.10.2", "html_url": "https://github.com/kmichels/yafda/releases/tag/v0.10.2"}
                """.utf8)
            let result = await check(localVersion: "0.10.2") { _ in equalJSON }
            let ok = result == nil
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): check() returns nil when remote == local")
        }
        do {
            let olderJSON = Data("""
                {"tag_name": "v0.9.0", "html_url": "https://github.com/kmichels/yafda/releases/tag/v0.9.0"}
                """.utf8)
            let result = await check(localVersion: "0.10.2") { _ in olderJSON }
            let ok = result == nil
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): check() returns nil when remote < local")
        }
        do {
            struct FetchError: Error {}
            let result = await check(localVersion: "0.10.2") { _ in throw FetchError() }
            let ok = result == nil
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): check() returns nil when fetch throws")
        }

        // MARK: Settings.updateCheckEnabled - defaults-to-true trap
        do {
            let saved = UserDefaults.standard.object(forKey: "updateCheckEnabled")
            UserDefaults.standard.removeObject(forKey: "updateCheckEnabled")
            let defaultsOn = Settings.updateCheckEnabled
            Settings.updateCheckEnabled = false
            let storesOff = Settings.updateCheckEnabled == false
            if let saved {
                UserDefaults.standard.set(saved, forKey: "updateCheckEnabled")
            } else {
                UserDefaults.standard.removeObject(forKey: "updateCheckEnabled")
            }
            let ok = defaultsOn && storesOff
            if !ok { passed = false }
            print("\(ok ? "PASS" : "FAIL"): updateCheckEnabled defaults on and " +
                  "persists false when set (defaultsOn=\(defaultsOn) storesOff=\(storesOff))")
        }

        return passed
    }
}
