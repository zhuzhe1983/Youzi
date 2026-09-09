import SwiftUI

/// Deliberately secondary: stays below the local model controls, no new top-level tab.
struct SettingsRemoteModelsPanel: View {
    var kind: ModelKind? = nil
    @Environment(YouziI18nConfig.self) private var i18n
    @State private var settings: RemoteModelSettings
    @State private var expanded: Bool
    @State private var editing: RemoteModelConfiguration?
    @State private var removing: RemoteModelConfiguration?
    @State private var error: String?
    init(kind: ModelKind? = nil, settings: RemoteModelSettings = .shared, expanded: Bool = false) {
        self.kind = kind
        _settings = State(initialValue: settings)
        _expanded = State(initialValue: expanded)
    }
    private var models: [RemoteModelConfiguration] { settings.document.models.filter { kind == nil || $0.slot.kind == kind } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(i18n.text(zh: "模型来源", en: "Model source")).font(RapidFont.bodyEmphasis)
                Spacer()
                Picker(i18n.text(zh: "自动选择优先级", en: "Automatic selection priority"), selection: Binding<String>(
                    get: { kind.map { settings.document.overrides[$0.rawValue]?.rawValue ?? "inherit" } ?? settings.document.globalPriority.rawValue },
                    set: { value in perform {
                        try settings.update { doc in
                            if let kind { doc.overrides[kind.rawValue] = ModelSourcePriority(rawValue: value) }
                            else if let priority = ModelSourcePriority(rawValue: value) { doc.globalPriority = priority }
                        }
                    }})) {
                    if kind != nil { Text(i18n.text(zh: "跟随全局", en: "Follow global")).tag("inherit") }
                    ForEach(ModelSourcePriority.allCases, id: \.self) { Text($0.title(chinese: i18n.isChinese)).tag($0.rawValue) }
                }.labelsHidden().frame(maxWidth: 260)
                .accessibilityIdentifier("Settings.Remote.Priority.\(kind?.rawValue ?? "global")")
            }
            Text(i18n.text(zh: "优先级即时保存，已有选择不变；可在模型菜单中按当前优先级重新选择。请求失败不会跨服务重试。", en: "Priority saves immediately. Existing choices stay unchanged; use the model menu to reselect by current priority. Failed requests never retry on another service."))
                .font(RapidFont.caption).foregroundStyle(.secondary)
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(i18n.text(zh: "远程服务仅作补充，不占用本地模型内存。使用时会向服务商发送提示词及所需附件，可能产生费用。", en: "Remote services supplement local models without model RAM use. Requests send prompts and required attachments to the provider and may incur charges."))
                        .font(RapidFont.caption).foregroundStyle(.secondary)
                    if models.isEmpty { Text(i18n.text(zh: "尚未添加远程模型", en: "No remote models configured")).foregroundStyle(.secondary) }
                    ForEach(models) { model in
                        HStack(spacing: 10) {
                            Image(systemName: "network").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(model.displayName).font(RapidFont.bodyEmphasis)
                                Text("\(model.slot.title(chinese: i18n.isChinese)) · \(model.modelID) · \(URL(string: model.baseURL)?.host ?? "")")
                                    .font(RapidFont.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if settings.document.remote(for: model.slot)?.id == model.id {
                                Text(i18n.text(zh: "远程首选", en: "Preferred remote")).font(RapidFont.caption).foregroundStyle(.secondary)
                            } else if model.enabled {
                                Button(i18n.text(zh: "设为首选", en: "Prefer")) { perform { try settings.update { $0.preferred[model.slot.rawValue] = model.id } } }
                            }
                            Toggle(i18n.text(zh: "启用", en: "Enable"), isOn: Binding(get: { model.enabled }, set: { enabled in
                                var next = model; next.enabled = enabled
                                perform { try settings.save(next, key: nil) }
                            })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                            Button { editing = model } label: { Image(systemName: "pencil") }.help(i18n.text(zh: "编辑", en: "Edit"))
                            Button { removing = model } label: { Image(systemName: "trash") }.help(i18n.text(zh: "移除配置", en: "Remove configuration"))
                        }.padding(10).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                    }
                    Button { var model = RemoteModelConfiguration(); model.slot = RemoteModelSlot.allCases.first { kind == nil || $0.kind == kind } ?? .chat; editing = model } label: {
                        Label(i18n.text(zh: "添加远程模型", en: "Add remote model"), systemImage: "plus")
                    }.accessibilityIdentifier("Settings.Remote.Add.\(kind?.rawValue ?? "global")")
                    if let failure = error ?? settings.loadError { Text(failure).font(RapidFont.caption).foregroundStyle(.red) }
                }.padding(.top, 12)
            } label: {
                Label(i18n.text(zh: "远程模型（可选） · \(models.count)", en: "Remote models (optional) · \(models.count)"), systemImage: "network")
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("Settings.Remote.Disclosure.\(kind?.rawValue ?? "global")")
        }
        .padding(16).background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
        .sheet(item: $editing) { model in RemoteModelEditor(model: model, settings: settings) }
        .confirmationDialog(i18n.text(zh: "移除远程模型配置和对应密钥？不会删除服务商的模型或文件。", en: "Remove this configuration and its key? Provider models and files are not deleted."), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button(i18n.text(zh: "移除", en: "Remove"), role: .destructive) { if let model = removing { perform { try settings.remove(model.id) } }; removing = nil }
        }
    }
    private func perform(_ action: () throws -> Void) { do { try action(); error = nil } catch { self.error = error.localizedDescription; expanded = true } }
}

