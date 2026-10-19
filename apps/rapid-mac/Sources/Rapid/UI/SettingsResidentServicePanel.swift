import SwiftUI

/// One pool for startup and automatic routing; readiness remains observed state.
struct SettingsResidentServicePanel: View {
    var slots: [YouziResidentServicePreference.Slot] = YouziResidentServicePreference.Slot.allCases
    var showsLaunchGuidance = true
    @Environment(ServerManager.self) private var server
    @Environment(YouziI18nConfig.self) private var i18n
    @State private var entries: [ModelEntry] = []
    @State private var loadingCatalog = false
    @State private var selectedSlot = YouziResidentServicePreference.Slot.chat

    private var slot: YouziResidentServicePreference.Slot {
        slots.contains(selectedSlot) ? selectedSlot : (slots.first ?? .chat)
    }

    var body: some View {
        SettingsSection(i18n.text(zh: "可用模型", en: "Available models")) {
            VStack(alignment: .leading, spacing: 12) {
                if slots.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(slots) { item in
                                Button { selectedSlot = item } label: {
                                    Text(item.title(isChinese: i18n.isChinese))
                                        .font(RapidFont.bodyEmphasis).fixedSize()
                                        .padding(.horizontal, 10).padding(.vertical, 7)
                                        .foregroundStyle(slot == item ? Color.accentColor : .secondary)
                                        .background(slot == item ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                }.buttonStyle(.plain)
                                    .accessibilityIdentifier("Settings.Models.Selection.Tab.\(item.rawValue)")
                                    .accessibilityAddTraits(slot == item ? .isSelected : [])
                            }
                        }
                    }
                }
                Text(i18n.text(zh: "本地模型", en: "Local models")).font(RapidFont.bodyEmphasis)
                ResidentServiceSlotList(slot: slot, entries: entries).id(slot)
                HStack {
                    if server.isRestoringResidentServices || loadingCatalog { ProgressView().controlSize(.small) }
                    Spacer()
                    Button(i18n.text(zh: "刷新列表", en: "Refresh")) { Task { await refreshCatalog() } }
                        .disabled(loadingCatalog)
                        .accessibilityIdentifier("Settings.Models.Selection.Refresh")
                }
                Text(i18n.text(
                    zh: "自动加载：每次打开 Youzi 时加载。手动加载：点击模型旁的“加载”后使用。修改策略不会立即卸载已加载模型；策略即时保存，下次启动生效。对外 API 只提供已加载的本地模型。",
                    en: "Automatic models load when Youzi opens. Manual models load when you click Load. Changing the policy never unloads a running model. Policies are saved immediately and apply at the next launch. The external API only serves loaded local models."
                )).font(RapidFont.caption).foregroundStyle(.secondary)
                SettingsRemoteModelsPanel(kind: RemoteModelSlot(rawValue: slot.rawValue)?.kind, slot: RemoteModelSlot(rawValue: slot.rawValue))
                if showsLaunchGuidance {
                    Text(i18n.text(zh: "视频就绪表示服务可用，不代表权重持续驻留内存。", en: "Video ready means service availability, not permanent weight residency."))
                        .font(RapidFont.caption).foregroundStyle(.secondary)
                }
            }.padding(16)
        }
        .task(id: server.binaryPath) { await refreshCatalog() }
    }

    private func refreshCatalog() async {
        guard !loadingCatalog, let binary = server.binaryPath else { return }
        loadingCatalog = true
        defer { loadingCatalog = false }
        entries = await server.residentServiceCatalogProvider(binary)
        await server.refreshResidency()
    }
}

struct ResidentServiceSlotList: View {
    var defaults: UserDefaults = .standard
    let slot: YouziResidentServicePreference.Slot
    let entries: [ModelEntry]
    @Environment(ServerManager.self) private var server
    @Environment(YouziI18nConfig.self) private var i18n
    @State private var selected: [String] = []
    @State private var query = ""
    @State private var loadingAlias: String?
    @State private var loadError: String?

