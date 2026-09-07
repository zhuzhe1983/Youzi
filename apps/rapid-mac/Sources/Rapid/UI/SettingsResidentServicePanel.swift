import SwiftUI

/// One model-management vocabulary in Service and each scenario tab. Default
/// choice, next-start intent and observed service state are independent.
struct SettingsResidentServicePanel: View {
    var slots: [YouziResidentServicePreference.Slot] = YouziResidentServicePreference.Slot.allCases
    var showsLaunchGuidance = true
    @Environment(ServerManager.self) private var server
    @Environment(YouziI18nConfig.self) private var i18n
    @AppStorage(YouziResidentServicePreference.enabledKey) private var enabled = false
    @State private var entries: [ModelEntry] = []
    @State private var loadingCatalog = false
    @State private var selectedSlot = YouziResidentServicePreference.Slot.chat

    private var slot: YouziResidentServicePreference.Slot {
        slots.contains(selectedSlot) ? selectedSlot : (slots.first ?? .chat)
    }

    var body: some View {
        SettingsSection(i18n.text(zh: "模型选择与启动", en: "Model selection & startup")) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(i18n.text(zh: "聊天服务启动后，自动加载启动清单", en: "Load the startup list after the chat service starts"), isOn: $enabled)
                    .accessibilityIdentifier("Settings.Models.Resident.Enabled")
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
                ResidentServiceSlotList(slot: slot, entries: entries).id(slot)
                HStack {
                    Button(i18n.text(zh: "立即加载启动清单", en: "Load startup list now")) {
                        Task { await server.restoreResidentServices(manually: true) }
                    }
                    .disabled(server.servingAlias == nil || server.isRestoringResidentServices || loadingCatalog)
                    .accessibilityIdentifier("Settings.Models.Resident.Load")
                    if server.isRestoringResidentServices || loadingCatalog { ProgressView().controlSize(.small) }
                    Spacer()
                    Button(i18n.text(zh: "刷新列表", en: "Refresh")) { Task { await refreshCatalog() } }
                        .disabled(loadingCatalog)
                        .accessibilityIdentifier("Settings.Models.Selection.Refresh")
                }
                Text(i18n.text(
                    zh: "默认：新任务或工作台未指定模型时使用。自动加载：加入下次聊天服务启动后的加载清单，不改变默认模型。选择立即保存，不会启动或卸载模型；立即加载无需开启自动加载开关。",
                    en: "Default is used for new tasks or workspaces without an explicit model. Auto-load adds a model to the next chat-service startup, without changing the default. Choices are saved immediately and never start or unload models; Load now works even with automatic loading off."
                )).font(RapidFont.caption).foregroundStyle(.secondary)
                if showsLaunchGuidance {
                    Text(i18n.text(zh: "打开客户端后自动加载，还需开启下方的“打开应用时自动启动聊天模型”。视频就绪表示服务可用，不代表权重持续驻留内存。", en: "To load on app launch, also enable chat auto-start below. Video ready means service availability, not permanent weight residency."))
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
    @State private var defaultAlias = ""
    @State private var query = ""

    private var choices: [ModelEntry] {
        entries.filter { slot.accepts($0) && (query.isEmpty || $0.alias.localizedCaseInsensitiveContains(query)) }
            .sorted { $0.alias.localizedStandardCompare($1.alias) == .orderedAscending }
    }
    private var unavailable: [String] {
        Set(selected + (defaultAlias.isEmpty ? [] : [defaultAlias])).filter { alias in
            !entries.contains { $0.alias == alias && slot.accepts($0) }
        }.sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField(i18n.text(zh: "搜索已下载模型", en: "Search downloaded models"), text: $query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("Settings.Models.Selection.Search.\(slot.rawValue)")
                Button(i18n.text(zh: "默认：自动", en: "Default: automatic")) {
                    defaults.removeObject(forKey: slot.defaultKey)
                    sync()
                }.disabled(defaultAlias.isEmpty)
                    .accessibilityIdentifier("Settings.Models.Selection.DefaultAutomatic.\(slot.rawValue)")
            }
            if !slot.allowsMultiple {
                Text(i18n.text(zh: "当前语音运行时每个场景仅支持一个已加载模型；多模型缓存尚未支持。默认模型与自动加载仍独立设置。", en: "The audio runtime currently supports one loaded model per scenario, not multiple cached engines. Default and auto-load remain independent."))
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
                        if defaultAlias == alias { defaults.removeObject(forKey: slot.defaultKey) }
                        sync()
                    }.accessibilityIdentifier("Settings.Models.Selection.Clear.\(alias)")
                }
            }
        }
        .onAppear { sync() }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in sync() }
    }

    private func row(_ entry: ModelEntry) -> some View {
        let ready = YouziScenarioModels.isReady(entry, in: server.residency)
        let loading = server.isResidentLoadInFlight(entry.alias)
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
                Button {
                    defaults.set(entry.alias, forKey: slot.defaultKey)
                    sync()
                } label: {
                    Label(i18n.text(zh: "默认", en: "Default"), systemImage: defaultAlias == entry.alias ? "star.fill" : "star")
                }.buttonStyle(.borderless)
                    .foregroundStyle(defaultAlias == entry.alias ? Color.accentColor : Color.secondary)
                    .accessibilityIdentifier("Settings.Models.Selection.Default.\(entry.alias)")
                    .accessibilityValue(defaultAlias == entry.alias ? i18n.text(zh: "已选择", en: "selected") : i18n.text(zh: "未选择", en: "not selected"))
                Toggle(i18n.text(zh: "自动加载", en: "Auto-load"), isOn: Binding(
                    get: { selected.contains(entry.alias) },
                    set: { checked in
                        let aliases = checked ? selected + [entry.alias] : selected.filter { $0 != entry.alias }
                        YouziResidentServicePreference.setAliases(aliases, for: slot, in: defaults)
                        sync()
                    }
                )).toggleStyle(.checkbox)
                    .disabled(!slot.allowsMultiple && !selected.isEmpty && !selected.contains(entry.alias))
                    .accessibilityIdentifier("Settings.Models.Resident.\(slot.rawValue).\(entry.alias)")
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
        defaultAlias = defaults.string(forKey: slot.defaultKey) ?? ""
    }
}
