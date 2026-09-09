import SwiftUI

/// A real popover, not an NSMenu header: native menus drop custom memory bars.
struct YouziScenarioModelPicker: View {
    @Binding var assistantAlias: String
    let chatEntries: [ModelEntry]
    var chatIsStreaming = false
    @Environment(ServerManager.self) private var server
    @Environment(AudioViewModel.self) private var audio
    @Environment(ImageGenViewModel.self) private var images
    @Environment(VideoGenViewModel.self) private var videos
    @Environment(DownloadManager.self) private var downloads
    @Environment(YouziI18nConfig.self) private var i18n
    @Environment(YouziFontSizeConfig.self) private var fonts
    @Environment(SettingsRouter.self) private var router: SettingsRouter?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    @State private var remoteHealth = YouziRemoteModelAvailability()
    @State private var probeRefresh = 0
    @State private var residencyVerified = false
    @State private var residencyCheckedAt: Date?
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

    private var selections: [RemoteModelSlot: String] {
        let explicit: [RemoteModelSlot: String] = [.chat: assistantAlias,
            .speech: audio.selectedSpeechAlias, .transcription: audio.selectedTranscriptionAlias,
            .image: images.selectedAlias, .video: videos.selectedAlias]
        return explicit.merging(Dictionary(uniqueKeysWithValues: RemoteModelSlot.allCases.compactMap { slot in
            guard explicit[slot, default: ""].isEmpty,
                  let localSlot = YouziResidentServicePreference.Slot(rawValue: slot.rawValue),
                  let alias = server.automaticModelAlias(for: localSlot, entries: entries) else { return nil }
            return (slot, alias)
        })) { _, automatic in automatic }
    }

    private var localReachable: Bool {
        guard case .ready = server.state, residencyVerified, let residencyCheckedAt else { return false }
        return Date.now.timeIntervalSince(residencyCheckedAt) < 15
    }
    private var readySlots: Set<RemoteModelSlot> {
        let settings = RemoteModelSettings.shared
        let online = Set(settings.document.models.filter {
            $0.enabled && remoteHealth.status($0.alias, revision: settings.revision) == .online
        }.map(\.alias))
        return YouziModelAvailability.readySlots(selections: selections, entries: entries,
            residency: server.residency, localReachable: localReachable, remoteOnline: online)
    }
    private var availabilityDescription: String {
        let available = RemoteModelSlot.allCases.filter { readySlots.contains($0) }
            .map { $0.title(chinese: i18n.isChinese) }.joined(separator: " / ")
        return available.isEmpty ? i18n.text(zh: "当前默认模型尚未就绪", en: "No selected model is ready")
            : i18n.text(zh: "可用：", en: "Available: ") + available
    }
    private var probeAliases: [String] {
        let selected = selections.values.filter(RemoteModelEndpoint.isRemote)
        let visible = presented ? RemoteModelSettings.shared.entries(kind: selectedKind).map(\.alias) : []
        return Array(Set(selected + visible)).sorted()
    }
    private struct ProbeKey: Equatable {
        var aliases: [String]
        var revision: Int
        var active: Bool
        var refresh: Int
    }

