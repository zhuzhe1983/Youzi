import AppKit
import SwiftUI

/// Six focused pages, sharing Settings' single scroll canvas and Save footer.
struct SettingsModelsPanel: View {
    @Binding var selection: ModelSettingsTab
    @Environment(YouziI18nConfig.self) private var i18n
    @Environment(ServerManager.self) private var server
    @State private var generation = ModelGenerationSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: RapidTheme.Space.xl) {
            SectionHeader(i18n.text(zh: "模型", en: "Models"),
                          subtitle: i18n.text(zh: "服务与文件集中管理，各场景分别设置。", en: "Manage services and files, with defaults for each workflow."), emphasis: .page)
            // Horizontal scrolling keeps all six destinations reachable at the
            // minimum window width and the largest global font size.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(ModelSettingsTab.allCases) { tab in
                        Button { selection = tab } label: {
                            Text(tab.title(isChinese: i18n.isChinese))
                                .font(RapidFont.bodyEmphasis)
                                .fixedSize()
                                .padding(.horizontal, 12).padding(.vertical, 9)
                                .foregroundStyle(selection == tab ? Color.accentColor : .secondary)
                                .background(selection == tab ? Color.accentColor.opacity(0.12) : .clear,
                                            in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selection == tab ? .isSelected : [])
                        .accessibilityIdentifier("Settings.Models.Tab.\(tab.rawValue)")
                    }
                }
            }
            .accessibilityIdentifier("Settings.Models.Tabs")
            Group {
                switch selection {
                case .service: SettingsModelServicePanel()
                case .files: SettingsModelManagementPanel(showsPageHeader: false)
                case .chat: SettingsChatModelPanel()
                case .audio: SettingsAudioDefaultsPanel(generation: generation)
                case .image: imageDefaults
                case .video: SettingsVideoDefaultsPanel(generation: generation)
                }
            }
            .id(selection)
        }
    }

    private var imageDefaults: some View {
        SettingsSection(i18n.text(zh: "图片生成默认值", en: "Image generation defaults"),
                        subtitle: i18n.text(zh: "图片工作台及其他入口未指定尺寸时使用。单次选择优先；图片编辑保留原图尺寸。", en: "Used by the workspace and other app callers when no size is specified. Explicit choices win; edits retain the source size.")) {
            VStack(alignment: .leading, spacing: 16) {
                Picker(i18n.text(zh: "默认比例", en: "Default aspect ratio"), selection: $generation.imageAspect) {
                    Text("1:1").tag("square")
                    Text("3:4").tag("portrait")
                    Text("4:3").tag("landscape")
                }
                .accessibilityIdentifier("Settings.Models.Image.Aspect")
                Picker(i18n.text(zh: "默认长边", en: "Default long edge"), selection: $generation.imageResolution) {
                    ForEach(ModelGenerationDefaults.imageResolutions, id: \.self) { edge in
                        Text("\(edge) px").tag(edge)
                    }
                }
                .accessibilityIdentifier("Settings.Models.Image.Resolution")
                Text(i18n.text(zh: "输出尺寸：", en: "Output size: ") + generation.store.imageSize.replacingOccurrences(of: "x", with: " × ") + " px")
                    .font(RapidFont.bodyEmphasis)
                Text(i18n.text(zh: "更大的尺寸需要更多内存和生成时间。默认 512 × 512；模型不支持时会返回错误，不会静默放大或修改单次参数。", en: "Larger sizes need more memory and time. Default: 512 × 512. Unsupported explicit sizes are not silently changed."))
                    .font(RapidFont.caption).foregroundStyle(.secondary)
            }.padding(16)
        }
    }
}

