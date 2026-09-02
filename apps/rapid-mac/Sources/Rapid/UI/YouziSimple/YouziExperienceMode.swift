import Foundation
import Observation

/// The two presentations of the same app-owned runtime and user data.
///
/// This is deliberately a presentation preference, not a runtime profile.
/// Switching it must never create or restart a model, conversation, store, or
/// connector. `ContentView` is the only place that branches on this value.
enum YouziExperienceMode: String, CaseIterable, Identifiable, Sendable {
    case simple
    case professional

    static let defaultMode: Self = .simple

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .simple: "简约模式"
        case .professional: "专业模式"
        }
    }

    var accessibilityIdentifier: String {
        "Youzi.ExperienceMode.\(rawValue)"
    }
}

/// App-owned, persisted experience preference.
///
/// Keeping persistence in a tiny observable object makes the default and
/// defensive fallback testable without standing up a SwiftUI scene. The
/// object contains no product data and no runtime services.
@MainActor
@Observable
final class YouziExperienceModeConfig {
    static let storageKey = "youzi.experience-mode.v1"

    private let defaults: UserDefaults

    var mode: YouziExperienceMode {
        didSet { defaults.set(mode.rawValue, forKey: Self.storageKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let rawValue = defaults.string(forKey: Self.storageKey),
           let storedMode = YouziExperienceMode(rawValue: rawValue) {
            mode = storedMode
        } else {
            mode = .defaultMode
        }
    }
}
