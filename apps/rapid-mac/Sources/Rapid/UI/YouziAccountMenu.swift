import SwiftUI

/// Shared account affordance for Simple and Professional Mode.
///
/// This is presentation chrome only: it must never create or restart a model,
/// conversation, store, or connector. Mode switching writes the persisted
/// experience preference; `ContentView` is the only place that branches on it.
struct YouziAccountMenu: View {
    static let helpURL = URL(string: "https://github.com/zhuzhe1983/Youzi/issues")!

    var catalogEntries: [ModelEntry] = []
    var arrowEdge: Edge = .bottom

    @Environment(YouziExperienceModeConfig.self) private var experienceMode
    @Environment(AppearanceConfig.self) private var appearance
    @Environment(ServerManager.self) private var server
    @Environment(UpdateChecker.self) private var updater
    @Environment(SparkleUpdateController.self) private var sparkleUpdater
    @Environment(SettingsRouter.self) private var settingsRouter
    @Environment(YouziI18nConfig.self) private var i18n
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL

    @State private var isPresented = false

    private var currentOccupancy: YouziModelOccupancy {
        let voiceResident = server.residency.audioLanes.contains { $0.state == "resident" }
        return YouziModelOccupancy.resolve(
            residency: server.residency,
            host: MemoryProbe.snapshot(),
            voiceLaneResident: voiceResident
        )
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            trigger
        }
        .buttonStyle(.plain)
        .padding(.horizontal, RapidTheme.Space.sm)
        .padding(.vertical, RapidTheme.Space.xs)
        .popover(isPresented: $isPresented, arrowEdge: arrowEdge) {
            menuBody
        }
        .accessibilityIdentifier("Youzi.AccountMenu")
        .accessibilityLabel("柚子")
    }

    private var trigger: some View {
        HStack(spacing: RapidTheme.Space.sm) {
            YouziLogo(size: 28)
            VStack(alignment: .leading, spacing: RapidTheme.Space.xxs) {
                Text("柚子")
                    .font(RapidFont.bodyEmphasis)
                    .foregroundStyle(RapidTheme.textPrimary)
                Text(experienceMode.mode.localizedDisplayName(isChinese: i18n.isChinese))
                    .font(RapidFont.caption)
                    .foregroundStyle(RapidTheme.textSecondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.up.chevron.down")
                .font(RapidFont.caption)
                .foregroundStyle(RapidTheme.textSecondary)
        }
        .padding(.horizontal, RapidTheme.Space.sm)
        .frame(minHeight: 48)
        .contentShape(Rectangle())
    }

    private var menuBody: some View {
        VStack(alignment: .leading, spacing: RapidTheme.Space.sm) {
            identityHeader

            Divider()

            Button {
                let next = experienceMode.mode.other
                isPresented = false
                experienceMode.mode = next
            } label: {
                Label(
                    i18n.text(
                        zh: "切换到\(experienceMode.mode.other.localizedDisplayName(isChinese: true))",
                        en: "Switch to \(experienceMode.mode.other.localizedDisplayName(isChinese: false))"
                    ),
                    systemImage: "arrow.left.arrow.right"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(experienceMode.mode.other.accessibilityIdentifier)

            Divider()

            systemStatusRow

            Divider()

            appearanceRow

            menuRowButton(
                title: i18n.text(zh: "设置", en: "Settings"),
                systemImage: "gearshape",
                identifier: "Youzi.AccountMenu.Settings"
            ) {
                isPresented = false
                openWindow(id: "settings")
            }

            menuRowButton(
                title: i18n.text(zh: "检查更新", en: "Check for Updates"),
                systemImage: "arrow.triangle.2.circlepath",
                identifier: "Youzi.AccountMenu.CheckForUpdates",
                action: checkForUpdates
            )

            menuRowButton(
                title: i18n.text(zh: "帮助与反馈", en: "Help & Feedback"),
                systemImage: "questionmark.circle",
                identifier: "Youzi.AccountMenu.Help"
            ) {
                isPresented = false
                openURL(Self.helpURL)
            }
        }
        .padding(RapidTheme.Space.md)
        .frame(width: 292, alignment: .leading)
    }

    private var identityHeader: some View {
        HStack(spacing: RapidTheme.Space.sm) {
            YouziLogo(size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("柚子")
                    .font(RapidFont.bodyEmphasis)
                Text(i18n.text(zh: "本机单机运行", en: "Runs 100% locally on your Mac"))
                    .font(RapidFont.caption)
                    .foregroundStyle(RapidTheme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("Youzi.AccountMenu.Identity")
    }

    private var appearanceRow: some View {
        @Bindable var appearance = appearance
        return HStack(spacing: RapidTheme.Space.sm) {
            Label(i18n.text(zh: "外观", en: "Theme"), systemImage: "circle.lefthalf.filled")
                .labelStyle(.titleAndIcon)
            Spacer(minLength: RapidTheme.Space.xs)
            Picker(i18n.text(zh: "外观", en: "Theme"), selection: $appearance.mode) {
                ForEach(AppearanceMode.accountMenuOrder) { mode in
                    Text(mode.localizedShortDisplayName(isChinese: i18n.isChinese))
                        .tag(mode)
                        .accessibilityLabel(mode.localizedDisplayName(isChinese: i18n.isChinese))
                        .accessibilityIdentifier("Youzi.AccountMenu.Appearance.\(mode.rawValue)")
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 168)
            .accessibilityIdentifier("Youzi.AccountMenu.Appearance")
        }
        .font(RapidFont.body)
    }

    private var systemStatusRow: some View {
        VStack(alignment: .leading, spacing: RapidTheme.Space.xs) {
            HStack(spacing: RapidTheme.Space.xs) {
                Label(i18n.text(zh: "系统状态", en: "System Status"), systemImage: "heart.text.clipboard")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(RapidTheme.textSecondary)
                MemoryPill()
                CPUPill()
                GPUPill()
                Spacer(minLength: 2)
                Text(currentOccupancy.mode.label)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(RapidTheme.brandPrimary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(RapidTheme.brandPrimary.opacity(0.12))
                    )
            }
            .lineLimit(1)

        }
        .accessibilityIdentifier("Youzi.AccountMenu.SystemStatus")
    }

    private func menuRowButton(
        title: String,
        systemImage: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(RapidFont.body)
        .accessibilityIdentifier(identifier)
    }

    private func checkForUpdates() {
        isPresented = false
        if sparkleUpdater.isEnabled, sparkleUpdater.canCheckForUpdates {
            sparkleUpdater.checkForUpdates()
            return
        }
        Task { _ = await updater.check() }
        settingsRouter.route(to: .app) {
            openWindow(id: "settings")
        }
    }
}
