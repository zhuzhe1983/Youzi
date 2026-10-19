import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Simple Mode's task surface. It deliberately talks to the app-owned
/// `ChatViewModel` and `ServerManager` from the environment: the simplified
/// presentation changes language and hierarchy, never the underlying task or
/// model lifecycle.
struct YouziSimpleTaskView: View {
    @Environment(ChatViewModel.self) private var chat
    @Environment(ServerManager.self) private var server
    @Environment(YouziProductModel.self) private var productModel
    @Environment(\.openWindow) private var openWindow
    @Environment(SettingsRouter.self) private var settingsRouter: SettingsRouter?
    @Environment(YouziI18nConfig.self) private var i18n

    let taskID: UUID?
    let projectID: UUID?
    @Binding var assistantAlias: String
    var catalogEntries: [ModelEntry] = []
    let onPrepareAssistant: () -> Void
    let onOpenProfessional: () -> Void
    let onShowTemplates: () -> Void
    let onTaskPersisted: (UUID) -> Void
    let onNavigate: (YouziSimpleDestination) -> Void

    /// Scene storage keeps an unfinished request intact while onboarding or
    /// Professional Mode temporarily replaces this presentation.
    @SceneStorage("YouziSimple.NewTask.draft.v1") private var draft = ""
    @State private var showsLiveVoice = false
    @State private var showsModelSelectionHelp = false
    // The voice sheet retains its preparation closure across multiple sends.
    // Keep a newly created task ID in shared State rather than a captured nil
    // taskID, which would otherwise create a second task on the next utterance.
    @State private var preparedTaskID: UUID?
    @State private var focusRequest = 0
    @State private var selectedWorkspaceID: UUID?
    @State private var selectedProjectID: UUID?
    @State private var selectedArtifactID: UUID?
    @State private var selectedScene = YouziTaskScene.writing
    @State private var selectedHelperID: UUID?
    @State private var selectedSkillIDs: [UUID] = []
    @State private var selectedConnectorIDs: [UUID] = []
    @SceneStorage("YouziSimple.Composer.referenceDrafts.v1") private var referenceDrafts = "{}"
    private struct ReferenceDraft: Codable {
        var helper: UUID?
        var skills: [UUID]
        var connectors: [UUID]
    }
    @State private var fileImportError: String?



    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                if let project = currentProject {
                    projectBreadcrumb(project)
                    Divider()
                }
                if chat.messages.isEmpty {
                    welcome
                } else {
                    transcript
                    Divider()
                    composer
                }
            }

            if currentProject != nil, let artifact = selectedArtifact {
                Divider()
                projectArtifactPreview(artifact)
                    .frame(minWidth: 260, idealWidth: 300, maxWidth: 360)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RapidTheme.surfaceCanvas)
        .modifier(YouziChatMediaPresentation(conversationID: chat.activeConversationID))
        .accessibilityIdentifier("YouziSimple.Surface.newTask")
        .modifier(YouziLiveVoicePresentation(
            chat: chat, server: server, alias: assistantAlias,
            prepareTurn: prepareTaskRequest, isPresented: $showsLiveVoice
        ))
        .alert(i18n.text(zh: "请选择聊天模型", en: "Choose a chat model"), isPresented: $showsModelSelectionHelp) {
            Button(i18n.text(zh: "知道了", en: "OK"), role: .cancel) {}
        } message: {
            Text(i18n.text(zh: "请从输入框旁的模型菜单选择一个已下载模型，或在模型设置中选择优先模型。你的输入已保留。", en: "Choose a downloaded model beside the composer, or choose a preferred model in Model Settings. Your draft is preserved."))
        }
        .onAppear {
            loadTaskContext()
            resolveAssistantAliasIfNeeded()
        }
        .onChange(of: taskID) { _, _ in loadTaskContext() }
        .onChange(of: projectID) { _, newValue in
            selectedProjectID = newValue
        }
        .onChange(of: catalogEntries) { _, _ in
            resolveAssistantAliasIfNeeded()
        }
        .onChange(of: server.state) { _, _ in
            resolveAssistantAliasIfNeeded()
        }
        .onChange(of: server.remoteModelSettings.document.preferredModels) { _, _ in
            guard chat.messages.isEmpty, !chat.isStreaming else { return }
            assistantAlias = server.automaticModelAlias(for: .chat, entries: downloadedChatModels) ?? ""
        }
        .onChange(of: selectedHelperID) { _, _ in persistReferences() }
        .onChange(of: selectedSkillIDs) { _, _ in persistReferences() }
        .onChange(of: selectedConnectorIDs) { _, _ in persistReferences() }
        .alert(i18n.text(zh: "没有添加文件", en: "No files added"), isPresented: fileImportAlertBinding) {
            Button(i18n.text(zh: "好", en: "OK"), role: .cancel) {}
                .accessibilityIdentifier("YouziSimpleTaskView.Button.2a749ebe68")
        } message: {
            Text(fileImportError ?? i18n.text(zh: "请重试。", en: "Please try again."))
        }
    }

    private var currentProject: YouziProject? {
        guard let selectedProjectID else { return nil }
        return productModel.project(id: selectedProjectID)
    }

    private var projectArtifacts: [YouziArtifact] {
        guard let selectedProjectID else { return [] }
        return productModel.artifacts
            .filter { $0.projectID == selectedProjectID && $0.state != .archived }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var selectedArtifact: YouziArtifact? {
        guard let selectedArtifactID else { return nil }
        return productModel.artifact(id: selectedArtifactID)
    }

    private func projectBreadcrumb(_ project: YouziProject) -> some View {
        HStack(spacing: RapidTheme.Space.sm) {
            Label(i18n.text(zh: "工作空间", en: "Workspaces"), systemImage: "folder")
            Image(systemName: "chevron.right")
                .foregroundStyle(RapidTheme.textSecondary)
            Text(project.name)
                .font(RapidFont.bodyEmphasis)
            Spacer(minLength: 0)
            if !projectFiles.isEmpty {
                Menu(i18n.text(zh: "项目资料", en: "Project Files")) {
                    ForEach(projectFiles) { file in
                        Button(file.displayName) { openProjectFile(file) }
                            .accessibilityIdentifier("YouziSimpleTaskView.Button.69751f794d")
                    }
                }
                .menuStyle(.borderlessButton)
                .accessibilityIdentifier("YouziSimple.Project.Files")
            }
            if !projectArtifacts.isEmpty {
                Menu(i18n.text(zh: "项目成果", en: "Project Deliverables")) {
                    ForEach(projectArtifacts) { artifact in
                        Button(artifact.title) { selectedArtifactID = artifact.id }
                            .accessibilityIdentifier("YouziSimpleTaskView.Button.78cb8a6c0e")
                    }
                }
                .menuStyle(.borderlessButton)
                .accessibilityIdentifier("YouziSimple.Project.Artifacts")
            }
        }
        .font(RapidFont.secondary)
        .padding(.horizontal, RapidTheme.Space.xl)
        .frame(minHeight: 44)
        .accessibilityIdentifier("YouziSimple.Project.Breadcrumb")
    }

    private func projectArtifactPreview(_ artifact: YouziArtifact) -> some View {
        VStack(alignment: .leading, spacing: RapidTheme.Space.md) {
            HStack {
                Text(i18n.text(zh: "成果预览", en: "Deliverable Preview"))
                    .font(RapidFont.sectionTitle)
                Spacer(minLength: 0)
                Button {
                    selectedArtifactID = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(i18n.text(zh: "关闭成果预览", en: "Close preview"))
                    .accessibilityIdentifier("YouziSimpleTaskView.Button.0fdd22935e")
            }
            Text(artifact.title)
                .font(RapidFont.bodyEmphasis)
            if let preview = artifact.previewText, !preview.isEmpty {
                ScrollView {
                    Text(preview)
                        .font(RapidFont.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text(i18n.text(zh: "这份成果没有可显示的文本预览。", en: "This deliverable does not have a text preview."))
                    .font(RapidFont.secondary)
                    .foregroundStyle(RapidTheme.textSecondary)
            }
        }
        .padding(RapidTheme.Space.lg)
        .background(RapidTheme.surfaceRaised)
        .accessibilityIdentifier("YouziSimple.Project.ArtifactPreview")
    }

    private var welcome: some View {
        YouziCenteredWelcome {
            VStack(spacing: 24) {
                YouziLogo(size: 42)

                VStack(spacing: RapidTheme.Space.xs) {
                    Text(i18n.text(zh: "今天想让我帮你做什么？", en: "What would you like to do today?"))
                        .font(.system(size: max(20, round(28 * RapidFont.fontScale)), weight: .semibold))
                        .tracking(RapidFont.displayTitleTracking)
                        .multilineTextAlignment(.center)
                    Text(i18n.text(zh: "选一个场景，或直接告诉柚子你想完成什么。", en: "Choose a workflow, or tell Youzi what you’d like to do."))
                        .font(RapidFont.displaySubtitle)
                        .foregroundStyle(RapidTheme.textSecondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 12) {
                    YouziTaskSceneTabs(selection: $selectedScene)
                        .padding(.horizontal, RapidTheme.Space.xl)
                    composer
                    YouziTaskSceneSuggestions(scene: selectedScene) { prompt in
                        let current = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        draft = current.isEmpty ? prompt : current + "\n" + prompt
                        focusRequest &+= 1
                    }.padding(.horizontal, RapidTheme.Space.xl)
                }.frame(maxWidth: 860)

            }
            .accessibilityIdentifier("YouziSimple.Welcome.Content")
        }
    }

    private var toolResults: [String: ChatMessage] {
        Dictionary(chat.messages.compactMap { message in
            guard message.role == .tool, let id = message.toolCallID else { return nil }
            return (id, message)
        }, uniquingKeysWith: { _, last in last })
    }

    private var artifactIDs: Set<UUID> {
        SimpleTranscriptPresentation.artifactIDs(in: chat.messages)
    }

    private var transcript: some View {
        let artifactIDs = artifactIDs
        let toolResults = toolResults
        return YouziSimpleTranscript(messages: chat.messages, followsReply: !showsLiveVoice) { message in
            if SimpleTranscriptPresentation.isVisible(message) {
                simpleMessage(message, artifactIDs: artifactIDs, toolResults: toolResults)
            }
        }
    }

    @ViewBuilder
    private func simpleMessage(_ message: ChatMessage, artifactIDs: Set<UUID>, toolResults: [String: ChatMessage]) -> some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 80)
                VStack(alignment: .leading, spacing: RapidTheme.Space.sm) {
                    if !message.content.isEmpty {
                        Text(message.content)
                            .font(RapidFont.body)
                            .textSelection(.enabled)
                    }
                    if !message.imageAttachments.isEmpty || !message.fileAttachments.isEmpty {
                        Label(i18n.text(zh: "已添加资料", en: "Attachments added"), systemImage: "paperclip")
                            .font(RapidFont.caption)
                            .foregroundStyle(RapidTheme.textSecondary)
                    }
                }
                .padding(.horizontal, RapidTheme.Space.lg)
                .padding(.vertical, RapidTheme.Space.md)
                .background(
                    RoundedRectangle(cornerRadius: RapidTheme.Radius.bubble, style: .continuous)
                        .fill(RapidTheme.userBubble)
                )
            }

        case .assistant:
            HStack(alignment: .top, spacing: RapidTheme.Space.md) {
                YouziLogo(size: 24)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: RapidTheme.Space.sm) {
                    if message.toolCallArtifactSuppressed || artifactIDs.contains(message.id) {
                        Label(i18n.text(zh: "工具调用未完成，模型没有给出有效回答。可以重试或更换模型。", en: "Tool use did not finish and the model produced no usable answer. Retry or choose another model."), systemImage: "exclamationmark.bubble")
                            .font(RapidFont.body).foregroundStyle(RapidTheme.textSecondary)
                    } else if message.content.isEmpty && message.status == .streaming
                                && (message.toolCalls?.isEmpty ?? true) {
                        ChatWaitingHint()
                    } else if message.wireVisibility == .transcriptOnly {
                        Text(i18n.text(zh: "已经准备好了，今天想让我帮你做什么？", en: "I'm ready! What would you like to do today?"))
                            .font(RapidFont.body)
                    } else if message.status == .streaming {
                        Text(message.content)
                            .font(RapidFont.body)
                            .textSelection(.enabled)
                    } else {
                        TextKitMarkdownView(content: message.content)
                            .textSelection(.enabled)
                    }

                    if let calls = message.toolCalls, !calls.isEmpty {
                        ForEach(calls) { call in
                            ToolCallChip(call: call, result: toolResults[call.id])
                            YouziChatArtifactCard(call: call, result: toolResults[call.id], conversationID: chat.activeConversationID)
                            if let result = toolResults[call.id],
                               SimpleTranscriptPresentation.hasFakeIPFailure(result) {
                                Text(i18n.text(zh: "域名返回代理 Fake-IP，当前安全策略阻止了访问。若使用可信本机代理，请在「安全中心」开启「兼容本机代理」后重试。", en: "DNS returned a proxy Fake-IP blocked by the current policy. For a trusted local proxy, enable Local Proxy Compatibility in Security and retry."))
                                    .font(RapidFont.caption).foregroundStyle(RapidTheme.textSecondary)
                            }
                        }
                    }
                    if !message.reasoning.isEmpty {
                        DisclosureGroup(i18n.text(zh: "思考过程", en: "Reasoning")) {
                            Text(message.reasoning).font(RapidFont.secondary).textSelection(.enabled)
                        }
                        .font(RapidFont.caption).foregroundStyle(RapidTheme.textSecondary)
                            .accessibilityIdentifier("YouziSimpleTaskView.DisclosureGroup.cfe669a0b5")
                    }
                    if let error = message.errorMessage, !error.isEmpty, message.status != .failed {
                        Text(error).font(RapidFont.caption).foregroundStyle(RapidTheme.textSecondary)
                    }
                    if message.status == .failed {
                        Label(i18n.text(zh: "这次没有完成，可以再试一次。", en: "Could not complete this turn. Please try again."), systemImage: "arrow.clockwise")
                            .font(RapidFont.caption)
                            .foregroundStyle(RapidTheme.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

        case .system, .unknown:
            Text(message.content)
                .font(RapidFont.secondary)
                .foregroundStyle(RapidTheme.textSecondary)
                .padding(RapidTheme.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: RapidTheme.Radius.card, style: .continuous)
                        .fill(RapidTheme.surfaceRaised)
                )

        case .tool:
            EmptyView()
        }
    }

    private var composer: some View {
        let contentWidth: CGFloat = chat.messages.isEmpty ? 860 : RapidTheme.Layout.contentMaxWidth
        return VStack(spacing: RapidTheme.Space.sm) {
            if showsLiveVoice { YouziLiveVoiceInlineControls(isPresented: $showsLiveVoice) }
            if needsAttention {
                HStack(spacing: RapidTheme.Space.sm) {
                    Image(systemName: "exclamationmark.circle")
                    Text(i18n.text(zh: "柚子需要处理一个问题后才能继续。", en: "Youzi needs to resolve an issue before continuing."))
                    Spacer(minLength: 0)
                    Button(i18n.text(zh: "在专业模式中处理", en: "Resolve in Professional Mode"), action: onOpenProfessional)
                        .buttonStyle(.link)
                        .accessibilityIdentifier("YouziSimple.NewTask.OpenProfessional")
                }
                .font(RapidFont.secondary)
                .foregroundStyle(RapidTheme.textSecondary)
                .frame(maxWidth: contentWidth)
            }

            VStack(alignment: .leading, spacing: RapidTheme.Space.sm) {
                selectedReferences
                ComposeField(
                    text: $draft,
                    focusToken: focusRequest,
                    isStreaming: chat.isStreaming,
                    placeholder: i18n.text(zh: "想让柚子帮你做什么？", en: "What would you like Youzi to do?"),
                    onSubmit: submit,
                    onCancel: { chat.stop() },
                    onRecallLastUser: {
                        chat.messages.last(where: { $0.role == .user })?.content
                    },
                    axIdentifier: "YouziSimple.NewTask.Input",
                    axLabel: i18n.text(zh: "新任务请求", en: "New task request"),
                    axRoleDescription: i18n.text(zh: "任务请求输入框", en: "Task request input")
                )

                .frame(minHeight: chat.messages.isEmpty ? 88 : 44, alignment: .top)

                HStack(spacing: RapidTheme.Space.sm) {
                    Menu {
                        Button(i18n.text(zh: "导入文件副本…", en: "Import File Copy…")) {
                            importFile(mode: .copy, target: .task)
                        }
                            .accessibilityIdentifier("YouziSimpleTaskView.Button.fad9a4d805")
                        Button(i18n.text(zh: "引用本地文件…", en: "Reference Local File…")) {
                            importFile(mode: .reference, target: .task)
                        }
                            .accessibilityIdentifier("YouziSimpleTaskView.Button.150e3b5583")

                        Divider()
                        Menu(i18n.text(zh: "专家", en: "Experts")) {
                            ForEach(productModel.document.helpers.filter { $0.state == .active }) { helper in
                                Button(helper.name) {
                                    selectedHelperID = helper.id
                                    focusRequest &+= 1
                                }
                                    .accessibilityIdentifier("YouziSimpleTaskView.Button.9e348b9044")
                            }
                        }
                            .accessibilityIdentifier("YouziSimpleTaskView.Menu.f25632e2ea")

                        Menu(i18n.text(zh: "技能", en: "Skills")) {
                            ForEach(productModel.document.skills.filter { $0.state == .active }) { skill in
                                Button(skill.name) {
                                    if !selectedSkillIDs.contains(skill.id) { selectedSkillIDs.append(skill.id) }
                                    focusRequest &+= 1
                                    productModel.markSkillUsed(skill.id)
                                }
                                    .accessibilityIdentifier("YouziSimpleTaskView.Button.e7fd73f4b6")
                            }
                        }
                            .accessibilityIdentifier("YouziSimpleTaskView.Menu.458e538ec0")

                        Menu(i18n.text(zh: "连接器", en: "Connectors")) {
                            ForEach(productModel.document.connectors.filter { $0.state == .active }) { connector in
                                Button(connector.name) {
                                    if !selectedConnectorIDs.contains(connector.id) { selectedConnectorIDs.append(connector.id) }
                                    focusRequest &+= 1
                                }
                                    .accessibilityIdentifier("YouziSimpleTaskView.Button.0c91261a94")
                            }
                        }
                            .accessibilityIdentifier("YouziSimpleTaskView.Menu.f0e167a6b7")

                        Divider()

                        Divider()
                        if currentProject != nil {
                            Divider()
                            Button(i18n.text(zh: "向项目添加资料副本…", en: "Add File Copy to Project…")) {
                                importFile(mode: .copy, target: .project)
                            }
                                .accessibilityIdentifier("YouziSimpleTaskView.Button.ec74df28b1")
                            Button(i18n.text(zh: "向项目引用本地资料…", en: "Reference Local File in Project…")) {
                                importFile(mode: .reference, target: .project)
                            }
                                .accessibilityIdentifier("YouziSimpleTaskView.Button.199a32a255")
                            if !readableProjectFiles.isEmpty {
                                Menu(i18n.text(zh: "使用已有项目资料", en: "Use Existing Project Files")) {
                                    ForEach(readableProjectFiles) { file in
                                        Button(file.displayName) { attachProjectFileToTask(file) }
                                            .accessibilityIdentifier("YouziSimpleTaskView.Button.7c265db1ee")
                                    }
                                }
                                    .accessibilityIdentifier("YouziSimpleTaskView.Menu.4d61b7411e")
                            }
                        }

                        Divider()
                        Button(i18n.text(zh: "从模板开始…", en: "Start from Template…"), action: onShowTemplates)
                            .accessibilityIdentifier("YouziSimpleTaskView.Button.dc919abd3c")
                        Button(i18n.text(zh: "管理专家、技能与连接器…", en: "Manage Experts, Skills & Connectors…")) { onNavigate(.helpers) }
                            .accessibilityIdentifier("YouziSimpleTaskView.Button.1f017082b2")
                    } label: {
                        Image(systemName: "plus").font(.system(size: 17)).frame(width: 30, height: 30)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel(i18n.text(zh: "添加文件、专家、技能或连接器", en: "Add files, experts, skills or connectors"))
                    .accessibilityIdentifier("YouziSimple.NewTask.Add")

                    if !currentTaskFiles.isEmpty {
                        Label(i18n.text(zh: "\(currentTaskFiles.count) 份资料", en: "\(currentTaskFiles.count) files"), systemImage: "paperclip")
                            .font(RapidFont.caption)
                            .foregroundStyle(RapidTheme.textSecondary)
                    }

                    Spacer(minLength: 0)

                    if let helper = selectedHelper {
                        Menu {
                            Button(i18n.text(zh: "取消专家选择", en: "Clear expert")) { selectedHelperID = nil }
                            Divider()
                            ForEach(productModel.helpers.filter { $0.state == .active }) { item in
                                Button(item.name) { selectedHelperID = item.id }
                            }
                        } label: { Label(helper.name, systemImage: "person.crop.circle").lineLimit(1) }
                            .font(RapidFont.caption).menuStyle(.borderlessButton).frame(maxWidth: 140)
                            .accessibilityIdentifier("YouziSimple.SelectedExpert")
                    }
                    modelQuickPicker

                    YouziContextUsageRing(messages: chat.messages, alias: assistantAlias)

                    YouziComposerIconButton(
                        symbol: chat.isStreaming ? "stop.fill" : "arrow.up",
                        label: chat.isStreaming ? i18n.text(zh: "停止任务", en: "Stop task") : i18n.text(zh: "开始任务", en: "Start task"),
                        enabled: chat.isStreaming || canSubmit
                    ) {
                        if chat.isStreaming { chat.stop() } else { submit() }
                    }
                    .help(chat.isStreaming ? i18n.text(zh: "停止", en: "Stop") : i18n.text(zh: "开始任务", en: "Start task"))
                    .accessibilityIdentifier("YouziSimple.NewTask.SendOrStop")

                    YouziLiveVoiceButton(isPresented: $showsLiveVoice, compact: true)
                }
            }
            .padding(.horizontal, RapidTheme.Space.md)
            .padding(.vertical, RapidTheme.Space.sm)
            .background(
                RoundedRectangle(cornerRadius: RapidTheme.Radius.input, style: .continuous)
                    .fill(RapidTheme.surfaceRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RapidTheme.Radius.input, style: .continuous)
                    .strokeBorder(RapidTheme.hairlineStrong, lineWidth: 1)
            )
            .frame(maxWidth: contentWidth)
            HStack(spacing: 16) {
                        Menu(currentWorkspace?.name ?? i18n.text(zh: "工作空间：自动管理", en: "Workspace: managed")) {
                            Button(i18n.text(zh: "由柚子在开始时管理", en: "Managed by Youzi at start")) {
                                selectWorkspace(nil)
                            }
                                .accessibilityIdentifier("YouziSimpleTaskView.Button.f0e6e6b312")
                            ForEach(activeWorkspaces) { workspace in
                                Button(workspace.name) { selectWorkspace(workspace.id) }
                                    .accessibilityIdentifier("YouziSimpleTaskView.Button.3f2cdaaa0c")
                            }
                            Divider()
                            Button(i18n.text(zh: "管理工作空间…", en: "Manage Workspaces…")) { onNavigate(.workspaces) }
                                .accessibilityIdentifier("YouziSimpleTaskView.Button.f8d3623359")
                        }
                            .accessibilityIdentifier("YouziSimpleTaskView.Menu.073cb55317")

                        Menu(currentProject?.name ?? i18n.text(zh: "项目：未选择", en: "Project: none")) {
                            Button(i18n.text(zh: "不放入项目", en: "No Project")) { selectProject(nil) }
                                .accessibilityIdentifier("YouziSimpleTaskView.Button.03c3cf3e2c")
                            ForEach(activeProjects) { project in
                                Button(project.name) { selectProject(project.id) }
                                    .accessibilityIdentifier("YouziSimpleTaskView.Button.a293291eae")
                            }
                            Divider()
                            Button(i18n.text(zh: "管理项目…", en: "Manage Projects…")) { onNavigate(.workspaces) }
                                .accessibilityIdentifier("YouziSimpleTaskView.Button.56aa8c1007")
                        }
                            .accessibilityIdentifier("YouziSimpleTaskView.Menu.3df50ff4d9")

                Spacer(minLength: 0)
            }
            .font(RapidFont.caption).foregroundStyle(RapidTheme.textSecondary).lineLimit(1)
            .menuStyle(.borderlessButton).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: contentWidth, alignment: .leading)
            .accessibilityIdentifier("YouziSimple.Composer.Workspace")
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, RapidTheme.Space.xl)
        .padding(.vertical, chat.messages.isEmpty ? 0 : RapidTheme.Space.md)
        .background(RapidTheme.surfaceCanvas)
    }

    private var canSubmit: Bool {
        !chat.isStreaming && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var downloadedChatModels: [ModelEntry] {
        catalogEntries.filter { $0.kind == .chat && $0.cached }
    }

    private var modelQuickPicker: some View {
        YouziScenarioModelPicker(assistantAlias: $assistantAlias, chatEntries: catalogEntries, chatIsStreaming: chat.isStreaming, showsSelectionName: true)
    }

    private var selectedHelper: YouziHelper? {
        selectedHelperID.flatMap(productModel.helper(id:))
    }

    @ViewBuilder private var selectedReferences: some View {
        if !selectedSkillIDs.isEmpty || !selectedConnectorIDs.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(selectedSkillIDs.compactMap(productModel.skill(id:))) { skill in
                        referenceChip(skill.name, symbol: "bolt") { selectedSkillIDs.removeAll { $0 == skill.id } }
                    }
                    ForEach(selectedConnectorIDs.compactMap(productModel.connector(id:))) { connector in
                        referenceChip(connector.name, symbol: "link") { selectedConnectorIDs.removeAll { $0 == connector.id } }
                    }
                }
            }.accessibilityIdentifier("YouziSimple.Composer.References")
        }
    }

    private func referenceChip(_ title: String, symbol: String, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 5) {
            Label(title, systemImage: symbol).lineLimit(1)
            Button(action: remove) { Image(systemName: "xmark").font(.system(size: 9)) }
                .buttonStyle(.plain).accessibilityLabel(i18n.text(zh: "移除引用：", en: "Remove reference: ") + title)
        }.font(RapidFont.caption).padding(.horizontal, 9).padding(.vertical, 6)
            .background(RapidTheme.brandPrimaryTint, in: Capsule())
            .foregroundStyle(RapidTheme.brandPrimary)
    }

    private var storedReferenceDrafts: [String: ReferenceDraft] {
        (try? JSONDecoder().decode([String: ReferenceDraft].self, from: Data(referenceDrafts.utf8))) ?? [:]
    }

    private func persistReferences() {
        var records = storedReferenceDrafts
        records[(preparedTaskID ?? taskID)?.uuidString ?? "new"] = ReferenceDraft(helper: selectedHelperID, skills: selectedSkillIDs, connectors: selectedConnectorIDs)
        if let data = try? JSONEncoder().encode(records) { referenceDrafts = String(decoding: data, as: UTF8.self) }
    }

    private func restoreReferences(for task: YouziTask?) {
        let saved = storedReferenceDrafts[task?.id.uuidString ?? "new"]
        selectedHelperID = (saved?.helper ?? task?.helperID).flatMap { productModel.helper(id: $0)?.state == .active ? $0 : nil }
        selectedSkillIDs = (saved?.skills ?? task?.skillIDs ?? []).filter { productModel.skill(id: $0)?.state == .active }
        selectedConnectorIDs = (saved?.connectors ?? []).filter { productModel.connector(id: $0)?.state == .active }
    }

    private func requestWithReferences(_ request: String) -> String {
        var references = selectedHelper.map { ["@" + $0.name] } ?? []
        references += selectedSkillIDs.compactMap(productModel.skill(id:)).map { "/" + $0.name }
        references += selectedConnectorIDs.compactMap(productModel.connector(id:)).map { "#" + $0.name }
        return references.isEmpty ? request : request + "\n\n" + references.joined(separator: " ")
    }

    private func resolveAssistantAliasIfNeeded() {
        // Keep an explicit remote selection, even disabled: fail visibly, never silently send elsewhere.
        if RemoteModelEndpoint.isRemote(assistantAlias) { return }
        if !assistantAlias.isEmpty,
           downloadedChatModels.contains(where: { $0.alias == assistantAlias }) {
            return
        }
        // An empty selection is not permission to pick any downloaded model.
        // Use the preferred pool or leave the choice to the user.
        assistantAlias = server.automaticModelAlias(for: .chat, entries: downloadedChatModels) ?? ""
    }

    private enum FileImportTarget: Equatable {
        case task
        case project
    }

    private var activeWorkspaces: [YouziWorkspace] {
        productModel.workspaces.filter { $0.state == .active }
    }

    private var activeProjects: [YouziProject] {
        productModel.projects.filter { $0.state == .active }
    }

    private var currentWorkspace: YouziWorkspace? {
        guard let selectedWorkspaceID else { return nil }
        return productModel.workspace(id: selectedWorkspaceID)
    }

    private var projectFiles: [YouziFile] {
        guard let project = currentProject else { return [] }
        return project.resourceFileIDs.compactMap(productModel.file(id:))
    }

    private var readableProjectFiles: [YouziFile] {
        projectFiles.filter { ChatFileAttachment.recognizesDocument(at: URL(fileURLWithPath: $0.displayName)) }
    }

    private var currentTaskFiles: [YouziFile] {
        guard let taskID, let task = productModel.task(id: taskID) else { return [] }
        return task.inputFileIDs.compactMap(productModel.file(id:))
    }

    private func loadTaskContext() {
        preparedTaskID = taskID
        restoreReferences(for: taskID.flatMap(productModel.task(id:)))
        guard let taskID, let task = productModel.task(id: taskID) else {
            selectedProjectID = projectID
            selectedWorkspaceID = nil
            selectedArtifactID = projectArtifacts.first?.id
            return
        }
        selectedProjectID = task.projectID ?? projectID
        selectedWorkspaceID = task.workspaceID
        selectedArtifactID = projectArtifacts.first?.id
        if chat.messages.isEmpty {
            draft = task.request
            focusRequest &+= 1
        }
    }

    private func selectWorkspace(_ id: UUID?) {
        selectedWorkspaceID = id
        if let taskID {
            productModel.assignWorkspace(id, toTask: taskID)
        }
    }

    private func selectProject(_ id: UUID?) {
        selectedProjectID = id
        if let taskID {
            productModel.moveTask(taskID, toProject: id)
        }
    }

    private func ensureTaskDraft(request: String? = nil) -> YouziTask? {
        if let id = taskID ?? preparedTaskID, let task = productModel.task(id: id) {
            return task
        }
        let request = (request ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        let title = request.isEmpty ? i18n.text(zh: "未命名任务", en: "Untitled Task") : taskTitle(from: request)
        guard let task = productModel.createTaskDraft(
            title: title,
            request: request,
            projectID: selectedProjectID
        ) else {
            fileImportError = i18n.text(zh: "无法创建任务草稿。", en: "Could not create task draft.")
            return nil
        }
        if let selectedWorkspaceID {
            productModel.assignWorkspace(selectedWorkspaceID, toTask: task.id)
        }
        preparedTaskID = task.id
        persistReferences()
        onTaskPersisted(task.id)
        return productModel.task(id: task.id) ?? task
    }

    private func importFile(mode: YouziFileImportMode, target: FileImportTarget) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = mode == .copy ? i18n.text(zh: "导入副本", en: "Import Copy") : i18n.text(zh: "引用文件", en: "Reference File")
        if target == .task {
            panel.allowedContentTypes = [.pdf, .commaSeparatedText, .plainText]
        }
        guard panel.runModal() == .OK, let URL = panel.url else { return }

        let attachmentTarget: YouziFileAttachmentTarget
        switch target {
        case .task:
            guard let task = ensureTaskDraft() else { return }
            attachmentTarget = .task(task.id)
        case .project:
            guard let selectedProjectID else {
                fileImportError = i18n.text(zh: "请先选择项目。", en: "Please select a project first.")
                return
            }
            attachmentTarget = .project(selectedProjectID)
        }
        if productModel.importFile(at: URL, mode: mode, attachingTo: attachmentTarget) == nil {
            fileImportError = i18n.text(zh: "无法添加这个文件。", en: "Could not add this file.")
        }
    }

    private func attachProjectFileToTask(_ file: YouziFile) {
        guard let task = ensureTaskDraft() else { return }
        productModel.referenceProjectFile(file.id, toTask: task.id)
        if productModel.lastPersistenceError != nil {
            fileImportError = i18n.text(zh: "无法把这份项目资料添加到任务。", en: "Could not add this project file to task.")
        }
    }

    private func openProjectFile(_ file: YouziFile) {
        do {
            try productModel.withFileURL(id: file.id) { URL in
                guard NSWorkspace.shared.open(URL) else {
                    throw CocoaError(.fileReadUnknown)
                }
            }
        } catch {
            fileImportError = i18n.text(zh: "无法打开这份项目资料。", en: "Could not open this project file.")
        }
    }

    private func taskTitle(from request: String) -> String {
        let firstLine = request.split(whereSeparator: \.isNewline).first.map(String.init) ?? request
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(48))
    }

    private func chatAttachments(for task: YouziTask) throws -> [ChatFileAttachment] {
        try task.inputFileIDs.prefix(ChatFileAttachment.maxAttachmentsPerMessage).compactMap { id in
            guard productModel.file(id: id) != nil else { return nil }
            return try productModel.withFileURL(id: id) { URL in
                try ChatFileAttachment(contentsOf: URL)
            }
        }
    }

    private var fileImportAlertBinding: Binding<Bool> {
        Binding(
            get: { fileImportError != nil },
            set: { if !$0 { fileImportError = nil } }
        )
    }

    private var needsAttention: Bool {
        if chat.lastError != nil { return true }
        return switch server.state {
        case .missing, .crashed: true
        case .idle, .starting, .ready, .stopped: false
        }
    }

    private func submit() {
        let request = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, !chat.isStreaming else { return }
        resolveAssistantAliasIfNeeded()
        guard !assistantAlias.isEmpty else {
            showsModelSelectionHelp = true
            return
        }
        guard let attachments = prepareTaskRequest(request) else { return }
        draft = ""
        focusRequest &+= 1
        chat.send(requestWithReferences(request), alias: assistantAlias, fileAttachments: attachments)
        var records = storedReferenceDrafts
        records.removeValue(forKey: "new")
        if let data = try? JSONEncoder().encode(records) { referenceDrafts = String(decoding: data, as: UTF8.self) }
    }

    /// Text and voice share task/workspace preparation and attachment handling.
    /// Voice does not consume or clear the user's unfinished typed draft.
    private func prepareTaskRequest(_ request: String) -> [ChatFileAttachment]? {
        guard var task = ensureTaskDraft(request: request) else { return nil }
        task.title = (task.title == "未命名任务" || task.title == "Untitled Task") ? taskTitle(from: request) : task.title
        task.request = request
        task.helperID = selectedHelperID
        task.skillIDs = selectedSkillIDs
        task.updatedAt = Date()
        productModel.save(task)
        productModel.assignWorkspace(selectedWorkspaceID, toTask: task.id)
        productModel.moveTask(task.id, toProject: selectedProjectID)
        let attachments: [ChatFileAttachment]
        do {
            attachments = try chatAttachments(for: productModel.task(id: task.id) ?? task)
        } catch {
            fileImportError = i18n.text(zh: "无法读取已添加的任务资料。", en: "Could not read added task files.")
            return nil
        }
        guard productModel.beginTaskExecution(
            taskID: task.id,
            conversationID: chat.activeConversationID
        ) != nil else {
            fileImportError = i18n.text(zh: "无法准备任务的工作空间。", en: "Could not prepare workspace for task.")
            return nil
        }
        return attachments
    }

}
