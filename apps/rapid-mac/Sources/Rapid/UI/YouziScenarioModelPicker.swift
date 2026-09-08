import SwiftUI

/// A real popover, not an NSMenu header: native menus drop custom memory bars.
struct YouziScenarioModelPicker: View {
    @Binding var assistantAlias: String
    let chatEntries: [ModelEntry]
    @Environment(ServerManager.self) private var server
    @Environment(DownloadManager.self) private var downloads
    @Environment(YouziI18nConfig.self) private var i18n
    @Environment(YouziFontSizeConfig.self) private var fonts
    @Environment(SettingsRouter.self) private var router: SettingsRouter?
    @Environment(\.openWindow) private var openWindow
    @State private var presented = false
    @State private var media: [ModelEntry] = []
    @State private var loading = true
    @State private var error: String?
    @State private var selectedKind = ModelKind.chat
    @State private var loadingAlias: String?

    private var entries: [ModelEntry] { YouziScenarioModels.merge(chat: chatEntries, media: media) }
    private var occupancy: YouziModelOccupancy {
        YouziModelOccupancy.resolve(residency: server.residency, host: MemoryProbe.snapshot(), voiceLaneResident: false)
    }

    var body: some View {
        Button { presented.toggle() } label: {
            HStack(spacing: 4) {
                ForEach(YouziModelLane.allCases) { lane in
                    Circle().fill(lane.occupancyColor).frame(width: 5, height: 5)
                }
                Text(assistantAlias.isEmpty ? i18n.text(zh: "选择模型", en: "Select model") : assistantAlias)
                    .font(RapidFont.caption).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9))
            }
            .foregroundStyle(RapidTheme.textSecondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RapidTheme.surfaceCanvas, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("YouziSimple.NewTask.ModelSelector")
        .popover(isPresented: $presented, arrowEdge: .top) { panel }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            YouziScenarioModelMemoryHeader(occupancy: occupancy, refreshing: loading) {
                Task { await refresh() }
            }
            YouziScenarioModelToolbar(selectedKind: $selectedKind, moreModelSettings: openModelSettings)
            if loading {
                HStack { ProgressView().controlSize(.small); Text(i18n.text(zh: "正在读取已下载模型…", en: "Reading downloaded models…")) }
                    .font(RapidFont.caption)
            }
            if let error { Text(error).font(RapidFont.caption).foregroundStyle(.orange) }
            ScrollView {
                LazyVStack(spacing: 4) {
                    let choices = entries.filter { $0.kind == selectedKind && $0.cached }
                    if choices.isEmpty && !loading && error == nil {
                        Text(i18n.text(zh: "暂无已下载模型", en: "No downloaded models"))
                            .font(RapidFont.secondary).foregroundStyle(.secondary).padding(.vertical, 16)
                    }
                    ForEach(choices) { entry in modelRow(entry) }
                }
            }.frame(maxHeight: 240)
        }
        .padding(16).frame(width: YouziScenarioModelToolbar.panelWidth(scale: fonts.scale))
        .task(id: ModelPickerBar.PickerCatalogKey(binaryPath: server.binaryPath, cacheGeneration: downloads.cacheGeneration, refreshEnabled: true)) { await refresh() }
    }

    private func openModelSettings() {
        presented = false
        let tab: ModelSettingsTab = switch selectedKind {
        case .chat: .chat
        case .audio: .audio
        case .image: .image
        case .video: .video
        }
        if let router { router.route(toModelTab: tab) { openWindow(id: "settings") } }
        else { openWindow(id: "settings") }
    }

    private func modelRow(_ entry: ModelEntry) -> some View {
        let ready = YouziScenarioModels.isReady(entry, in: server.residency)
        return Button {
            Task {
                loadingAlias = entry.alias
                defer { loadingAlias = nil }
                let success: Bool
                if ready { success = true }
                else if server.servingAlias != nil { success = await server.loadStartupModel(entry) }
                else if entry.kind == .chat { success = await server.ensureServing(alias: entry.alias, hfPath: entry.hfRepo) }
                else { success = false }
                if success && entry.kind == .chat { assistantAlias = entry.alias }
                if !success { error = i18n.text(zh: "模型未能启动，请在模型设置中查看详情。", en: "Model could not start. See model settings for details.") }
            }
        } label: {
            HStack(spacing: 8) {
                Text(entry.alias).font(RapidFont.secondary).lineLimit(1).truncationMode(.middle)
                if YouziResidentServicePreference.Slot.allCases.contains(where: {
                    YouziResidentServicePreference.aliases(for: $0).contains(entry.alias)
                }) {
                    Image(systemName: "bolt.fill").font(RapidFont.caption).foregroundStyle(.orange)
                        .accessibilityLabel(i18n.text(zh: "自动加载优选模型", en: "Automatic preferred model"))
                }
                Spacer(minLength: 4)
                Text(memoryLabel(entry)).font(RapidFont.caption).foregroundStyle(.secondary)
                if loadingAlias == entry.alias { ProgressView().controlSize(.mini) }
                else if ready { Image(systemName: "checkmark").foregroundStyle(.green) }
            }.padding(8).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(loadingAlias != nil)
        .accessibilityIdentifier("Youzi.ScenarioModels.\(entry.alias)")
        .accessibilityValue(ready ? i18n.text(zh: "已加载", en: "Loaded") : i18n.text(zh: "已下载，未加载", en: "Downloaded, not loaded"))
    }

    private func memoryLabel(_ entry: ModelEntry) -> String {
        if let resident = server.residency.models.first(where: { $0.matches(entry.alias) }), resident.displayBytes > 0 {
            return formatGigabytes(resident.displayBytes)
        }
        if entry.kind == .audio && YouziScenarioModels.isReady(entry, in: server.residency) { return "—" }
        return entry.sizeOnDisk.map { i18n.text(zh: "磁盘 ", en: "Disk ") + $0 } ?? "—"
    }

    private func refresh() async {
        loading = true
        defer { loading = false }
        guard let binary = server.binaryPath else {
            error = i18n.text(zh: "运行时尚未就绪，稍后请刷新。", en: "Runtime is not ready. Refresh shortly.")
            return
        }
        guard let result = await ModelCatalog.scenarioMediaEntries(binary: binary), !Task.isCancelled else {
            error = i18n.text(zh: "读取模型目录失败，请重试。", en: "Could not read the model catalog. Retry.")
            return
        }
        media = result
        error = nil
        await server.refreshResidency()
    }
}

