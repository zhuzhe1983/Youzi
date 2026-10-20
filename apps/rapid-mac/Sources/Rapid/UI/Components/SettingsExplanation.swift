import SwiftUI

private struct SettingsShowsExplanationsKey: EnvironmentKey {
    // Shared headings/rows also appear outside Settings, where their copy
    // remains visible. Only the Settings window supplies the saved preference.
    static let defaultValue = true
}

extension EnvironmentValues {
    var settingsShowsExplanations: Bool {
        get { self[SettingsShowsExplanationsKey.self] }
        set { self[SettingsShowsExplanationsKey.self] = newValue }
    }
}

private struct SettingsExplanationModifier: ViewModifier {
    @Environment(\.settingsShowsExplanations) private var isVisible

    @ViewBuilder func body(content: Content) -> some View {
        if isVisible { content }
    }
}

extension View {
    /// Optional instructional copy only. Status, validation, limits, and
    /// confirmation messages stay outside this modifier and remain visible.
    func settingsExplanation() -> some View {
        modifier(SettingsExplanationModifier())
    }
}
