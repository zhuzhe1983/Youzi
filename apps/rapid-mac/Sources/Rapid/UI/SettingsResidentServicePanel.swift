import SwiftUI

/// GUI defaults and local loading share one list. The optional external API
/// separately exposes all resident local models; it owns no model preference.
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
                ResidentServiceSlotList(slot: slot, entries: entries, settings: server.remoteModelSettings).id(slot)
                HStack {
                    if server.isRestoringResidentServices || loadingCatalog { ProgressView().controlSize(.small) }
                    Spacer()
                    Button(i18n.text(zh: "刷新列表", en: "Refresh")) { Task { await refreshCatalog() } }
                        .disabled(loadingCatalog)
                        .accessibilityIdentifier("Settings.Models.Selection.Refresh")
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
    @State var settings: RemoteModelSettings = .shared
    @Environment(ServerManager.self) private var server
    @Environment(YouziI18nConfig.self) private var i18n
    @State private var preferred: String?
    @State private var query = ""
    @State private var loadingAlias: String?
    @State private var error: String?
    @State private var editing: RemoteModelConfiguration?
    @State private var removing: RemoteModelConfiguration?

    private var remoteSlot: RemoteModelSlot { RemoteModelSlot(rawValue: slot.rawValue)! }
    private var remoteModels: [RemoteModelConfiguration] { settings.document.models.filter { $0.slot == remoteSlot } }
    private var allChoices: [ModelEntry] { entries.filter { slot.accepts($0) && !$0.isRemote } + remoteModels.map(\.entry) }
    private func remote(_ entry: ModelEntry) -> RemoteModelConfiguration? { remoteModels.first { $0.alias == entry.alias } }
    private func title(_ entry: ModelEntry) -> String { remote(entry)?.displayName ?? entry.alias }
    private var choices: [ModelEntry] {
        allChoices.filter { query.isEmpty || title($0).localizedCaseInsensitiveContains(query)
            || (remote($0)?.modelID ?? $0.alias).localizedCaseInsensitiveContains(query) }
            .sorted { lhs, rhs in
                if (lhs.alias == preferred) != (rhs.alias == preferred) { return lhs.alias == preferred }
                if lhs.isRemote != rhs.isRemote { return !lhs.isRemote }
                return title(lhs).localizedStandardCompare(title(rhs)) == .orderedAscending
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField(i18n.text(zh: "搜索本地或远程模型", en: "Search local or remote models"), text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("Settings.Models.Selection.Search.\(slot.rawValue)")
            if choices.isEmpty {
                Text(i18n.text(zh: "没有匹配的模型。可在“模型文件”中下载，或添加远程模型。", en: "No matching models. Download one in Model Files or add a remote model."))
                    .font(RapidFont.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(choices, id: \.alias) { entry in
                        row(entry)
                        Divider()
                    }
                }
            }.frame(height: CGFloat(min(5, choices.count)) * max(92, 92 * RapidFont.fontScale))
            if let preferred, !allChoices.contains(where: { $0.alias == preferred }) {
                HStack {
                    Text(i18n.text(zh: "优先模型暂不可用，请重新选择。", en: "The preferred model is unavailable. Choose another model."))
                        .font(RapidFont.caption).foregroundStyle(.orange)
                    Button(i18n.text(zh: "清除选择", en: "Clear selection")) {
                        perform { try settings.prefer(nil, for: remoteSlot); sync() }
                    }
                }
            }
            Button {
                var model = RemoteModelConfiguration(); model.slot = remoteSlot; editing = model
            } label: { Label(i18n.text(zh: "添加远程模型", en: "Add remote model"), systemImage: "plus") }
                .accessibilityIdentifier("Settings.Remote.Add.\(slot.kind.rawValue)")
            Text(i18n.text(
                zh: "每个场景只选一个优先模型，供柚子默认使用。本地优先模型会自动加载，其他本地模型可手动加载。切换优先模型不会卸载已经加载的模型，也不会改变进行中的任务。",
                en: "Choose one preferred model per workflow for Youzi to use by default. A preferred local model loads automatically; other local models can be loaded manually. Changing the preference does not unload models or change ongoing tasks."
            )).font(RapidFont.caption).foregroundStyle(.secondary)
            if let failure = error ?? settings.loadError { Text(failure).font(RapidFont.caption).foregroundStyle(.red) }
        }
        .onAppear { sync() }
        .onChange(of: settings.revision) { _, _ in sync() }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in sync() }
        .sheet(item: $editing) { model in RemoteModelEditor(model: model, settings: settings) }
        .confirmationDialog(i18n.text(zh: "移除远程模型配置和对应密钥？不会删除服务商的模型或文件。", en: "Remove this configuration and its key? Provider models and files are not deleted."), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button(i18n.text(zh: "移除", en: "Remove"), role: .destructive) {
                if let model = removing { perform { try settings.remove(model.id); sync() } }
                removing = nil
            }
        }
    }

    private func row(_ entry: ModelEntry) -> some View {
        let configuration = remote(entry)
        let ready = !entry.isRemote && YouziScenarioModels.isReady(entry, in: server.residency)
        let loading = loadingAlias == entry.alias || server.isResidentLoadInFlight(entry.alias)
        let failure = server.residentLoadFailures[entry.alias]
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Label(title(entry), systemImage: entry.isRemote ? "network" : "desktopcomputer")
                    .font(RapidFont.bodyEmphasis).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if entry.alias == preferred {
                    Label(i18n.text(zh: "优先", en: "Preferred"), systemImage: "checkmark.circle.fill")
                        .font(RapidFont.caption).foregroundStyle(Color.accentColor).fixedSize()
                        .accessibilityIdentifier("Settings.Models.Preferred.\(entry.alias)")
                } else {
                    Button(i18n.text(zh: configuration?.enabled == false ? "启用并设为优先" : "设为优先", en: configuration?.enabled == false ? "Enable and prefer" : "Make preferred")) {
                        perform { try settings.prefer(entry.alias, for: remoteSlot); sync() }
                        if preferred == entry.alias, !entry.isRemote, !ready {
                            Task { await load(entry) }
                        }
                    }.disabled(loadingAlias != nil)
                        .accessibilityIdentifier("Settings.Models.Prefer.\(entry.alias)")
                }
            }
            HStack(spacing: 10) {
                Text(entry.isRemote ? i18n.text(zh: "远程", en: "Remote") : i18n.text(zh: "本地", en: "Local"))
                    .font(RapidFont.caption).foregroundStyle(.secondary).fixedSize()
                if let configuration {
                    Text(configuration.modelID + " · " + (URL(string: configuration.baseURL)?.host ?? ""))
                        .font(RapidFont.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(i18n.text(zh: configuration.enabled ? "已配置" : "已停用", en: configuration.enabled ? "Configured" : "Disabled"))
                        .font(RapidFont.caption).foregroundStyle(.secondary).fixedSize()
                    Menu {
                        Button(i18n.text(zh: "编辑", en: "Edit")) { editing = configuration }
                        Button(i18n.text(zh: "移除配置…", en: "Remove configuration…"), role: .destructive) { removing = configuration }
                    } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).fixedSize()
                        .accessibilityLabel(i18n.text(zh: "远程模型操作", en: "Remote model actions"))
                } else {
                    Text(modelSize(entry)).font(RapidFont.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(loading ? i18n.text(zh: "加载中", en: "Loading") : failure != nil ? i18n.text(zh: "加载失败", en: "Failed") : ready ? i18n.text(zh: "已加载", en: "Loaded") : i18n.text(zh: "未加载", en: "Not loaded"))
                        .font(RapidFont.caption).foregroundStyle(failure != nil ? Color.red : ready ? Color.green : Color.secondary).fixedSize()
                    if !ready {
                        Button(i18n.text(zh: "加载", en: "Load")) { Task { await load(entry) } }
                            .disabled(loading || loadingAlias != nil)
                            .accessibilityIdentifier("Settings.Models.Selection.Load.\(entry.alias)")
                    }
                }
            }
            if let failure { Text(failure.message).font(RapidFont.caption).foregroundStyle(.red).lineLimit(2) }
        }.padding(.vertical, 12)
    }

    private func modelSize(_ entry: ModelEntry) -> String {
        let files = i18n.text(zh: "文件：", en: "Files: ") + (entry.sizeOnDisk ?? "—")
        guard let model = server.residency.models.first(where: { $0.matches(entry.alias) }), model.displayBytes > 0 else { return files }
        return files + i18n.text(zh: " · 内存：", en: " · RAM: ") + formatGigabytes(model.displayBytes)
    }

    private func sync() {
        preferred = YouziResidentServicePreference.preferredAlias(for: slot, in: defaults, remoteDocument: settings.document)
    }

    private func perform(_ action: () throws -> Void) {
        do { try action(); error = nil } catch { self.error = error.localizedDescription }
    }

    private func load(_ entry: ModelEntry) async {
        guard loadingAlias == nil else { return }
        loadingAlias = entry.alias; error = nil
        defer { loadingAlias = nil }
        let success = await server.loadModelManually(entry)
        if success { await server.refreshResidency() }
        else { error = server.residentLoadFailures[entry.alias]?.message ?? i18n.text(zh: "模型未能加载，请重试或查看日志。", en: "Could not load the model. Retry or check the logs.") }
    }
}
