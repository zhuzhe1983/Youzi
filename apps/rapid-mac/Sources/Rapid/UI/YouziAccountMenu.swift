import SwiftUI

/// Shared account affordance for Simple and Professional Mode.
///
/// This is presentation chrome only: it must never create or restart a model,
/// conversation, store, or connector. Mode switching writes the persisted
/// experience preference; `ContentView` is the only place that branches on it.
struct YouziAccountMenu: View {
    var catalogEntries: [ModelEntry] = []
    var arrowEdge: Edge = .bottom

    @Environment(YouziExperienceModeConfig.self) private var experienceMode
    @Environment(AppearanceConfig.self) private var appearance
    @Environment(ServerManager.self) private var server
    @Environment(UpdateChecker.self) private var updater
    @Environment(SparkleUpdateController.self) private var sparkleUpdater
    @Environment(SettingsRouter.self) private var settingsRouter
    @Environment(YouziI18nConfig.self) private var i18n
    @Environment(YouziFontSizeConfig.self) private var fonts
    @Environment(\.openWindow) private var openWindow

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
            YouziAccountMenuTrigger(mode: experienceMode.mode, isChinese: i18n.isChinese, scale: fonts.scale)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, RapidTheme.Space.sm)
        .padding(.vertical, RapidTheme.Space.xs)
        .popover(isPresented: $isPresented, arrowEdge: arrowEdge) {
            menuBody
        }
        .accessibilityIdentifier("Youzi.AccountMenu")
        .accessibilityLabel(i18n.text(zh: "柚子菜单", en: "Youzi menu"))
        .accessibilityValue(experienceMode.mode.localizedDisplayName(isChinese: i18n.isChinese))
    }

    private var menuBody: some View {
        @Bindable var appearance = appearance
        return YouziAccountMenuContent(
            mode: Binding(
                get: { experienceMode.mode },
                set: { next in
                    guard next != experienceMode.mode else { return }
                    // Close before swapping shells. This changes presentation only;
                    // the app-owned chat, models and settings stay in place.
                    isPresented = false
                    experienceMode.mode = next
                }
            ),
            appearance: $appearance.mode,
            isChinese: i18n.isChinese,
            scale: fonts.scale,
            openSettings: {
                isPresented = false
                openWindow(id: "settings")
            },
            checkForUpdates: checkForUpdates
        ) {
            systemStatusRow
        }
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
