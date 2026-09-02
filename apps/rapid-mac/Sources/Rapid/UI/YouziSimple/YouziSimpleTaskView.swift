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

    let taskID: UUID?
    let projectID: UUID?
    let assistantAlias: String
    let onPrepareAssistant: () -> Void
    let onOpenProfessional: () -> Void
    let onShowTemplates: () -> Void
    let onTaskPersisted: (UUID) -> Void
    let onNavigate: (YouziSimpleDestination) -> Void

    /// Scene storage keeps an unfinished request intact while onboarding or
    /// Professional Mode temporarily replaces this presentation.
    @SceneStorage("YouziSimple.NewTask.draft.v1") private var draft = ""
    @State private var focusRequest = 0
    @State private var selectedWorkspaceID: UUID?
    @State private var selectedProjectID: UUID?
    @State private var selectedArtifactID: UUID?
    @State private var fileImportError: String?

    private struct Suggestion: Identifiable {
        let id: String
        let title: String
    }

    private let suggestions = [
        Suggestion(id: "summarize-a-document", title: "整理一份文档"),
        Suggestion(id: "plan-my-week", title: "规划我的一周"),
        Suggestion(id: "draft-a-thoughtful-message", title: "帮我写一条用心的消息"),
        Suggestion(id: "help-me-explore-an-idea", title: "和我一起理清一个想法"),
    ]

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
                }
                Divider()
                composer
            }

            if currentProject != nil, let artifact = selectedArtifact {
                Divider()
                projectArtifactPreview(artifact)
                    .frame(minWidth: 260, idealWidth: 300, maxWidth: 360)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RapidTheme.surfaceCanvas)
        .accessibilityIdentifier("YouziSimple.Surface.newTask")
        .onAppear(perform: loadTaskContext)
        .onChange(of: taskID) { _, _ in loadTaskContext() }
        .onChange(of: projectID) { _, newValue in
            selectedProjectID = newValue
        }
        .alert("没有添加文件", isPresented: fileImportAlertBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(fileImportError ?? "请重试。")
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
            Label("工作空间", systemImage: "folder")
            Image(systemName: "chevron.right")
                .foregroundStyle(RapidTheme.textSecondary)
            Text(project.name)
                .font(RapidFont.bodyEmphasis)
            Spacer(minLength: 0)
            if !projectFiles.isEmpty {
                Menu("项目资料") {
                    ForEach(projectFiles) { file in
                        Button(file.displayName) { openProjectFile(file) }
                    }
                }
                .menuStyle(.borderlessButton)
                .accessibilityIdentifier("YouziSimple.Project.Files")
            }
            if !projectArtifacts.isEmpty {
                Menu("项目成果") {
                    ForEach(projectArtifacts) { artifact in
                        Button(artifact.title) { selectedArtifactID = artifact.id }
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
                Text("成果预览")
                    .font(RapidFont.sectionTitle)
                Spacer(minLength: 0)
                Button {
                    selectedArtifactID = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭成果预览")
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
                Text("这份成果没有可显示的文本预览。")
                    .font(RapidFont.secondary)
                    .foregroundStyle(RapidTheme.textSecondary)
            }
        }
        .padding(RapidTheme.Space.lg)
        .background(RapidTheme.surfaceRaised)
        .accessibilityIdentifier("YouziSimple.Project.ArtifactPreview")
    }

    private var welcome: some View {
        ScrollView {
            VStack(spacing: RapidTheme.Space.xl) {
                YouziLogo(size: 92)

                VStack(spacing: RapidTheme.Space.sm) {
                    Text("今天想让我帮你做什么？")
                        .font(RapidFont.displayTitle)
                        .tracking(RapidFont.displayTitleTracking)
                        .multilineTextAlignment(.center)
                    Text("告诉柚子你想完成什么。你的内容会留在这台 Mac 上。")
                        .font(RapidFont.displaySubtitle)
                        .foregroundStyle(RapidTheme.textSecondary)
                        .multilineTextAlignment(.center)
                }

                Button {
                    onShowTemplates()
                } label: {
                    Label("从模板开始", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("YouziSimple.NewTask.ShowTemplates")

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: RapidTheme.Space.md),
                        GridItem(.flexible(), spacing: RapidTheme.Space.md),
                    ],
                    spacing: RapidTheme.Space.md
                ) {
                    ForEach(suggestions) { suggestion in
                        Button {
                            draft = suggestion.title
                            focusRequest &+= 1
                        } label: {
                            HStack(spacing: RapidTheme.Space.sm) {
                                Text(suggestion.title)
                                    .font(RapidFont.bodyEmphasis)
                                    .foregroundStyle(RapidTheme.textPrimary)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.up.right")
                                    .foregroundStyle(RapidTheme.textSecondary)
                            }
                            .padding(RapidTheme.Space.lg)
                            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                            .background(
                                RoundedRectangle(
                                    cornerRadius: RapidTheme.Radius.card,
                                    style: .continuous
                                )
                                .fill(RapidTheme.surfaceRaised)
                            )
                            .overlay(
                                RoundedRectangle(
                                    cornerRadius: RapidTheme.Radius.card,
                                    style: .continuous
                                )
                                .strokeBorder(RapidTheme.hairline, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(
                            "YouziSimple.NewTask.Suggestion.\(suggestion.id)"
                        )
                    }
                }
                .frame(maxWidth: 620)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, RapidTheme.Space.xl)
            .padding(.vertical, RapidTheme.Space.huge)
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: RapidTheme.Space.xl) {
                    ForEach(chat.messages) { message in
                        if message.role != .tool {
                            simpleMessage(message)
                                .id(message.id)
                        }
                    }
                }
                .frame(maxWidth: RapidTheme.Layout.contentMaxWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, RapidTheme.Space.xl)
                .padding(.vertical, RapidTheme.Space.xl)
            }
            .onChange(of: chat.messages.last?.content) { _, _ in
                if let lastID = chat.messages.last?.id {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func simpleMessage(_ message: ChatMessage) -> some View {
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
                        Label("已添加资料", systemImage: "paperclip")
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
                    if message.content.isEmpty && message.status == .streaming {
                        HStack(spacing: RapidTheme.Space.sm) {
                            ProgressView()
                                .controlSize(.small)
                            Text("正在处理…")
                                .font(RapidFont.secondary)
                                .foregroundStyle(RapidTheme.textSecondary)
                        }
                    } else if message.wireVisibility == .transcriptOnly {
                        Text("已经准备好了，今天想让我帮你做什么？")
                            .font(RapidFont.body)
                    } else if message.status == .streaming {
                        Text(message.content)
                            .font(RapidFont.body)
                            .textSelection(.enabled)
                    } else {
                        TextKitMarkdownView(content: message.content)
                            .textSelection(.enabled)
                    }

                    if message.status == .failed {
                        Label("这次没有完成，可以再试一次。", systemImage: "arrow.clockwise")
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
        VStack(spacing: RapidTheme.Space.sm) {
            if needsAttention {
                HStack(spacing: RapidTheme.Space.sm) {
                    Image(systemName: "exclamationmark.circle")
                    Text("柚子需要处理一个问题后才能继续。")
                    Spacer(minLength: 0)
                    Button("在专业模式中处理", action: onOpenProfessional)
                        .buttonStyle(.link)
                        .accessibilityIdentifier("YouziSimple.NewTask.OpenProfessional")
                }
                .font(RapidFont.secondary)
                .foregroundStyle(RapidTheme.textSecondary)
                .frame(maxWidth: RapidTheme.Layout.contentMaxWidth)
            }

            VStack(spacing: RapidTheme.Space.sm) {
                ComposeField(
                    text: $draft,
                    focusToken: focusRequest,
                    isStreaming: chat.isStreaming,
                    placeholder: "想让柚子帮你做什么？",
                    onSubmit: submit,
                    onCancel: { chat.stop() },
                    onRecallLastUser: {
                        chat.messages.last(where: { $0.role == .user })?.content
                    },
                    axIdentifier: "YouziSimple.NewTask.Input",
                    axLabel: "新任务请求",
                    axRoleDescription: "任务请求输入框"
                )

                HStack(spacing: RapidTheme.Space.sm) {
                    Menu {
                        Menu("工作空间") {
                            Button("由柚子在开始时管理") {
                                selectWorkspace(nil)
                            }
                            ForEach(activeWorkspaces) { workspace in
                                Button(workspace.name) { selectWorkspace(workspace.id) }
                            }
                            Divider()
                            Button("管理工作空间…") { onNavigate(.workspaces) }
                        }

                        Menu("项目") {
                            Button("不放入项目") { selectProject(nil) }
                            ForEach(activeProjects) { project in
                                Button(project.name) { selectProject(project.id) }
                            }
                            Divider()
                            Button("管理项目…") { onNavigate(.workspaces) }
                        }

                        Divider()
                        Button("导入文件副本…") {
                            importFile(mode: .copy, target: .task)
                        }
                        Button("引用本地文件…") {
                            importFile(mode: .reference, target: .task)
                        }

                        if currentProject != nil {
                            Divider()
                            Button("向项目添加资料副本…") {
                                importFile(mode: .copy, target: .project)
                            }
                            Button("向项目引用本地资料…") {
                                importFile(mode: .reference, target: .project)
                            }
                            if !readableProjectFiles.isEmpty {
                                Menu("使用已有项目资料") {
                                    ForEach(readableProjectFiles) { file in
                                        Button(file.displayName) { attachProjectFileToTask(file) }
                                    }
                                }
                            }
                        }

                        Divider()
                        Button("从模板开始…", action: onShowTemplates)
                        Button("选择帮手…") { onNavigate(.helpers) }
                    } label: {
                        Label("添加", systemImage: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityIdentifier("YouziSimple.NewTask.Add")

                    if let workspace = currentWorkspace {
                        Label(workspace.name, systemImage: "folder")
                            .font(RapidFont.caption)
                            .foregroundStyle(RapidTheme.textSecondary)
                            .lineLimit(1)
                    }

                    if !currentTaskFiles.isEmpty {
                        Label("\(currentTaskFiles.count) 份资料", systemImage: "paperclip")
                            .font(RapidFont.caption)
                            .foregroundStyle(RapidTheme.textSecondary)
                    }

                    Label(runtimeStatus, systemImage: runtimeSymbol)
                        .font(RapidFont.caption)
                        .foregroundStyle(RapidTheme.textSecondary)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    if chat.isStreaming {
                        Button(action: { chat.stop() }) {
                            Image(systemName: "stop.fill")
                                .frame(width: 28, height: 28)
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.bordered)
                        .help("停止")
                        .accessibilityLabel("停止任务")
                        .accessibilityIdentifier("YouziSimple.NewTask.SendOrStop")
                    } else {
                        Button(action: submit) {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(
                                    canSubmit ? RapidTheme.onBrandPrimary : RapidTheme.textSecondary
                                )
                                .frame(width: 28, height: 28)
                                .background(
                                    Circle().fill(
                                        canSubmit ? RapidTheme.brandPrimary : Color.clear
                                    )
                                )
                                .overlay(
                                    Circle().strokeBorder(
                                        canSubmit ? .clear : RapidTheme.hairlineStrong,
                                        lineWidth: 1
                                    )
                                )
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSubmit)
                        .help(assistantAlias.isEmpty ? "完成本地设置" : "开始任务")
                        .accessibilityLabel("开始任务")
                        .accessibilityIdentifier("YouziSimple.NewTask.SendOrStop")
                    }
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
            .frame(maxWidth: RapidTheme.Layout.contentMaxWidth)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, RapidTheme.Space.xl)
        .padding(.vertical, RapidTheme.Space.lg)
        .background(RapidTheme.surfaceCanvas)
    }

    private var canSubmit: Bool {
        !chat.isStreaming && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        if let taskID, let task = productModel.task(id: taskID) {
            return task
        }
        let request = (request ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        let title = request.isEmpty ? "未命名任务" : taskTitle(from: request)
        guard let task = productModel.createTaskDraft(
            title: title,
            request: request,
            projectID: selectedProjectID
        ) else {
            fileImportError = "无法创建任务草稿。"
            return nil
        }
        if let selectedWorkspaceID {
            productModel.assignWorkspace(selectedWorkspaceID, toTask: task.id)
        }
        onTaskPersisted(task.id)
        return productModel.task(id: task.id) ?? task
    }

    private func importFile(mode: YouziFileImportMode, target: FileImportTarget) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = mode == .copy ? "导入副本" : "引用文件"
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
                fileImportError = "请先选择项目。"
                return
            }
            attachmentTarget = .project(selectedProjectID)
        }
        if productModel.importFile(at: URL, mode: mode, attachingTo: attachmentTarget) == nil {
            fileImportError = "无法添加这个文件。"
        }
    }

    private func attachProjectFileToTask(_ file: YouziFile) {
        guard let task = ensureTaskDraft() else { return }
        productModel.referenceProjectFile(file.id, toTask: task.id)
        if productModel.lastPersistenceError != nil {
            fileImportError = "无法把这份项目资料添加到任务。"
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
            fileImportError = "无法打开这份项目资料。"
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

    private var runtimeStatus: String {
        if assistantAlias.isEmpty { return "需要完成本地设置" }
        return switch server.state {
        case .starting: "正在本地准备…"
        case .ready: "已在本机就绪"
        case .missing, .crashed: "需要处理"
        case .idle, .stopped: "随时可以开始"
        }
    }

    private var runtimeSymbol: String {
        switch server.state {
        case .ready: "checkmark.circle.fill"
        case .starting: "hourglass"
        case .missing, .crashed: "exclamationmark.circle"
        case .idle, .stopped: "lock.shield"
        }
    }

    private func submit() {
        let request = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, !chat.isStreaming else { return }
        guard !assistantAlias.isEmpty else {
            onPrepareAssistant()
            return
        }
        guard var task = ensureTaskDraft(request: request) else { return }
        task.title = task.title == "未命名任务" ? taskTitle(from: request) : task.title
        task.request = request
        task.updatedAt = Date()
        productModel.save(task)
        productModel.assignWorkspace(selectedWorkspaceID, toTask: task.id)
        productModel.moveTask(task.id, toProject: selectedProjectID)
        let attachments: [ChatFileAttachment]
        do {
            attachments = try chatAttachments(for: productModel.task(id: task.id) ?? task)
        } catch {
            fileImportError = "无法读取已添加的任务资料。"
            return
        }
        guard productModel.beginTaskExecution(
            taskID: task.id,
            conversationID: chat.activeConversationID
        ) != nil else {
            fileImportError = "无法准备任务的工作空间。"
            return
        }
        draft = ""
        focusRequest &+= 1
        chat.send(request, alias: assistantAlias, fileAttachments: attachments)
    }

}
