import Foundation

/// How the context-aware homophone disambiguation pass runs (if at all).
enum DisambiguationEngine: String, CaseIterable, Identifiable {
    /// No context pass. Recognition bias + hard corrections still apply. Default.
    case off
    /// On-device Apple model. Experimental: unreliable on macOS 26's ~3B model
    /// (may mis-substitute), kept for macOS 27's much stronger on-device model.
    case onDevice
    /// Apple Foundation Models on Private Cloud Compute — a macOS 27 capability.
    /// Inert on macOS 26 (behaves as `off`) until the PCC model API exists.
    case privateCloudCompute

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .off: return "Off"
        case .onDevice: return "On-device (experimental)"
        case .privateCloudCompute: return "Private Cloud Compute (macOS 27)"
        }
    }
}

enum Settings {
    private static let defaults = UserDefaults.standard

    /// Bundle ids this app has shipped under, newest legacy first. The
    /// UserDefaults domain *is* the bundle id, so every rename orphans the
    /// previous domain wholesale.
    ///
    /// **Newest first.** The loop below only fills keys that are still unset, so
    /// whichever domain is listed first wins. Getting the order wrong, or
    /// omitting the most recent id, silently restores *older* settings rather
    /// than resetting to defaults — which is worse, because it looks
    /// deliberate. `local.mutter` must stay at the head of this list until
    /// something newer replaces it.
    private static let legacySuiteNames = [
        "local.mutter", "local.murmur", "local.whisperflow",
    ]

    /// Every key Settings owns. This list is the whole migration: a key
    /// missing from it is a setting silently reset to its default on rename.
    /// `inputDeviceUID` is the one that hurts most — losing it drops recording
    /// back to whatever macOS considers the default input, which is a quiet
    /// downgrade rather than a visible failure.
    private static let migratedKeys = [
        "hotkey", "locale", "styleDefault", "styleOverrides",
        "engine", "whisperModel", "inputDeviceUID", "voiceProfile",
        "disambiguationEngine", "appendTrailingSpace",
    ]

    private static let migrationVersionKey = "defaultsMigratedVersion"
    private static let currentMigrationVersion = 2

    /// One-time import of preferences saved under an earlier bundle id.
    /// Call before anything reads Settings.
    ///
    /// A one-shot copy, deliberately not a fallback suite. Registering the old
    /// domain as a fallback would mean that clearing a setting here re-exposes
    /// the value underneath it, so a preference could never be reset to its
    /// default again.
    static func migrateLegacyDefaults() {
        guard defaults.integer(forKey: migrationVersionKey) < currentMigrationVersion
        else { return }
        for suiteName in legacySuiteNames {
            guard let legacy = UserDefaults(suiteName: suiteName) else { continue }
            for key in migratedKeys where defaults.object(forKey: key) == nil {
                if let value = legacy.object(forKey: key) {
                    defaults.set(value, forKey: key)
                }
            }
        }
        defaults.set(currentMigrationVersion, forKey: migrationVersionKey)
    }

    static var hotkey: HotkeyMonitor.Hotkey {
        get {
            HotkeyMonitor.Hotkey(
                rawValue: defaults.string(forKey: "hotkey") ?? "") ?? .fn
        }
        set { defaults.set(newValue.rawValue, forKey: "hotkey") }
    }

    static var localeIdentifier: String {
        get { defaults.string(forKey: "locale") ?? "en-US" }
        set { defaults.set(newValue, forKey: "locale") }
    }

    /// Recognition engine: "apple" (instant) or "whisper" (precise).
    static var engine: String {
        get { defaults.string(forKey: "engine") ?? "apple" }
        set { defaults.set(newValue, forKey: "engine") }
    }

    static var whisperModel: String {
        get { defaults.string(forKey: "whisperModel") ?? "small" }
        set { defaults.set(newValue, forKey: "whisperModel") }
    }

    static var locale: Locale {
        Locale(identifier: localeIdentifier)
    }

    /// Whether inserted dictation ends with a space, so the cursor is ready for
    /// the next sentence. On unless deliberately turned off.
    ///
    /// Note the `object(forKey:)` check: `bool(forKey:)` returns false for a key
    /// that has never been written, which would ship this off for everyone.
    static var appendTrailingSpace: Bool {
        get {
            guard defaults.object(forKey: "appendTrailingSpace") != nil else { return true }
            return defaults.bool(forKey: "appendTrailingSpace")
        }
        set { defaults.set(newValue, forKey: "appendTrailingSpace") }
    }

    /// UID of the microphone to record from, or nil to follow the system
    /// default. A UID rather than an AudioObjectID because IDs are ephemeral
    /// handles that change between launches.
    static var inputDeviceUID: String? {
        get { defaults.string(forKey: "inputDeviceUID") }
        set { defaults.set(newValue, forKey: "inputDeviceUID") }
    }

    /// Which engine runs the context disambiguation pass. Defaults to off — the
    /// on-device model is unreliable on macOS 26; see VocabularyDisambiguator.
    static var disambiguationEngine: DisambiguationEngine {
        get { defaults.string(forKey: "disambiguationEngine")
            .flatMap(DisambiguationEngine.init(rawValue:)) ?? .off }
        set { defaults.set(newValue.rawValue, forKey: "disambiguationEngine") }
    }
}