/// Memory and refresh share the top row; no empty title row above the bar.
struct YouziScenarioModelMemoryHeader: View {
    let occupancy: YouziModelOccupancy
    let refreshing: Bool
    var refresh: () -> Void
    @Environment(YouziI18nConfig.self) private var i18n

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            YouziModelOccupancyBar(occupancy: occupancy)
                .accessibilityIdentifier("Youzi.ScenarioModels.Memory")
            Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain).disabled(refreshing)
                .accessibilityLabel(i18n.text(zh: "刷新模型", en: "Refresh models"))
                .accessibilityIdentifier("YouziScenarioModelPicker.Button.389a1e56c3")
        }
    }
}

/// Keep the settings entry beside the scenario tabs, including at large text sizes.
/// Stateless presentation also permits rendering without starting a model service.
struct YouziScenarioModelToolbar: View {
    @Binding var selectedKind: ModelKind
    var moreModelSettings: () -> Void
    @Environment(YouziI18nConfig.self) private var i18n
    @Environment(YouziFontSizeConfig.self) private var fonts

    static func panelWidth(scale: CGFloat) -> CGFloat { 440 * max(1, scale) }

    var body: some View {
        HStack(spacing: 12) {
            Picker(i18n.text(zh: "场景", en: "Scenario"), selection: $selectedKind) {
                ForEach(ModelKind.allCases) { kind in
                    Text(title(kind)).tag(kind)
                }
            }.pickerStyle(.segmented).labelsHidden().fixedSize()
                .accessibilityIdentifier("YouziScenarioModelPicker.Picker.fa4bba6e5b")
            Spacer(minLength: 0)
            Button(i18n.text(zh: "更多模型设置…", en: "More model settings…"), action: moreModelSettings)
                .buttonStyle(.plain).font(fonts.font(12.5)).foregroundStyle(RapidTheme.brand)
                .lineLimit(1).fixedSize()
                .accessibilityIdentifier("YouziScenarioModelPicker.Button.d87486a311")
        }
        .accessibilityIdentifier("YouziScenarioModelPicker.ScenarioToolbar")
    }

    private func title(_ kind: ModelKind) -> String {
        switch kind {
        case .chat: i18n.text(zh: "聊天", en: "Chat")
        case .image: i18n.text(zh: "图片", en: "Image")
        case .audio: i18n.text(zh: "语音", en: "Audio")
        case .video: i18n.text(zh: "视频", en: "Video")
        }
    }
}
