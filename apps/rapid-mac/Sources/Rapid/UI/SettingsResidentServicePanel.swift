import SwiftUI

/// The resident set is explicit and downloaded-only; it is not the download catalog.
struct SettingsResidentServicePanel: View {
    @Environment(ServerManager.self) private var server
    @Environment(YouziI18nConfig.self) private var i18n
    @AppStorage(YouziResidentServicePreference.enabledKey) private var enabled = false
    @State private var entries: [ModelEntry] = []
    @State private var loadingCatalog = false

    var body: some View {
        SettingsSection(i18n.text(zh: "多模型常驻服务", en: "Resident model services")) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(i18n.text(zh: "聊天服务启动后恢复常驻模型", en: "Restore resident models when chat starts"), isOn: $enabled)
                    .accessibilityIdentifier("Settings.Models.Resident.Enabled")
                LabeledContent(i18n.text(zh: "聊天", en: "Chat"), value: server.servingAlias ?? i18n.text(zh: "尚未启动", en: "Not started"))
                ForEach(YouziResidentServicePreference.Slot.allCases) { slot in
                    ResidentServiceSlotRow(slot: slot, entries: entries)
                }
                HStack {
                    Button(i18n.text(zh: "加载常驻模型", en: "Load resident set")) {
                        Task { await server.restoreResidentServices() }
                    }
                    .disabled(!enabled || server.servingAlias == nil || server.isRestoringResidentServices || loadingCatalog)
                    .accessibilityIdentifier("Settings.Models.Resident.Load")
                    if server.isRestoringResidentServices { ProgressView().controlSize(.small) }
                    Spacer()
                    Button(i18n.text(zh: "刷新列表", en: "Refresh")) { Task { await refreshCatalog() } }
                        .disabled(loadingCatalog)
                }
                Text(i18n.text(
                    zh: "仅选择已下载的模型，共用服务地址和鉴权。聊天模型沿用当前选择；配合下方自动启动，可在打开应用后恢复整组服务。关闭此开关或取消选择不会卸载已运行的模型。内存不足会提示，不会退出聊天；视频暂不支持常驻。",
                    en: "Choose downloaded models sharing one endpoint and key. Chat uses the current selection; enable auto-start below to restore the set on launch. Disabling restore or clearing a selection does not unload running models. Memory failures do not stop chat. Video residency is not supported yet."
                ))
                .font(RapidFont.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: server.binaryPath) { await refreshCatalog() }
    }

    private func refreshCatalog() async {
        guard !loadingCatalog, let binary = server.binaryPath else { return }
        loadingCatalog = true
        defer { loadingCatalog = false }
        async let audio = ModelCatalog.audioEntries(binary: binary)
        async let images = ModelCatalog.imageEntries(binary: binary)
        entries = (await audio) + (await images)
        await server.refreshResidency()
    }
}

private struct ResidentServiceSlotRow: View {
    let slot: YouziResidentServicePreference.Slot
    let entries: [ModelEntry]
    @Environment(ServerManager.self) private var server
    @Environment(YouziI18nConfig.self) private var i18n
    @AppStorage private var alias: String

    init(slot: YouziResidentServicePreference.Slot, entries: [ModelEntry]) {
        self.slot = slot
        self.entries = entries
        _alias = AppStorage(wrappedValue: "", slot.key)
    }

    private var choices: [ModelEntry] {
        entries.filter { slot.accepts($0) }.sorted { $0.alias.localizedStandardCompare($1.alias) == .orderedAscending }
    }

    private var resident: Bool {
        if slot == .image { return server.isModelResident(alias) }
        return server.isVoiceLaneResident(for: alias, modelPath: entries.first { $0.alias == alias }?.hfRepo)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Picker(slot.title(isChinese: i18n.isChinese), selection: $alias) {
                    Text(i18n.text(zh: "不自动加载", en: "Do not preload")).tag("")
                    if !alias.isEmpty && !choices.contains(where: { $0.alias == alias }) {
                        Text(alias + i18n.text(zh: "（不可用）", en: " (unavailable)")).tag(alias)
                    }
                    ForEach(choices, id: \.alias) { entry in
                        Text(entry.alias + (entry.sizeOnDisk.map { " · \($0)" } ?? "")).tag(entry.alias)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("Settings.Models.Resident.\(slot.rawValue)")
                if !alias.isEmpty {
                    Text(status).font(RapidFont.caption)
                        .foregroundStyle(resident ? Color.green : Color.secondary)
                        .fixedSize()
                }
            }
            if let failure = server.residentLoadFailures[alias] {
                Text(failure.message).font(RapidFont.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
    }

    private var status: String {
        if server.isResidentLoadInFlight(alias) { return i18n.text(zh: "加载中", en: "Loading") }
        if server.residentLoadFailures[alias] != nil { return i18n.text(zh: "加载失败", en: "Failed") }
        let path = entries.first { $0.alias == alias }?.hfRepo
        let audioBusy = path.map { modelPath in
            server.residency.audioLanes.contains { $0.model == modelPath && $0.state == "busy" }
        } ?? false
        let modelBusy = server.residency.models.contains { $0.matches(alias) && ($0.activeRequests > 0 || $0.state == "busy") }
        if audioBusy || modelBusy { return i18n.text(zh: "服务中", en: "Busy") }
        if resident { return i18n.text(zh: "已就绪", en: "Ready") }
        return i18n.text(zh: "未加载", en: "Not loaded")
    }
}
