import SwiftUI

/// A reroll runs the original media tool directly; it does not ask a language
/// model to reinterpret the prompt or alter the active conversation.
@MainActor @Observable
final class YouziArtifactReroll {
    private(set) var running = false
    private(set) var result: ToolCallResult?
    private(set) var approval: YouziModelApprovalStore?
    @ObservationIgnored private var task: Task<Void, Never>?

    func start(artifact: YouziArtifact, generation: YouziArtifactGeneration, tools: YouziLocalModelTools) {
        guard !running, generation.canReroll else { return }
        running = true; result = nil; approval = tools.approval
        tools.requiredSource = generation.source
        tools.rerollParentID = artifact.id
        var args = generation.rerollArguments()
        // Speech speed is replayed through the internal client dependency; it
        // is not a new agent-controlled time transformation.
        args.removeValue(forKey: "speed")
        task = Task { [weak self] in
            guard let self else { return }
            defer { running = false; task = nil; approval = nil }
            do {
                let json = try JSONEncoder().encode(args)
                result = await tools.run(.init(id: UUID().uuidString, name: generation.operation.tool,
                    arguments: String(decoding: json, as: UTF8.self)))
            } catch {
                result = .init(toolCallID: "reroll", content: "{\"error\":\"invalid_arguments\"}", isError: true)
            }
        }
    }
    func cancel() { task?.cancel() }
}

