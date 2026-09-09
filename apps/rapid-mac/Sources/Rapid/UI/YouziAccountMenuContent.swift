import SwiftUI

/// Runtime-free account surfaces. Both shells render the same preference and
/// controls; fixtures can exercise them without creating a model server.
struct YouziAccountMenuTrigger: View {
    let mode: YouziExperienceMode
    let isChinese: Bool
    let scale: CGFloat
    var userAddress: String = ""

    /// A profile label, not the assistant's conversational name or app brand.
    static func displayName(userAddress: String, isChinese: Bool) -> String {
        let name = CustomInstructionsConfig.identity(userAddress)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? (isChinese ? "柚子" : "Youzi") : name
    }

    private var displayName: String {
        Self.displayName(userAddress: userAddress, isChinese: isChinese)
    }

    var body: some View {
        HStack(spacing: RapidTheme.Space.sm) {
            Text(displayName)
                .font(.system(size: round(13.5 * scale), weight: .medium))
                .foregroundStyle(RapidTheme.textPrimary)
                .truncationMode(.tail)
                .help(displayName)
                .accessibilityIdentifier("Youzi.AccountMenu.DisplayName")
            Text(mode.localizedShortDisplayName(isChinese: isChinese))
                .font(.system(size: round(11.5 * scale), weight: .medium))
                .foregroundStyle(RapidTheme.brandPrimary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(RapidTheme.brandPrimary.opacity(0.12), in: Capsule())
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel(mode.localizedDisplayName(isChinese: isChinese))
                .accessibilityIdentifier("Youzi.AccountMenu.ModeBadge")
            Spacer(minLength: 0)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: round(11.5 * scale)))
                .foregroundStyle(RapidTheme.textSecondary)
                .fixedSize()
        }
        .lineLimit(1)
        .padding(.horizontal, RapidTheme.Space.sm)
        .frame(minHeight: 40)
        .contentShape(Rectangle())
    }
}

struct YouziAccountMenuContent<Status: View>: View {
    @Binding var mode: YouziExperienceMode
    @Binding var appearance: AppearanceMode
    let isChinese: Bool
    let scale: CGFloat
    let openSettings: () -> Void
    let checkForUpdates: () -> Void
    @ViewBuilder var status: () -> Status

    static func panelWidth(isChinese: Bool, scale: CGFloat) -> CGFloat {
        (isChinese ? 332 : 352) * max(1, scale)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RapidTheme.Space.sm) {
            header
            Divider()
            status()
            Divider()
            appearanceRow
            row(title: isChinese ? "设置" : "Settings", image: "gearshape",
                identifier: "Youzi.AccountMenu.Settings", action: openSettings)
            row(title: isChinese ? "检查更新" : "Check for Updates", image: "arrow.triangle.2.circlepath",
                identifier: "Youzi.AccountMenu.CheckForUpdates", action: checkForUpdates)
        }
        .font(.system(size: round(13.5 * scale)))
        .padding(RapidTheme.Space.md)
        .frame(width: Self.panelWidth(isChinese: isChinese, scale: scale), alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: RapidTheme.Space.sm) {
            HStack(spacing: RapidTheme.Space.sm) {
                YouziLogo(size: 28)
                Text(isChinese ? "柚子" : "Youzi")
                    .fontWeight(.medium)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("Youzi.AccountMenu.Identity")
            Spacer(minLength: RapidTheme.Space.sm)
            Picker(isChinese ? "界面模式" : "Interface mode", selection: $mode) {
                ForEach(YouziExperienceMode.allCases) { choice in
                    Text(choice.localizedShortDisplayName(isChinese: isChinese))
                        .tag(choice)
                        .accessibilityLabel(choice.localizedDisplayName(isChinese: isChinese))
                        .accessibilityIdentifier(choice.accessibilityIdentifier)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: (isChinese ? 132 : 152) * max(1, scale))
            .accessibilityIdentifier("Youzi.AccountMenu.ExperienceMode")
        }
        .lineLimit(1)
        .frame(minHeight: 32)
    }

    private var appearanceRow: some View {
        HStack(spacing: RapidTheme.Space.sm) {
            Label(isChinese ? "外观" : "Theme", systemImage: "circle.lefthalf.filled")
            Spacer(minLength: RapidTheme.Space.xs)
            Picker(isChinese ? "外观" : "Theme", selection: $appearance) {
                ForEach(AppearanceMode.accountMenuOrder) { choice in
                    Text(choice.localizedShortDisplayName(isChinese: isChinese))
                        .tag(choice)
                        .accessibilityLabel(choice.localizedDisplayName(isChinese: isChinese))
                        .accessibilityIdentifier("Youzi.AccountMenu.Appearance.\(choice.rawValue)")
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 168 * max(1, scale))
            .accessibilityIdentifier("Youzi.AccountMenu.Appearance")
        }
        .lineLimit(1)
    }

    private func row(title: String, image: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: image)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}
