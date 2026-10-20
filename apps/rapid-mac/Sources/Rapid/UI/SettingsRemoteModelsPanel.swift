import SwiftUI

struct RemoteModelEditor: View {
    @State var model: RemoteModelConfiguration
    let settings: RemoteModelSettings
    @Environment(YouziI18nConfig.self) private var i18n
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var replaceKey = false
    @State private var checking = false
    @State private var checkTask: Task<Void, Never>?
    @State var discovered: [RemoteDiscoveredModel] = []
    @State private var sourceID: UUID?
    @State private var search = ""
    @State private var showAll = false
    @State private var showsDiscoveredModels = false
    @State private var discoveryRevision = UUID()
    @State private var result: String?
    @State private var failure: String?
    @State private var needsKeychainAuthorization = false
    @State private var authorizingKey = false
    private var existing: Bool { settings.document.models.contains { $0.id == model.id } }
    private var inheritedSource: UUID? { !existing && !replaceKey ? sourceID : nil }
    private var draftKey: String? { inheritedSource != nil || (existing && !replaceKey) ? nil : key }
    private var filteredModels: [RemoteDiscoveredModel] {
        RemoteDiscoveredModel.filtered(discovered, slot: model.slot, query: search, showAll: showAll)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(i18n.text(zh: "远程模型 · OpenAI 兼容", en: "Remote model · OpenAI compatible")).font(RapidFont.pageTitle)
            ScrollView {
                Form {
                    Picker(i18n.text(zh: "场景", en: "Workflow"), selection: $model.slot) {
                        ForEach(RemoteModelSlot.allCases) { Text($0.title(chinese: i18n.isChinese)).tag($0) }
                    }
                    if !existing && !settings.document.models.isEmpty {
                        Picker(i18n.text(zh: "复用服务器配置", en: "Reuse server configuration"), selection: $sourceID) {
                            Text(i18n.text(zh: "手动填写", en: "Enter manually")).tag(nil as UUID?)
                            ForEach(settings.document.models) { source in
                                Text(source.baseURL + " · " + source.displayName).tag(Optional(source.id))
                            }
                        }.onChange(of: sourceID) { _, value in
                            invalidateDiscovery()
                            key = ""; replaceKey = false
                            if let source = settings.document.models.first(where: { $0.id == value }) {
                                model.baseURL = source.baseURL
                                model.allowInsecureHTTP = source.allowInsecureHTTP
                            }
                        }
                        .accessibilityIdentifier("Settings.Remote.ReuseService")
                        Text(i18n.text(zh: "只沿用服务器地址、API Key 和连接选项；模型名称与参数单独设置。", en: "Copies the server URL, API key and connection options only. Choose the model and its parameters separately."))
                            .font(RapidFont.caption).foregroundStyle(.secondary)
                            .settingsExplanation()
                    }
                    TextField("Base URL", text: $model.baseURL, prompt: Text("https://api.example.com/v1"))
                        .accessibilityIdentifier("Settings.Remote.BaseURL")
                        .onChange(of: model.baseURL) { _, _ in
                            invalidateDiscovery()
                            if existing { replaceKey = true }
                            if let source = settings.document.models.first(where: { $0.id == sourceID }),
                               (try? RemoteModelEndpoint.normalizedBaseURL(model.baseURL, allowHTTP: model.allowInsecureHTTP).absoluteString) != source.baseURL { sourceID = nil }
                        }
                    Toggle(i18n.text(zh: "允许不加密的 HTTP（仅限可信网络）", en: "Allow unencrypted HTTP (trusted networks only)"), isOn: $model.allowInsecureHTTP)
                    if existing || sourceID != nil { Toggle(i18n.text(zh: "替换 API Key（留空则免认证）", en: "Replace API key (empty removes authentication)"), isOn: $replaceKey) }
                    if (!existing && sourceID == nil) || replaceKey {
                        SecureField(i18n.text(zh: "API Key（可选）", en: "API key (optional)"), text: $key)
                            .accessibilityIdentifier("Settings.Remote.APIKey")
                    } else { Text(i18n.text(zh: "使用该服务器已保存的 API Key", en: "Using the saved server API key")).foregroundStyle(.secondary) }
                    HStack {
                        Button(i18n.text(zh: "读取模型列表 / 测试连接", en: "Discover models / Test connection")) { discover() }.disabled(checking || model.baseURL.isEmpty)
                        if checking { ProgressView().controlSize(.small) }
                    }
                    if needsKeychainAuthorization {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(i18n.text(zh: "已保存的 API Key 需要 macOS 钥匙串授权。授权后可继续复用，无需重新填写。", en: "The saved API key needs macOS Keychain authorization. Authorize to reuse it without entering it again."))
                                .font(RapidFont.caption).foregroundStyle(.secondary)
                            Button(i18n.text(zh: "授权读取密钥并重试", en: "Authorize key access and retry")) { discover(authorize: true) }
                                .disabled(checking)
                                .accessibilityIdentifier("Settings.Remote.AuthorizeKey")
                        }
                    }
                    if authorizingKey {
                        Text(i18n.text(zh: "正在等待 macOS 钥匙串授权，请在系统对话框中操作。", en: "Waiting for macOS Keychain authorization. Respond to the system dialog."))
                            .font(RapidFont.caption).foregroundStyle(.secondary)
                    }
                    TextField(i18n.text(zh: "远程模型名称 / ID", en: "Remote model name / ID"), text: modelIDBinding)
                        .accessibilityIdentifier("Settings.Remote.ModelID")
                    if !discovered.isEmpty {
                        Text(i18n.text(zh: "\(discovered.count) 个模型 · 当前场景 \(discovered.filter { $0.slots.contains(model.slot) }.count) 个候选 · 显示 \(filteredModels.count) 个", en: "\(discovered.count) models · \(discovered.filter { $0.slots.contains(model.slot) }.count) workflow candidates · \(filteredModels.count) shown"))
                            .font(RapidFont.caption).foregroundStyle(.secondary)
                        Button { showsDiscoveredModels.toggle() } label: {
                            HStack {
                                Text(model.modelID.isEmpty ? i18n.text(zh: "请选择一个模型", en: "Choose a model") : model.modelID)
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Image(systemName: "chevron.down")
                            }.frame(maxWidth: .infinity)
                        }
                        .accessibilityIdentifier("Settings.Remote.DiscoveredModels")
                        .popover(isPresented: $showsDiscoveredModels, arrowEdge: .bottom) {
                            discoveredModelList
                        }
                        if filteredModels.isEmpty {
                            Text(i18n.text(zh: "没有匹配项。可显示全部模型，或手动填写模型 ID。", en: "No matches. Show all models or enter a model ID manually."))
                                .font(RapidFont.caption).foregroundStyle(.secondary)
                        }
                        if let selected = discovered.first(where: { $0.id == model.modelID }), !selected.slots.contains(model.slot) {
                            Text(i18n.text(zh: "当前模型尚未被识别为此场景的候选，请确认服务商支持。", en: "This model is not identified for this workflow. Confirm provider support."))
                                .font(RapidFont.caption).foregroundStyle(.orange)
                        }
                    }
                    TextField(i18n.text(zh: "本地显示名称", en: "Local display name"), text: $model.name, prompt: Text(model.modelID))
                        .accessibilityIdentifier("Settings.Remote.DisplayName")
                    Text(i18n.text(zh: "默认沿用远程模型名称，可修改；保存后显示在对应场景的模型列表中。", en: "Defaults to the remote model name. Rename it here for the workflow model list."))
                        .font(RapidFont.caption).foregroundStyle(.secondary)
                        .settingsExplanation()
                    if model.slot == .image || model.slot == .video {
                        Text(model.slot == .image
                             ? i18n.text(zh: "需要兼容 /images/generations；图片理解能力不等于图片生成。", en: "Requires /images/generations compatibility; image input alone is not image generation.")
                             : i18n.text(zh: "请选择服务商的视频协议；仅有视频模型名称不能确认可用。", en: "Choose your provider's video protocol. A video model name alone does not confirm compatibility."))
                            .font(RapidFont.caption).foregroundStyle(.secondary)
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
                        Picker(i18n.text(zh: "视频接口", en: "Video API"), selection: Binding(get: { model.videoAPI ?? .openAI }, set: { model.videoAPI = $0 })) {
                            Text("OpenAI /videos").tag(RemoteVideoAPI.openAI)
                            Text("CLIProxyAPI /openai/v1/videos").tag(RemoteVideoAPI.cliProxyAPI)
                        }
                        if model.usesCLIProxyVideo {
                            Text(i18n.text(zh: "沿用上方常规 /v1 地址。支持 Grok Imagine Video、1.5、1.5-preview；仅保留本次连接的任务记录，不支持服务端历史列表、删除或取消。MiniMax-H3 需要其他服务接口。", en: "Keep the regular /v1 base above. Supports Grok Imagine Video, 1.5 and 1.5-preview. Session jobs only: no server history, deletion or cancellation. MiniMax-H3 needs another provider API."))
                                .font(RapidFont.caption).foregroundStyle(.secondary)
                        }
                        Toggle(i18n.text(zh: "支持参考图片", en: "Supports reference images"), isOn: $model.supportsVideoImageInput)
                        TextField(i18n.text(zh: "支持尺寸（逗号分隔）", en: "Supported sizes (comma separated)"), text: $model.videoSizes)
                        TextField(i18n.text(zh: "支持秒数（逗号分隔）", en: "Supported durations in seconds"), text: $model.videoSeconds)
                    }
                    Toggle(i18n.text(zh: "启用此远程模型", en: "Enable this remote model"), isOn: $model.enabled)
                }.formStyle(.grouped)
                VStack(alignment: .leading, spacing: 8) {
                    Text(i18n.text(zh: "仅读取 /models，不生成内容。优先按服务声明筛选，名称匹配仅作候选；均不代表接口已验证。未识别的模型仍可手动添加，参数以服务商说明为准。", en: "Only reads /models, without generation. Filters use provider metadata first, then name hints; neither verifies API compatibility. Unknown models can still be added manually. Use provider-documented parameters."))
                        .settingsExplanation()
                    Text(i18n.text(zh: "使用远程模型会发送本次请求内容，可能包含聊天上下文、记忆、附件和工具结果，并可能产生费用。", en: "Using a remote model sends request content, potentially including chat history, memory, attachments and tool results, and may incur charges."))
                    if let result { Text(result).foregroundStyle(.green) }
                    if let failure { Text(failure).foregroundStyle(.red) }
                }.font(RapidFont.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button(i18n.text(zh: "取消", en: "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(i18n.text(zh: "保存", en: "Save")) {
                    do { try settings.save(model, key: draftKey, inheritingFrom: inheritedSource); dismiss() }
                    catch { showFailure(error) }
                }.buttonStyle(.borderedProminent).disabled(checking).keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("Settings.Remote.Save")
            }
        }.padding(20).frame(width: 620, height: 650)
        .onChange(of: key) { _, _ in invalidateDiscovery() }
        .onChange(of: replaceKey) { _, _ in invalidateDiscovery() }
        .onChange(of: model.allowInsecureHTTP) { _, _ in invalidateDiscovery() }
        .onDisappear { checkTask?.cancel(); discoveryRevision = UUID() }
    }
    private var modelIDBinding: Binding<String> {
        Binding(get: { model.modelID }, set: { model.selectModelID($0) })
    }
    private var discoveredModelList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(i18n.text(zh: "选择远程模型", en: "Choose a remote model")).font(RapidFont.bodyEmphasis)
            Text(i18n.text(zh: "已读取 \(discovered.count) 个 · 当前场景 \(discovered.filter { $0.slots.contains(model.slot) }.count) 个候选", en: "\(discovered.count) found · \(discovered.filter { $0.slots.contains(model.slot) }.count) workflow candidates"))
                .font(RapidFont.caption).foregroundStyle(.secondary)
            TextField(i18n.text(zh: "搜索模型", en: "Search models"), text: $search)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("Settings.Remote.ModelSearch")
            Toggle(i18n.text(zh: "显示全部场景及未识别模型", en: "Show all workflows and unknown models"), isOn: $showAll)
                .font(RapidFont.caption)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(filteredModels) { candidate in
                        Button {
                            model.selectModelID(candidate.id)
                            showsDiscoveredModels = false
                        } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(candidate.id).font(RapidFont.secondary).lineLimit(2)
                                    Text(candidate.label(chinese: i18n.isChinese)).font(RapidFont.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                if model.modelID == candidate.id { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                            }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .accessibilityIdentifier("Settings.Remote.ModelCandidate.\(candidate.id)")
                    }
                    if filteredModels.isEmpty {
                        Text(i18n.text(zh: "没有匹配项，请调整搜索或显示全部模型。", en: "No matches. Change the search or show all models."))
                            .foregroundStyle(.secondary).padding(8)
                    }
                }
            }.frame(height: 250)
        }.padding(16).frame(width: 420)
            .accessibilityIdentifier("Settings.Remote.DiscoveryResults")
    }
    private func invalidateDiscovery() {
        checkTask?.cancel(); discoveryRevision = UUID(); checking = false
        discovered = []; result = nil; failure = nil; showsDiscoveredModels = false
        needsKeychainAuthorization = false; authorizingKey = false
    }
    private func showFailure(_ error: Error) {
        if case RemoteModelError.keychain = error, draftKey == nil {
            needsKeychainAuthorization = true
            failure = i18n.text(zh: "未能读取已保存的 API Key，请授权后重试，或选择替换 API Key。", en: "Could not read the saved API key. Authorize access and retry, or replace the API key.")
        } else {
            failure = error.localizedDescription
        }
    }
    private func discover(authorize: Bool = false) {
        checking = true; failure = nil; result = nil; authorizingKey = authorize
        // Capture the draft. A later edit must not present stale discovery as a new host's result.
        var snapshot = model
        if snapshot.modelID.isEmpty { snapshot.modelID = "discovery-only" }
        let revision = UUID(); discoveryRevision = revision
        let credential = draftKey
        let source = inheritedSource
        checkTask = Task {
            defer { if discoveryRevision == revision { checking = false; authorizingKey = false } }
            do {
                let endpoint: RemoteModelEndpoint
                if authorize {
                    endpoint = try await settings.authorizedDiscoveryEndpoint(snapshot, key: credential, inheritingFrom: source)
                } else {
                    endpoint = try settings.discoveryEndpoint(snapshot, key: credential, inheritingFrom: source)
                }
                guard !Task.isCancelled, discoveryRevision == revision else { return }
                authorizingKey = false; needsKeychainAuthorization = false
                let models = try await endpoint.discoverModels()
                guard !Task.isCancelled, discoveryRevision == revision else { return }
                discovered = models
                search = ""
                showAll = !models.contains { $0.slots.contains(model.slot) }
                showsDiscoveredModels = !models.isEmpty
                result = i18n.text(zh: "连接成功，读取到 \(models.count) 个模型。场景能力尚未验证。", en: "Connected: \(models.count) models. Workflow capabilities are not verified by discovery.")
            } catch { if !Task.isCancelled, discoveryRevision == revision { showFailure(error) } }
        }
    }
}