struct YouziArtifactGenerationDetail: View {
    @Environment(YouziProductModel.self) private var product
    @Environment(ServerManager.self) private var server
    @Environment(ChatViewModel.self) private var chat
    @Environment(DownloadManager.self) private var downloads
    @Environment(YouziI18nConfig.self) private var i18n
    @Environment(\.dismiss) private var dismiss
    let artifact: YouziArtifact
    @State private var reroll = YouziArtifactReroll()
    @State private var embedded: Bool?
    @State private var fileError = false
    private var generation: YouziArtifactGeneration? { product.artifact(id: artifact.id)?.generation ?? artifact.generation }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(i18n.text(zh: "生成信息", en: "Generation details"), systemImage: "info.circle").font(RapidFont.sectionTitle)
                Spacer()
                Button(i18n.text(zh: "关闭", en: "Close")) { dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(reroll.running)
                    .accessibilityIdentifier("YouziSimple.Generation.Close")
            }
            Text(artifact.title).font(RapidFont.bodyEmphasis).textSelection(.enabled)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let generation {
                        YouziGenerationInformation(generation: generation)
                        Divider()
                        HStack {
                            Text(embedded == true ? i18n.text(zh: "生成信息已写入文件，导出后会保留。", en: "Generation details are embedded and travel with exports.") :
                                i18n.text(zh: "生成信息保存在成果记录中。", en: "Generation details are saved in the deliverable record."))
                                .font(RapidFont.secondary).foregroundStyle(RapidTheme.textSecondary)
                            Spacer()
                            if embedded == false, case .appManaged = product.file(for: artifact)?.location {
                                Button(i18n.text(zh: "写入文件", en: "Embed in file")) {
                                    do { try product.embedGeneration(artifactID: artifact.id); embedded = true; fileError = false }
                                    catch { fileError = true }
                                }.disabled(reroll.running)
                                    .accessibilityIdentifier("YouziSimple.Generation.Embed")
                            }
                        }
                        if fileError {
                            Text(i18n.text(zh: "暂时无法读取或写入文件元信息，成果记录仍然保留。", en: "Could not read or write file metadata. The deliverable record is preserved."))
                                .font(RapidFont.secondary).foregroundStyle(.red)
                        }
                        Text(rerollExplanation(generation)).font(RapidFont.secondary).foregroundStyle(RapidTheme.textSecondary)
                    } else {
                        Text(i18n.text(zh: "这份成果没有可恢复的生成记录。模型、服务器、参数和提示词均未记录。", en: "No generation record could be recovered. The model, server, parameters and prompt were not recorded."))
                            .foregroundStyle(RapidTheme.textSecondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let request = reroll.approval?.pending {
                HStack {
                    Text(i18n.text(zh: "需要加载本地模型：", en: "Load local model: ") + request.alias).font(RapidFont.secondary)
                    Spacer()
                    Button(i18n.text(zh: "取消", en: "Cancel")) { reroll.approval?.resolve(id: request.id, allow: false) }
                    Button(i18n.text(zh: "加载并生成", en: "Load and generate")) { reroll.approval?.resolve(id: request.id, allow: true) }
                }.padding(12).background(RapidTheme.brandPrimaryTint, in: RoundedRectangle(cornerRadius: 8))
            }
            if let result = reroll.result {
                Text(result.isError
                    ? YouziLocalModelTools.failureMessage(content: result.content, chinese: i18n.isChinese) ?? i18n.text(zh: "重新生成未完成，原成果已保留。", en: "Reroll did not finish. The original is preserved.")
                    : i18n.text(zh: "已生成新成果，已添加到成果列表和原任务。", en: "A new deliverable was added to this list and the original task."))
                    .font(RapidFont.secondary).foregroundStyle(result.isError ? Color.red : Color.green)
                    .accessibilityIdentifier("YouziSimple.Generation.Result")
            }
            HStack {
                Spacer()
                if reroll.running {
                    ProgressView().controlSize(.small)
                    Text(i18n.text(zh: "正在重新生成…", en: "Generating…"))
                    Button(i18n.text(zh: "停止", en: "Stop")) { reroll.cancel() }
                } else {
                    Button { start() } label: {
                        Label(i18n.text(zh: "重新生成", en: "Reroll"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(generation?.canReroll != true || artifact.state != .active)
                    .accessibilityIdentifier("YouziSimple.Generation.Reroll")
                }
            }
        }
        .padding(24).frame(width: 620, height: 650)
        .interactiveDismissDisabled(reroll.running)
        .task(id: artifact.id) {
            guard let generation else { return }
            do {
                let lease = try await product.mediaLease(id: artifact.fileID)
                let record = try await Task.detached {
                    let size = try lease.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
                    guard size <= 80 * 1024 * 1024 else { throw YouziGenerationEmbedding.Failure.tooLarge }
                    return try YouziGenerationEmbedding.read(Data(contentsOf: lease.url), kind: artifact.kind)
                }.value
                embedded = record == generation
            } catch { fileError = true }
        }
        .onDisappear { reroll.cancel() }
        .accessibilityIdentifier("YouziSimple.Generation.Detail")
    }

    private func rerollExplanation(_ record: YouziArtifactGeneration) -> String {
        if !record.canReroll { return i18n.text(zh: "缺少原模型或服务器信息，无法可靠地重新生成。", en: "The original model or server is missing, so reroll is unavailable.") }
        let base = record.operation == .speech
            ? i18n.text(zh: "沿用原模型、服务器、文本和音色另存一份音频。", en: "Generate new audio using the original model, server, text and voice.")
            : i18n.text(zh: "沿用原模型、服务器、提示词及参数，使用新随机种子生成一份新成果。远程随机性由服务商控制。", en: "Reuse the original model, server, prompt and parameters with a new seed. Remote randomness is provider-controlled.")
        return base + (record.recoveredFromHistory ? i18n.text(zh: " 未记录的参数沿用当前默认值。", en: " Unrecorded parameters use current defaults.") : "")
            + (record.source.location == .remote ? i18n.text(zh: " 将向原服务商提交一次新请求，可能产生费用。", en: " This submits a new request to the original provider and may incur charges.") : "")
    }
    private func start() {
        guard let generation else { return }
        let params = generation.requested.merging(generation.submitted) { _, new in new }
        let speed: Double? = if case .number(let value) = params["speed"] { value } else { nil }
        let tools = YouziLocalModelTools.desktop(server: server, chat: chat, product: product, downloads: downloads,
            contextOverride: .init(taskID: artifact.taskID, projectID: artifact.projectID), speechSpeed: speed)
        reroll.start(artifact: artifact, generation: generation, tools: tools)
    }
}

struct YouziGenerationInformation: View {
    @Environment(YouziI18nConfig.self) private var i18n
    let generation: YouziArtifactGeneration
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            field(i18n.text(zh: "模型", en: "Model"), generation.source.modelName.isEmpty ? unknown : generation.source.modelName)
            if let id = generation.source.modelID, id != generation.source.modelName { field(i18n.text(zh: "模型 ID", en: "Model ID"), id) }
            field(i18n.text(zh: "服务器", en: "Server"), serverLabel)
            field(i18n.text(zh: generation.operation == .speech ? "合成文本" : "提示词", en: generation.operation == .speech ? "Speech text" : "Prompt"), generation.prompt)
            parameters(i18n.text(zh: "请求参数", en: "Requested parameters"), generation.requested)
            parameters(i18n.text(zh: "提交参数", en: "Submitted parameters"), generation.submitted)
            parameters(i18n.text(zh: "实际返回参数", en: "Reported parameters"), generation.reported)
            if generation.recoveredFromHistory {
                Text(i18n.text(zh: "从原任务的工具记录恢复；缺失信息显示为“未记录”。", en: "Recovered from the original task's tool records. Missing information is marked unrecorded."))
                    .font(RapidFont.caption).foregroundStyle(RapidTheme.textSecondary)
            }
        }.textSelection(.enabled)
    }
    private var unknown: String { i18n.text(zh: "未记录", en: "Not recorded") }
    private var serverLabel: String {
        let source = switch generation.source.location {
        case .local: i18n.text(zh: "本机", en: "Local")
        case .remote: i18n.text(zh: "远程", en: "Remote")
        case .unknown: unknown
        }
        return source + " · " + (generation.source.server ?? unknown)
    }
    private func field(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(RapidFont.caption).foregroundStyle(RapidTheme.textSecondary)
            Text(value).font(RapidFont.body).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func parameterLabel(_ key: String) -> String {
        guard i18n.isChinese else { return key }
        return ["size": "尺寸", "seed": "随机种子", "steps": "采样步数", "guidance": "引导系数",
                "negative_prompt": "负面提示词", "voice": "音色", "speed": "语速", "seconds": "时长（秒）",
                "elapsed_ms": "耗时（毫秒）", "negative_prompt_applied": "已应用负面提示词",
                "reference_image_id": "参考图片"] [key] ?? key
    }
    private func parameters(_ title: String, _ values: [String: CodableJSON]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(RapidFont.caption).foregroundStyle(RapidTheme.textSecondary)
            if values.isEmpty { Text(unknown).font(RapidFont.secondary).foregroundStyle(RapidTheme.textSecondary) }
            else {
                ForEach(values.keys.sorted(), id: \.self) { key in
                    HStack(alignment: .top) {
                        Text(parameterLabel(key)).font(RapidFont.caption).help(key).frame(width: 160, alignment: .leading)
                        Text(values[key]!.generationDisplay).font(RapidFont.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    }.fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