private struct SettingsModelServicePanel: View {
    @Environment(ServerManager.self) private var server
    @Environment(YouziI18nConfig.self) private var i18n
    @AppStorage(ModelServicePreference.portKey) private var preferredPort = 0
    @AppStorage(AutoStartPreference.storageKey) private var autoStart = AutoStartPreference.defaultValue
    @AppStorage(ModelSwitchConfirmationPreference.storageKey) private var confirmSwitch = ModelSwitchConfirmationPreference.defaultValue
    @State private var portText = ""
    @State private var portError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: RapidTheme.Space.lg) {
            SettingsSection(i18n.text(zh: "模型服务", en: "Model service")) {
                VStack(alignment: .leading, spacing: 16) {
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            endpoint
                            Spacer(minLength: 12)
                            copyAddressButton
                        }
                        VStack(alignment: .leading, spacing: 8) { endpoint; copyAddressButton }
                    }
                    HStack {
                        Text(i18n.text(zh: "服务端口", en: "Port")).font(RapidFont.bodyEmphasis)
                        Spacer()
                        TextField(i18n.text(zh: "自动", en: "Auto"), text: $portText)
                            .textFieldStyle(.roundedBorder).frame(width: 100)
                            .accessibilityIdentifier("Settings.Models.Service.Port")
                    }
                    if let portError { Text(portError).foregroundStyle(.red).font(RapidFont.caption) }
                    Divider()
                    SettingsEmbeddedAPISecurityPanel()
                    Text(i18n.text(zh: "仅本机访问。鉴权在保存后立即生效；端口和新 Key 在下次启动服务时生效。", en: "Local access only. Authentication applies immediately on Save; port and new keys apply on the next service start."))
                        .font(RapidFont.caption).foregroundStyle(.secondary)
                }
            }
            SettingsSection(i18n.text(zh: "启动选项", en: "Startup")) {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(i18n.text(zh: "打开应用时自动启动聊天模型", en: "Auto-start chat model on launch"), isOn: $autoStart)
                        .accessibilityIdentifier("Settings.Models.AutoStartOnLaunchToggle")
                    Toggle(i18n.text(zh: "中断正在处理的请求前先确认", en: "Confirm before interrupting active requests"), isOn: $confirmSwitch)
                        .accessibilityIdentifier("Settings.Models.ConfirmActiveRequestSwitchToggle")
                }
            }
        }
        .onAppear { portText = preferredPort == 0 ? "" : String(preferredPort) }
        .onChange(of: portText) { _, _ in applyPort() }
    }

    private var endpoint: some View {
        Text(verbatim: ModelAPIAccess.baseURL(port: server.activePort))
            .font(RapidFont.body).textSelection(.enabled)
            .accessibilityIdentifier("Settings.Models.Service.Address")
    }

    private var copyAddressButton: some View {
        Button(i18n.text(zh: "复制地址", en: "Copy address")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(ModelAPIAccess.baseURL(port: server.activePort), forType: .string)
        }
        .accessibilityIdentifier("Settings.Models.Service.CopyAddress")
    }

    private func applyPort() {
        let text = portText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { preferredPort = 0; portError = nil; return }
        guard let value = Int(text), (1024...65535).contains(value) else {
            portError = i18n.text(zh: "请输入 1024–65535 的整数，或留空使用自动端口。", en: "Enter an integer from 1024 to 65535, or leave blank for automatic allocation.")
            return
        }
        preferredPort = value
        portError = nil
    }
}

private struct SettingsChatModelPanel: View {
    @Environment(YouziI18nConfig.self) private var i18n
    @Environment(SamplingConfig.self) private var sampling
    @AppStorage(ModelPickerVisibility.showAllStorageKey) private var showAll = false

    var body: some View {
        @Bindable var sampling = sampling
        VStack(alignment: .leading, spacing: RapidTheme.Space.xl) {
            SettingsSection(i18n.text(zh: "聊天默认参数", en: "Chat defaults"),
                            subtitle: i18n.text(zh: "应用于后续聊天请求。上下文容量由模型决定；最大输出限制回答长度，不会改变模型容量。", en: "Applied to subsequent chat requests. Context capacity comes from the model; output limits do not change it.")) {
                VStack(alignment: .leading, spacing: 16) {
                    LabeledContent(i18n.text(zh: "当前模型上下文容量", en: "Current model context capacity"),
                                   value: sampling.activeContextWindow.map { "\($0) tokens" } ?? i18n.text(zh: "等待模型报告", en: "Awaiting model profile"))
                    Stepper(i18n.text(zh: "最大输出：\(sampling.maxTokens) tokens", en: "Maximum output: \(sampling.maxTokens) tokens"),
                            value: $sampling.maxTokens, in: SamplingConfig.maxTokensRange, step: 256)
                    HStack {
                        Text(i18n.text(zh: "温度", en: "Temperature"))
                        Slider(value: $sampling.temperature, in: SamplingConfig.temperatureRange, step: 0.05)
                        Text(sampling.temperature.formatted(.number.precision(.fractionLength(2))))
                    }
                    Toggle(i18n.text(zh: "模型选择器显示小于 1B 的模型", en: "Show sub-1B models in the picker"), isOn: $showAll)
                        .accessibilityIdentifier("Settings.Models.ShowAllModelsToggle")
                }.padding(16)
            }
            SettingsPerformancePanel(embedsInParentScroll: true, showsPageHeader: false)
        }
    }
}

