import SwiftUI

/// One circular treatment for send, stop and live voice, with a stable hit area.
struct YouziComposerIconButton: View {
    let symbol: String
    let label: String
    var enabled = true
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(enabled ? RapidTheme.onBrandPrimary : RapidTheme.textSecondary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(enabled ? RapidTheme.brandPrimary : Color.clear))
                .overlay(Circle().strokeBorder(enabled ? Color.clear : RapidTheme.hairlineStrong, lineWidth: 1))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}
