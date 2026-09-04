import SwiftUI

/// Shared account affordance for Simple and Professional Mode.
///
/// This is presentation chrome only: it must never create or restart a model,
/// conversation, store, or connector. Mode switching writes the persisted
/// experience preference; `ContentView` is the only place that branches on it.
struct YouziAccountMenu: View {
    static let helpURL = URL(string: "https://github.com/zhuzhe1983/Youzi/issues")!

    @Environment(YouziExperienceModeConfig.self) private var experienceMode
    @Environment(AppearanceConfig.self) private var appearance
    @Environment(ServerManager.self) private var server
    @Environment(UpdateChecker.self) private var updater
    @Environment(SparkleUpdateController.self) private var sparkleUpdater
    @Environment(SettingsRouter.self) private var settingsRouter
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openURL) private var openURL

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            trigger
        }
        .buttonStyle(.plain)
        .padding(.horizontal, RapidTheme.Space.sm)
        .padding(.vertical, RapidTheme.Space.xs)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
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
                Text(experienceMode.mode.displayName)
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

            menuRowButton(
                title: "设置",
                systemImage: "gearshape",
                identifier: "Youzi.AccountMenu.Settings"
            ) {
                isPresented = false
                openWindow(id: "settings")
            }

            appearanceRow

            systemStatusRow

            menuRowButton(
                title: "检查更新",
                systemImage: "arrow.triangle.2.circlepath",
                identifier: "Youzi.AccountMenu.CheckForUpdates",
                action: checkForUpdates
            )

            menuRowButton(
                title: "帮助与反馈",
                systemImage: "questionmark.circle",
                identifier: "Youzi.AccountMenu.Help"
            ) {
                isPresented = false
                openURL(Self.helpURL)
            }

            Divider()

            Button {
                let next = experienceMode.mode.other
                isPresented = false
                experienceMode.mode = next
            } label: {
                Label(
                    "切换到\(experienceMode.mode.other.displayName)",
                    systemImage: "arrow.left.arrow.right"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(experienceMode.mode.other.accessibilityIdentifier)
        }
        .padding(RapidTheme.Space.md)
        .frame(width: 292, alignment: .leading)
    }

    private var identityHeader: some View {
        HStack(spacing: RapidTheme.Space.sm) {
            YouziLogo(size: 32)
            VStack(alignment: .leading, spacing: RapidTheme.Space.xxs) {
                Text("柚子")
                    .font(RapidFont.bodyEmphasis)
                Text(experienceMode.mode.displayName)
                    .font(RapidFont.caption)
                    .foregroundStyle(RapidTheme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("Youzi.AccountMenu.Identity")
    }

    private var appearanceRow: some View {
        @Bindable var appearance = appearance
        return HStack(spacing: RapidTheme.Space.sm) {
            Label("外观", systemImage: "circle.lefthalf.filled")
                .labelStyle(.titleAndIcon)
            Spacer(minLength: RapidTheme.Space.xs)
            Picker("外观", selection: $appearance.mode) {
                ForEach(AppearanceMode.accountMenuOrder) { mode in
                    Text(mode.shortDisplayName)
                        .tag(mode)
                        .accessibilityLabel(mode.displayName)
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
            Label("系统状态", systemImage: "heart.text.clipboard")
                .font(RapidFont.body)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: RapidTheme.Space.xs) {
                    ServerStatusPill(state: server.state)
                    CPUPill()
                    GPUPill()
                    MemoryPill()
                }
                VStack(alignment: .leading, spacing: RapidTheme.Space.xs) {
                    ServerStatusPill(state: server.state)
                    HStack(spacing: RapidTheme.Space.xs) {
                        CPUPill()
                        GPUPill()
                    }
                    MemoryPill()
                }
            }
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