private struct SettingsAudioDefaultsPanel: View {
    @Bindable var generation: ModelGenerationSettings
    @Environment(YouziI18nConfig.self) private var i18n
    @Environment(ServerManager.self) private var server
    @State private var audio: AudioViewModel?
    @State private var confirmLoad = false
    @State private var previewAfterLoad = false
    @State private var preview = SettingsVoicePreview()
    @State private var previewText = ""
    @AppStorage("youzi.models.audio.autoPreview.v1") private var autoPreview = false

    var body: some View {
        SettingsSection(i18n.text(zh: "语音生成默认值", en: "Speech defaults"),
                        subtitle: i18n.text(zh: "每个语音模型单独保存音色。聊天、技能等应用内调用未指定参数时使用这些默认值。", en: "Voices are saved per model. App callers use these defaults when no explicit parameters are provided.")) {
            VStack(alignment: .leading, spacing: 16) {
                if let audio {
                    Picker(i18n.text(zh: "语音模型", en: "Speech model"), selection: Binding(
                        get: { audio.selectedSpeechAlias }, set: {
                            preview.stop()
                            audio.selectSpeechModel($0)
                            if autoPreview { requestPreview() }
                        }
                    )) {
                        if audio.selectedSpeechAlias.isEmpty { Text(i18n.text(zh: "暂无已下载模型", en: "No downloaded models")).tag("") }
                        ForEach(audio.speechModels.filter(\.cached), id: \.alias) { model in
                            Text(model.alias).tag(model.alias)
                        }
                    }
                    .disabled(audio.isBusy)
                    .accessibilityIdentifier("Settings.Models.Audio.Model")
                    Picker(i18n.text(zh: "默认音色", en: "Default voice"), selection: Binding(
                        get: { generation.voices[audio.selectedSpeechAlias] ?? "" },
                        set: {
                            generation.voices[audio.selectedSpeechAlias] = $0.isEmpty ? nil : $0
                            preview.stop()
                            if autoPreview { requestPreview(debounce: true) }
                        }
                    )) {
                        Text(i18n.text(zh: "自动（模型可用的首个音色）", en: "Automatic (first available voice)")).tag("")
                        ForEach(voiceChoices(audio), id: \.self) { Text($0).tag($0) }
                    }
                    .disabled(audio.selectedSpeechAlias.isEmpty || audio.isLoadingVoices)
                    .accessibilityIdentifier("Settings.Models.Audio.Voice")
                    Button(i18n.text(zh: "读取可用音色", en: "Read available voices")) {
                        preview.stop()
                        previewAfterLoad = false
                        if server.isVoiceLaneResident(for: audio.selectedSpeechAlias,
                            modelPath: audio.speechModels.first(where: { $0.alias == audio.selectedSpeechAlias })?.hfRepo) {
                            Task { _ = await audio.loadVoices() }
                        } else { confirmLoad = true }
                    }
                    .disabled(audio.isBusy || audio.selectedSpeechAlias.isEmpty)
                    if audio.isLoadingVoices { ProgressView().controlSize(.small) }
                    if let error = audio.errorMessage { Text(error).foregroundStyle(.red).font(RapidFont.caption) }
                    Text(i18n.text(zh: "打开此页不会自动加载模型。不支持的已保存音色会回退到当前模型的可用音色。", en: "Opening this page never loads a model. Unavailable saved voices fall back to an actual voice of the current model."))
                        .font(RapidFont.caption).foregroundStyle(.secondary)
                } else { ProgressView().controlSize(.small) }
                HStack {
                    Text(i18n.text(zh: "默认语速", en: "Default speed"))
                    Slider(value: $generation.speed, in: 0.5...2, step: 0.05)
                        .accessibilityIdentifier("Settings.Models.Audio.Speed")
                    Text(generation.speed.formatted(.number.precision(.fractionLength(2))) + "×")
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text(i18n.text(zh: "试听语音", en: "Voice preview")).font(RapidFont.bodyEmphasis)
                    TextField(i18n.text(zh: "输入试听文本", en: "Enter preview text"), text: $previewText, axis: .vertical)
                        .lineLimit(2...4).textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("Settings.Models.Audio.PreviewText")
                    Toggle(i18n.text(zh: "切换音色后自动试听", en: "Auto-preview when changing voice"), isOn: $autoPreview)
                        .accessibilityIdentifier("Settings.Models.Audio.AutoPreview")
                    HStack(spacing: 12) {
                        Button {
                            requestPreview()
                        } label: {
                            Label(i18n.text(zh: "试听 / 重播", en: "Preview / Replay"), systemImage: "play.fill")
                        }
                        .disabled(audio?.selectedSpeechAlias.isEmpty != false || audio?.isBusy == true || previewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("Settings.Models.Audio.Preview")
                        Button(i18n.text(zh: "停止", en: "Stop")) { preview.stop() }
                            .disabled(preview.state != .generating && preview.state != .playing)
                            .accessibilityIdentifier("Settings.Models.Audio.StopPreview")
                        if preview.state == .generating {
                            ProgressView().controlSize(.small)
                            Text(i18n.text(zh: "正在生成…", en: "Generating…")).font(RapidFont.caption)
                        } else if preview.state == .playing {
                            Text(i18n.text(zh: "正在播放", en: "Playing")).font(RapidFont.caption)
                        }
                    }
                    if let error = preview.errorMessage {
                        Text(i18n.text(zh: "试听失败：", en: "Preview failed: ") + error)
                            .font(RapidFont.caption).foregroundStyle(.red)
                    }
                    Text(i18n.text(zh: "使用当前音色与语速。自动试听默认关闭；切换模型也会遵循此开关。停止会取消本地等待与播放，已提交的模型计算可能仍会完成。", en: "Uses the current voice and speed. Auto-preview is off by default and also applies to model changes. Stop cancels local waiting and playback; already-submitted model computation may still finish."))
                        .font(RapidFont.caption).foregroundStyle(.secondary)
                }
            }.padding(16)
        }
        .task {
            if previewText.isEmpty {
                previewText = i18n.text(zh: "你好，我是柚子。这是当前音色的试听效果，很高兴为你服务。", en: "Hello, I am Youzi. This is a preview of the selected voice. How can I help you today?")
            }
            let model = AudioViewModel(server: server, generationSettings: generation)
            audio = model
            await model.refreshCatalog()
            if !model.speechModels.contains(where: { $0.cached && $0.alias == model.selectedSpeechAlias }) {
                model.selectSpeechModel(model.speechModels.first(where: \.cached)?.alias ?? "")
            }
        }
        .onDisappear { preview.stop() }
        .onChange(of: generation.speed) { _, _ in preview.stop() }
        .onChange(of: previewText) { _, text in
            preview.stop()
            if text.count > 500 { previewText = String(text.prefix(500)) }
        }
        .onChange(of: autoPreview) { _, enabled in if !enabled { preview.stop() } }
        .confirmationDialog(i18n.text(zh: "需要先加载这个语音模型，会占用内存。是否继续？", en: "This speech model must be loaded into memory. Continue?"), isPresented: $confirmLoad) {
            Button(previewAfterLoad
                   ? i18n.text(zh: "加载并试听", en: "Load and preview")
                   : i18n.text(zh: "加载并读取音色", en: "Load and read voices")) {
                if previewAfterLoad { startPreview() }
                else { Task { if let audio { _ = await audio.loadVoices() } } }
            }
            Button(i18n.text(zh: "取消", en: "Cancel"), role: .cancel) { previewAfterLoad = false }
        }
    }

    private func requestPreview(debounce: Bool = false) {
        guard let audio, !audio.selectedSpeechAlias.isEmpty,
              !previewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if server.isVoiceLaneResident(for: audio.selectedSpeechAlias,
                            modelPath: audio.speechModels.first(where: { $0.alias == audio.selectedSpeechAlias })?.hfRepo) {
            startPreview(debounce: debounce)
        } else {
            preview.stop()
            previewAfterLoad = true
            confirmLoad = true
        }
    }

    private func startPreview(debounce: Bool = false) {
        guard let audio, !audio.selectedSpeechAlias.isEmpty else { return }
        let alias = audio.selectedSpeechAlias
        let text = String(previewText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        guard !text.isEmpty else { return }
        let voice = generation.voices[alias]
        let speed = generation.speed
        preview.start(debounce: debounce ? .milliseconds(350) : .zero) {
            if !server.isVoiceLaneReady(for: alias) || audio.voices.isEmpty {
                guard await audio.loadVoices() else {
                    throw AudioClientError.transport(audio.errorMessage ?? i18n.text(zh: "无法读取语音模型音色。", en: "Could not read the model's voices."))
                }
            }
            try Task.checkCancellation()
            guard alias == audio.selectedSpeechAlias else { throw CancellationError() }
            // Resolve against actual voices; a stale saved default must not make preview fail.
            let resolvedVoice = voice.flatMap { audio.voices.contains($0) ? $0 : nil } ?? audio.voices.first
            let data = try await SettingsVoicePreview.synthesizeOnReadyLane(
                server: server, alias: alias, text: text, voice: resolvedVoice, speed: speed
            )
            _ = await server.refreshVoiceLaneResidency(
                for: alias, modelPath: audio.speechModels.first(where: { $0.alias == alias })?.hfRepo
            )
            return data
        }
    }
    private func voiceChoices(_ audio: AudioViewModel) -> [String] {
        var result = audio.voices
        if let saved = generation.voices[audio.selectedSpeechAlias], !saved.isEmpty, !result.contains(saved) { result.append(saved) }
        return result
    }
}

private struct SettingsVideoDefaultsPanel: View {
    @Bindable var generation: ModelGenerationSettings
    @Environment(YouziI18nConfig.self) private var i18n
    @Environment(ServerManager.self) private var server
    @AppStorage(VideoFeatureConfig.enabledKey) private var enabled = VideoFeatureConfig.defaultEnabled
    @State private var capabilities: VideoCapabilities?
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        SettingsSection(i18n.text(zh: "视频生成默认值", en: "Video defaults"),
                        subtitle: i18n.text(zh: "仅使用服务实际支持的尺寸和时长；模型切换后不支持的默认值会安全回退。", en: "Only capability-validated sizes and durations are used; unsupported defaults safely fall back after a model switch.")) {
            VStack(alignment: .leading, spacing: 16) {
                Toggle(i18n.text(zh: "启用视频生成入口", en: "Enable video workspace"), isOn: $enabled)
                    .accessibilityIdentifier("Settings.Experimental.VideoGenerationToggle")
                Picker(i18n.text(zh: "默认尺寸", en: "Default size"), selection: $generation.videoSize) {
                    Text(i18n.text(zh: "自动（最低可用开销）", en: "Automatic (lowest supported cost)")).tag("")
                    ForEach(sizeChoices, id: \.self) { Text($0).tag($0) }
                }
                .accessibilityIdentifier("Settings.Models.Video.Size")
                Picker(i18n.text(zh: "默认时长", en: "Default duration"), selection: $generation.videoSeconds) {
                    Text(i18n.text(zh: "自动", en: "Automatic")).tag(0)
                    ForEach(durationChoices, id: \.self) { Text("\($0) s").tag($0) }
                }
                .accessibilityIdentifier("Settings.Models.Video.Duration")
                Button(i18n.text(zh: "读取运行中模型的参数", en: "Read running model capabilities")) {
                    Task { await loadCapabilities() }
                }.disabled(loading)
                if loading { ProgressView().controlSize(.small) }
                if let error { Text(error).font(RapidFont.caption).foregroundStyle(.red) }
                Text(i18n.text(zh: "未启动视频模型时保留已保存值，不会为了读取参数自动加载或下载模型。", en: "Stored values are kept while the video model is stopped. Reading capabilities never starts or downloads a model."))
                    .font(RapidFont.caption).foregroundStyle(.secondary)
            }.padding(16)
        }
    }
    private var sizeChoices: [String] {
        var values = capabilities?.sizePresets ?? []
        if !generation.videoSize.isEmpty, !values.contains(generation.videoSize) { values.append(generation.videoSize) }
        return values
    }
    private var durationChoices: [Int] {
        let size = capabilities.map { generation.store.resolveVideoSize(available: $0.sizePresets) } ?? ""
        var values = capabilities?.durationPresets(for: size) ?? []
        if generation.videoSeconds > 0, !values.contains(generation.videoSeconds) { values.append(generation.videoSeconds) }
        return values.sorted()
    }
    private func loadCapabilities() async {
        loading = true; error = nil
        defer { loading = false }
        do { capabilities = try await VideoClient().capabilities(port: server.activePort, bearer: server.activeBearer) }
        catch { self.error = i18n.text(zh: "无法读取视频参数，请先在视频工作台启动模型：", en: "Unable to read capabilities. Start a video model in the workspace first: ") + error.localizedDescription }
    }
}