    var body: some View {
        Button { presented.toggle() } label: {
            YouziModelAvailabilityOrb(lanes: YouziModelAvailability.lanes(for: readySlots))
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(i18n.text(zh: "模型选择 · ", en: "Model selection · ") + availabilityDescription)
        .accessibilityLabel(i18n.text(zh: "模型选择", en: "Model selection"))
        .accessibilityValue(availabilityDescription)
        .accessibilityIdentifier("YouziSimple.NewTask.ModelSelector")
        .popover(isPresented: $presented, arrowEdge: .top) { panel }
        .task(id: ModelPickerBar.PickerCatalogKey(binaryPath: server.binaryPath, cacheGeneration: downloads.cacheGeneration, refreshEnabled: true)) { await refresh() }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                residencyVerified = await server.refreshResidency()
                residencyCheckedAt = .now
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
        .task(id: ProbeKey(aliases: probeAliases, revision: RemoteModelSettings.shared.revision, active: scenePhase == .active, refresh: probeRefresh)) {
            guard scenePhase == .active, !probeAliases.isEmpty else { return }
            let aliases = probeAliases
            var force = probeRefresh > 0
            while !Task.isCancelled {
                await remoteHealth.refresh(aliases: aliases, settings: .shared, force: force)
                force = false
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            YouziScenarioModelToolbar(selectedKind: $selectedKind, moreModelSettings: openModelSettings)
            if loading {
                HStack { ProgressView().controlSize(.small); Text(i18n.text(zh: "正在读取已下载模型…", en: "Reading downloaded models…")) }
                    .font(RapidFont.caption)
            }
            if let error { Text(error).font(RapidFont.caption).foregroundStyle(.orange) }
            ScrollView {
                LazyVStack(spacing: 4) {
                    let choices = entries.filter { $0.kind == selectedKind && $0.cached && !$0.isRemote }
                    let remotes = RemoteModelSettings.shared.entries(kind: selectedKind)
                    if choices.isEmpty && remotes.isEmpty && !loading && error == nil {
                        Text(i18n.text(zh: "暂无可选模型", en: "No models available"))
                            .font(RapidFont.secondary).foregroundStyle(.secondary).padding(.vertical, 16)
                    }
                    ForEach(choices) { entry in modelRow(entry) }
                    ForEach(remotes) { entry in remoteRow(entry) }
                }
            }.frame(maxHeight: 240)
            YouziScenarioModelMemoryFooter(occupancy: occupancy, refreshing: loading) {
                probeRefresh += 1
                Task { await refresh() }
            }
        }
        .padding(16).frame(width: YouziScenarioModelToolbar.panelWidth(scale: fonts.scale))
    }

    private var laneBusy: Bool {
        switch selectedKind {
        case .chat: chatIsStreaming
        case .audio: audio.isBusy
        case .image: images.isGenerating
        case .video: !videos.canSwitchModels
        }
    }

    private func select(_ alias: String, slot: RemoteModelSlot) {
        switch slot {
        case .chat: assistantAlias = alias
        case .transcription: audio.selectedTranscriptionAlias = alias
        case .speech: audio.selectSpeechModel(alias)
        case .image: images.selectedAlias = alias
        case .video: videos.selectModel(alias)
        }
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

    private func isSelected(_ entry: ModelEntry) -> Bool {
        guard let slot = YouziModelAvailability.slot(for: entry) else { return false }
        return selections[slot] == entry.alias
    }

    private func remoteRow(_ entry: ModelEntry) -> some View {
        Button {
            if let slot = YouziModelAvailability.slot(for: entry) { select(entry.alias, slot: slot) }
            presented = false
        } label: {
            YouziScenarioModelRow(title: RemoteModelSettings.shared.document.model(alias: entry.alias)?.displayName ?? entry.alias,
                remoteStatus: remoteHealth.status(entry.alias, revision: RemoteModelSettings.shared.revision), selected: isSelected(entry))
        }
        .buttonStyle(.plain).disabled(laneBusy || loadingAlias != nil)
        .accessibilityIdentifier("Youzi.ScenarioModels.\(entry.alias)")
    }

    private func modelRow(_ entry: ModelEntry) -> some View {
        let ready = localReachable && YouziScenarioModels.isReady(entry, in: server.residency)
        return Button {
            Task {
                loadingAlias = entry.alias
                defer { loadingAlias = nil }
                let success: Bool
                if ready { success = true }
                else if server.servingAlias != nil { success = await server.loadStartupModel(entry) }
                else if entry.kind == .chat { success = await server.ensureServing(alias: entry.alias, hfPath: entry.hfRepo) }
                else { success = false }
                if success, let slot = YouziModelAvailability.slot(for: entry) {
                    // Video selection validates against its own catalog; populate it before selecting.
                    if slot == .video && !videos.videoModels.contains(where: { $0.alias == entry.alias }) { await videos.refreshCatalog() }
                    select(entry.alias, slot: slot)
                    error = nil
                    residencyVerified = await server.refreshResidency()
                    residencyCheckedAt = .now
                } else {
                    error = i18n.text(zh: "模型未能启动，请在模型设置中查看详情。", en: "Model could not start. See model settings for details.")
                }
            }
        } label: {
            YouziScenarioModelRow(title: entry.alias, detail: memoryLabel(entry), resident: ready,
                selected: isSelected(entry), loading: loadingAlias == entry.alias)
        }
        .buttonStyle(.plain).disabled(laneBusy || loadingAlias != nil)
        .accessibilityIdentifier("Youzi.ScenarioModels.\(entry.alias)")
    }

    private func memoryLabel(_ entry: ModelEntry) -> String {
        if localReachable, YouziScenarioModels.isReady(entry, in: server.residency),
           let resident = server.residency.models.first(where: { $0.matches(entry.alias) || entry.hfRepo.map($0.matches) == true }), resident.displayBytes > 0 {
            return formatGigabytes(resident.displayBytes)
        }
        if localReachable && entry.kind == .audio && YouziScenarioModels.isReady(entry, in: server.residency) { return "—" }
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
        residencyVerified = await server.refreshResidency()
        residencyCheckedAt = .now
    }
}

/// Keep memory and refresh below the models, outside the scrolling list.
struct YouziScenarioModelMemoryFooter: View {
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
            Button(i18n.text(zh: "模型设置", en: "Model settings"), action: moreModelSettings)
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
