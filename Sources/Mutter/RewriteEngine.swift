import Foundation
import FoundationModels

/// On-device text rewriting via Apple's Foundation Models framework
/// (Apple Intelligence). Powers Style and Transforms — no cloud involved.
final class RewriteEngine {

    var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    /// Human-readable reason when the on-device model can't be used.
    var availabilityNote: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "This Mac doesn't support Apple Intelligence, which powers " +
                   "on-device rewriting."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Enable Apple Intelligence in System Settings to power " +
                   "on-device rewriting."
        case .unavailable(.modelNotReady):
            return "The on-device model is still downloading — try again in a bit."
        case .unavailable:
            return "The on-device model is unavailable."
        }
    }

    func rewrite(_ text: String, instructions: String) async throws -> String {
        let session = LanguageModelSession(
            instructions: instructions +
            "\nOutput ONLY the resulting text — no preamble, no quotes, " +
            "no explanations.")
        let response = try await session.respond(to: text)
        return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Styles (per-app tone, like Wispr Flow's Style feature)

enum WritingStyle: String, Codable, CaseIterable, Identifiable {
    case none, formal, casual, veryCasual

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "As spoken"
        case .formal: return "Formal"
        case .casual: return "Casual"
        case .veryCasual: return "Very casual"
        }
    }

    var instructions: String? {
        switch self {
        case .none:
            return nil
        case .formal:
            return "Rewrite the user's dictated text in a formal, professional " +
                   "tone: proper capitalization, professional punctuation and " +
                   "syntax. Keep the meaning, language and approximate length."
        case .casual:
            return "Rewrite the user's dictated text in a relaxed, friendly, " +
                   "conversational tone, as if messaging a colleague on Slack. " +
                   "Keep the meaning, language and approximate length."
        case .veryCasual:
            return "Rewrite the user's dictated text in a very casual chat tone: " +
                   "minimal capitalization, loose punctuation, like texting a " +
                   "friend. Keep the meaning, language and approximate length."
        }
    }
}

/// Default style plus per-app overrides, keyed by bundle identifier.
enum StyleSettings {
    private static let defaults = UserDefaults.standard

    static var defaultStyle: WritingStyle {
        get {
            WritingStyle(rawValue: defaults.string(forKey: "styleDefault") ?? "")
                ?? .none
        }
        set { defaults.set(newValue.rawValue, forKey: "styleDefault") }
    }

    /// bundleID → (app display name, style)
    static var overrides: [String: AppStyleRule] {
        get {
            guard let data = defaults.data(forKey: "styleOverrides"),
                  let rules = try? JSONDecoder().decode(
                    [String: AppStyleRule].self, from: data)
            else { return [:] }
            return rules
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: "styleOverrides")
            }
        }
    }

    static func style(forBundleID bundleID: String?) -> WritingStyle {
        guard let bundleID, let rule = overrides[bundleID] else {
            return defaultStyle
        }
        return rule.style
    }
}

struct AppStyleRule: Codable, Equatable {
    var appName: String
    var style: WritingStyle
}