struct RemoteModelEditor: View {
    @State var model: RemoteModelConfiguration
    let settings: RemoteModelSettings
    @Environment(YouziI18nConfig.self) private var i18n
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var replaceKey = false
    @State private var checking = false
    @State private var checkTask: Task<Void, Never>?
    @State private var discovered: [String] = []
    @State private var result: String?
    @State private var failure: String?
    private var existing: Bool { settings.document.models.contains { $0.id == model.id } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(i18n.text(zh: "远程模型 · OpenAI 兼容", en: "Remote model · OpenAI compatible")).font(RapidFont.pageTitle)
            ScrollView {
                Form {
                    TextField(i18n.text(zh: "显示名称", en: "Display name"), text: $model.name)
                    Picker(i18n.text(zh: "场景", en: "Workflow"), selection: $model.slot) {
                        ForEach(RemoteModelSlot.allCases) { Text($0.title(chinese: i18n.isChinese)).tag($0) }
                    }
                    TextField("Base URL", text: $model.baseURL, prompt: Text("https://api.example.com/v1"))
                        .accessibilityIdentifier("Settings.Remote.BaseURL")
                        .onChange(of: model.baseURL) { _, _ in result = nil; discovered = []; if existing { replaceKey = true } }
                    Toggle(i18n.text(zh: "允许不加密的 HTTP（仅限可信网络）", en: "Allow unencrypted HTTP (trusted networks only)"), isOn: $model.allowInsecureHTTP)
                    if existing { Toggle(i18n.text(zh: "替换 API Key（留空则免认证）", en: "Replace API key (empty removes authentication)"), isOn: $replaceKey) }
                    if !existing || replaceKey {
                        SecureField(i18n.text(zh: "API Key（可选）", en: "API key (optional)"), text: $key)
                            .accessibilityIdentifier("Settings.Remote.APIKey")
                    } else { Text(i18n.text(zh: "保留现有钥匙串密钥", en: "Keeping the existing Keychain credential")).foregroundStyle(.secondary) }
                    HStack {
                        Button(i18n.text(zh: "读取模型列表 / 测试连接", en: "Discover models / Test connection")) { discover() }.disabled(checking || model.baseURL.isEmpty)
                        if checking { ProgressView().controlSize(.small) }
                    }
                    TextField(i18n.text(zh: "模型 ID", en: "Model ID"), text: $model.modelID)
                        .accessibilityIdentifier("Settings.Remote.ModelID")
                    if !discovered.isEmpty {
                        Picker(i18n.text(zh: "从列表选择", en: "Choose discovered model"), selection: $model.modelID) {
                            if !discovered.contains(model.modelID) { Text(model.modelID.isEmpty ? "—" : model.modelID).tag(model.modelID) }
                            ForEach(discovered, id: \.self) { Text($0).tag($0) }
                        }
                    }
                    if model.slot == .chat { Toggle(i18n.text(zh: "支持图片理解", en: "Supports image input"), isOn: $model.supportsVision) }
                    if model.slot == .image {
                        Toggle(i18n.text(zh: "支持图片编辑接口", en: "Supports image edits endpoint"), isOn: $model.supportsImageEditing)
                        Picker(i18n.text(zh: "图片响应格式", en: "Image response format"), selection: $model.imageResponseFormat) {
                            Text(i18n.text(zh: "服务商默认（GPT Image 推荐）", en: "Provider default (GPT Image recommended)")).tag("auto")
                            Text("Base64 (DALL·E / compatible)").tag("b64_json")
                        }
                    }
                    if model.slot == .speech { TextField(i18n.text(zh: "可用音色（逗号分隔）", en: "Available voices (comma separated)"), text: $model.voices) }
                    if model.slot == .video {
                        Toggle(i18n.text(zh: "支持参考图片", en: "Supports reference images"), isOn: $model.supportsVideoImageInput)
                        TextField(i18n.text(zh: "支持尺寸（逗号分隔）", en: "Supported sizes (comma separated)"), text: $model.videoSizes)
                        TextField(i18n.text(zh: "支持秒数（逗号分隔）", en: "Supported durations in seconds"), text: $model.videoSeconds)
                    }
                    Toggle(i18n.text(zh: "启用此远程模型", en: "Enable this remote model"), isOn: $model.enabled)
                }.formStyle(.grouped)
                VStack(alignment: .leading, spacing: 8) {
                    Text(i18n.text(zh: "测试连接仅读取 /models，不发送对话、不生成内容。列表不提供完整能力信息，请根据服务商说明选择场景、音色和参数。", en: "Testing only reads /models; it sends no conversation and generates no content. Configure capabilities, voices and parameters according to your provider."))
                    Text(i18n.text(zh: "使用远程模型会发送本次请求内容，可能包含聊天上下文、记忆、附件和工具结果，并可能产生费用。", en: "Using a remote model sends request content, potentially including chat history, memory, attachments and tool results, and may incur charges."))
                    if let result { Text(result).foregroundStyle(.green) }
                    if let failure { Text(failure).foregroundStyle(.red) }
                }.font(RapidFont.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(i18n.text(zh: "取消", en: "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(i18n.text(zh: "保存", en: "Save")) {
                    do { try settings.save(model, key: !existing || replaceKey ? key : nil); dismiss() }
                    catch { failure = error.localizedDescription }
                }.buttonStyle(.borderedProminent).disabled(checking).keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("Settings.Remote.Save")
            }
        }.padding(20).frame(width: 620, height: 650)
        .onDisappear { checkTask?.cancel() }
    }
    private func discover() {
        checking = true; failure = nil; result = nil
        // Capture the draft. A later edit must not present stale discovery as a new host's result.
        var snapshot = model
        if snapshot.modelID.isEmpty { snapshot.modelID = "discovery-only" }
        let draftURL = model.baseURL
        checkTask = Task {
            defer { checking = false }
            do {
                let endpoint = try settings.discoveryEndpoint(snapshot, key: (!existing || replaceKey) ? key : nil)
                let models = try await endpoint.discover()
                guard !Task.isCancelled, model.baseURL == draftURL else { return }
                discovered = models
                result = i18n.text(zh: "连接成功，读取到 \(models.count) 个模型。场景能力尚未验证。", en: "Connected: \(models.count) models. Workflow capabilities are not verified by discovery.")
            } catch { if !Task.isCancelled { failure = error.localizedDescription } }
        }
    }
}