    private var choices: [ModelEntry] {
        entries.filter { slot.accepts($0) && (query.isEmpty || $0.alias.localizedCaseInsensitiveContains(query)) }
            .sorted { lhs, rhs in
                let left = selected.firstIndex(of: lhs.alias) ?? Int.max
                let right = selected.firstIndex(of: rhs.alias) ?? Int.max
                if left != right { return left < right }
                return lhs.alias.localizedStandardCompare(rhs.alias) == .orderedAscending
            }
    }
    private var unavailable: [String] {
        selected.filter { alias in
            !entries.contains { $0.alias == alias && slot.accepts($0) }
        }.sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField(i18n.text(zh: "搜索已下载模型", en: "Search downloaded models"), text: $query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("Settings.Models.Selection.Search.\(slot.rawValue)")

            }
            if !slot.allowsMultiple {
                Text(i18n.text(zh: "语音识别与语音合成各支持一个已加载模型；每个场景只能选一个自动加载模型。其他模型可手动加载，切换时需先明确卸载原模型。", en: "Transcription and speech each support one loaded model and one automatic selection. Other models can be loaded manually; switching requires explicitly unloading the occupied lane."))
                    .font(RapidFont.caption).foregroundStyle(.secondary)
            }
            if selected.isEmpty {
                Text(i18n.text(zh: "当前没有自动加载模型。可将模型设为“自动加载”，或点击“加载”手动启动。", en: "No automatic models. Choose Automatic for launch-time loading, or click Load to start a model manually."))
                    .font(RapidFont.caption).foregroundStyle(.secondary)
            }
            if choices.isEmpty {
                Text(i18n.text(zh: "没有匹配的已下载模型，请刷新或前往“模型文件”管理。", en: "No matching downloaded models. Refresh or manage Model Files."))
                    .font(RapidFont.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(choices, id: \.alias) { entry in row(entry) }
                }
            }.frame(height: CGFloat(min(5, choices.count)) * max(62, 62 * RapidFont.fontScale))
            ForEach(unavailable, id: \.self) { alias in
                HStack {
                    Text(alias + i18n.text(zh: "（不可用，已保留选择）", en: " (unavailable; selection retained)"))
                        .font(RapidFont.caption).foregroundStyle(.orange)
                    Spacer()
                    Button(i18n.text(zh: "移除选择", en: "Clear selection")) {
                        YouziResidentServicePreference.setAliases(selected.filter { $0 != alias }, for: slot, in: defaults)
                        sync()
                    }.accessibilityIdentifier("Settings.Models.Selection.Clear.\(alias)")
                }
            }
            if let loadError { Text(loadError).font(RapidFont.caption).foregroundStyle(.red) }
        }
        .onAppear { sync() }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in sync() }
    }

    private func row(_ entry: ModelEntry) -> some View {
        let ready = YouziScenarioModels.isReady(entry, in: server.residency)
        let loading = loadingAlias == entry.alias || server.isResidentLoadInFlight(entry.alias)
        let failure = server.residentLoadFailures[entry.alias]
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.alias).font(RapidFont.secondary).lineLimit(1).truncationMode(.middle)
                    Text(modelSize(entry))
                        .font(RapidFont.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(loading ? i18n.text(zh: "加载中", en: "Loading") : failure != nil ? i18n.text(zh: "加载失败", en: "Failed") : ready ? i18n.text(zh: "已就绪", en: "Ready") : i18n.text(zh: "未加载", en: "Not loaded"))
                    .font(RapidFont.caption).foregroundStyle(failure != nil ? Color.red : ready ? Color.green : Color.secondary)
                if selected.count > 1, let index = selected.firstIndex(of: entry.alias) {
                    Button {
                        YouziResidentServicePreference.promote(entry.alias, for: slot, in: defaults)
                        sync()
                    } label: {
                        Text("#\(index + 1)").monospacedDigit()
                    }.buttonStyle(.borderless).disabled(index == 0)
                        .help(i18n.text(zh: "设为优先使用的模型；已就绪模型仍优先复用", en: "Move first in the pool; ready models are still reused first"))
                        .accessibilityLabel(i18n.text(zh: "提升优先级", en: "Move first"))
                        .accessibilityIdentifier("Settings.Models.Selection.Priority.\(entry.alias)")
                }
                Picker(i18n.text(zh: "加载策略", en: "Loading policy"), selection: Binding(
                    get: { selected.contains(entry.alias) ? YouziResidentServicePreference.LoadingPolicy.automatic : .onDemand },
                    set: { policy in
                        YouziResidentServicePreference.setLoadingPolicy(policy, for: entry.alias, slot: slot, in: defaults)
                        sync()
                    }
                )) {
                    Text(i18n.text(zh: "手动加载", en: "Manual"))
                        .tag(YouziResidentServicePreference.LoadingPolicy.onDemand)
                    Text(i18n.text(zh: "自动加载", en: "Automatic"))
                        .tag(YouziResidentServicePreference.LoadingPolicy.automatic)
                }.pickerStyle(.menu).labelsHidden().frame(width: 115)
                    .accessibilityIdentifier("Settings.Models.Resident.\(slot.rawValue).\(entry.alias)")
                if !ready {
                    Button(i18n.text(zh: loading ? "加载中" : "加载", en: loading ? "Loading" : "Load")) {
                        Task { await load(entry) }
                    }.disabled(loading || loadingAlias != nil)
                        .accessibilityIdentifier("Settings.Models.Selection.Load.\(entry.alias)")
                }
            }
            if let failure { Text(failure.message).font(RapidFont.caption).foregroundStyle(.red).lineLimit(2) }
        }.font(RapidFont.secondary).padding(.vertical, 5)
    }

    private func modelSize(_ entry: ModelEntry) -> String {
        let files = i18n.text(zh: "文件：", en: "Files: ") + (entry.sizeOnDisk ?? "—")
        guard let model = server.residency.models.first(where: { $0.matches(entry.alias) }), model.displayBytes > 0 else { return files }
        return files + i18n.text(zh: " · 内存估算：", en: " · Memory estimate: ") + formatGigabytes(model.displayBytes)
    }

    private func sync() {
        selected = YouziResidentServicePreference.aliases(for: slot, in: defaults)
    }

    private func load(_ entry: ModelEntry) async {
        guard loadingAlias == nil else { return }
        loadingAlias = entry.alias; loadError = nil
        defer { loadingAlias = nil }
        let success = await server.loadModelManually(entry)
        if success { await server.refreshResidency() }
        else {
            loadError = server.residentLoadFailures[entry.alias]?.message
                ?? i18n.text(zh: "模型未能加载，请检查服务日志。", en: "Could not load the model. Check the service logs.")
        }
    }
}
