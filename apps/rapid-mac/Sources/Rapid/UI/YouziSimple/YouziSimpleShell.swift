import AppKit
import SwiftUI

/// The task-first Simple Mode presentation of the app-owned product graph.
/// Professional Mode and Simple Mode share the same runtime and persistence;
/// this shell only changes information architecture and language.
struct YouziSimpleShell: View {
    @Environment(YouziExperienceModeConfig.self) private var experienceMode
    @Environment(ChatViewModel.self) private var chat
    @Environment(YouziProductModel.self) private var productModel

    let assistantAlias: String
    let onPrepareAssistant: () -> Void
    let onOpenSettings: () -> Void

    @State private var selection: YouziSimpleDestination = .newTask
    @State private var selectedTaskID: UUID?
    @State private var selectedProjectID: UUID?
    @State private var selectedArtifactID: UUID?
    @State private var showingTemplates = false
    @State private var fileActionError: String?

    private static let bundledTemplates = try? YouziBundledTemplateCatalog.loadBundled()

    var body: some View {
        NavigationSplitView {
            sidebar
                .background(RapidTheme.surfaceSidebar)
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 280)
        } detail: {
            destination
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RapidTheme.surfaceCanvas)
        }
        .navigationSplitViewStyle(.balanced)
        .accessibilityIdentifier("YouziSimple.Shell")
        .sheet(isPresented: $showingTemplates) {
            templateSheet
                .frame(minWidth: 680, minHeight: 620)
        }
        .sheet(item: selectedArtifactBinding) { artifact in
            artifactPreview(artifact)
                .frame(minWidth: 560, minHeight: 420)
        }
        .alert("文件操作没有完成", isPresented: fileActionAlertBinding) {
            Button("好", role: .cancel) {}
        } message: {
            Text(fileActionError ?? "请重试。")
        }
        .onAppear(perform: seedBundledTemplates)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand

            VStack(spacing: RapidTheme.Space.xxs) {
                ForEach(YouziSimpleDestination.allCases) { destination in
                    navigationRow(destination)
                }
            }
            .padding(.horizontal, RapidTheme.Space.sm)

            Divider()
                .padding(.vertical, RapidTheme.Space.md)
                .padding(.horizontal, RapidTheme.Space.lg)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: RapidTheme.Space.md) {
                    recentTaskSection
                    workspaceTree
                    conversationFolderTree
                }
                .padding(.horizontal, RapidTheme.Space.sm)
                .padding(.bottom, RapidTheme.Space.md)
            }
            .scrollIndicators(.never)

            Divider()
                .padding(.horizontal, RapidTheme.Space.lg)
            accountMenu
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var brand: some View {
        HStack(spacing: RapidTheme.Space.sm) {
            YouziLogo(size: 28)
            Text("柚子")
                .font(RapidFont.windowTitle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, RapidTheme.Space.lg)
        .padding(.top, RapidTheme.Space.lg)
        .padding(.bottom, RapidTheme.Space.md)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("柚子，简约模式")
    }

    private var recentTaskSection: some View {
        VStack(alignment: .leading, spacing: RapidTheme.Space.xxs) {
            sidebarLabel("最近任务")
            if recentTasks.isEmpty {
                Text("最近任务会显示在这里。")
                    .font(RapidFont.caption)
                    .foregroundStyle(RapidTheme.textSecondary)
                    .padding(.horizontal, RapidTheme.Space.md)
                    .padding(.vertical, RapidTheme.Space.sm)
            } else {
                ForEach(recentTasks.prefix(6)) { task in
                    taskRow(task, prefix: "YouziSimple.RecentTask")
                }
            }
        }
    }

    @ViewBuilder
    private var workspaceTree: some View {
        if !activeWorkspaces.isEmpty || !unplacedProjects.isEmpty {
            VStack(alignment: .leading, spacing: RapidTheme.Space.xxs) {
                sidebarLabel("工作空间与项目")
                ForEach(activeWorkspaces) { workspace in
                    DisclosureGroup {
                        let directTasks = productModel.tasks.filter {
                            $0.workspaceID == workspace.id && $0.projectID == nil
                                && $0.status != .archived
                        }
                        ForEach(directTasks.prefix(5)) { task in
                            taskRow(task, prefix: "YouziSimple.WorkspaceTask")
                                .padding(.leading, RapidTheme.Space.sm)
                        }
                        ForEach(projects(in: workspace)) { project in
                            projectRow(project)
                                .padding(.leading, RapidTheme.Space.sm)
                        }
                    } label: {
                        Label(workspace.name, systemImage: "folder")
                            .font(RapidFont.secondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, RapidTheme.Space.md)
                    .padding(.vertical, RapidTheme.Space.xs)
                    .accessibilityIdentifier(
                        "YouziSimple.Sidebar.Workspace.\(workspace.id.uuidString)"
                    )
                }
                ForEach(unplacedProjects) { project in
                    projectRow(project)
                }
            }
        }
    }

    @ViewBuilder
    private var conversationFolderTree: some View {
        if !chat.folders.isEmpty {
            VStack(alignment: .leading, spacing: RapidTheme.Space.xxs) {
                sidebarLabel("对话文件夹")
                ForEach(chat.folders) { folder in
                    DisclosureGroup {
                        ForEach(conversations(in: folder)) { conversation in
                            Button { openConversation(conversation.id) } label: {
                                Label(conversation.title, systemImage: "text.bubble")
                                    .font(RapidFont.caption)
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .padding(.leading, RapidTheme.Space.sm)
                            .accessibilityIdentifier(
                                "YouziSimple.Conversation.\(conversation.id.uuidString)"
                            )
                        }
                    } label: {
                        Label(folder.name, systemImage: "folder")
                            .font(RapidFont.secondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, RapidTheme.Space.md)
                    .padding(.vertical, RapidTheme.Space.xs)
                    .accessibilityIdentifier(
                        "YouziSimple.ConversationFolder.\(folder.id.uuidString)"
                    )
                }
            }
        }
    }

    private func sidebarLabel(_ text: String) -> some View {
        Text(text)
            .font(RapidFont.groupLabel)
            .foregroundStyle(RapidTheme.textSecondary)
            .padding(.horizontal, RapidTheme.Space.md)
            .padding(.bottom, RapidTheme.Space.xs)
    }

    private func taskRow(_ task: YouziTask, prefix: String) -> some View {
        Button { openTask(task) } label: {
            HStack(spacing: RapidTheme.Space.sm) {
                Image(systemName: task.status.systemImage)
                    .foregroundStyle(RapidTheme.textSecondary)
                    .frame(width: 16)
                Text(task.title.isEmpty ? "未命名任务" : task.title)
                    .font(RapidFont.secondary)
                    .foregroundStyle(RapidTheme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, RapidTheme.Space.md)
            .frame(minHeight: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("\(prefix).\(task.id.uuidString)")
    }

    private func projectRow(_ project: YouziProject) -> some View {
        DisclosureGroup {
            ForEach(tasks(in: project).prefix(5)) { task in
                taskRow(task, prefix: "YouziSimple.ProjectTask")
                    .padding(.leading, RapidTheme.Space.sm)
            }
            Button("打开项目工作台") { openProject(project) }
                .buttonStyle(.plain)
                .font(RapidFont.caption)
                .foregroundStyle(RapidTheme.brandPrimary)
                .padding(.leading, RapidTheme.Space.lg)
        } label: {
            Label(project.name, systemImage: "square.stack.3d.up")
                .font(RapidFont.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, RapidTheme.Space.md)
        .padding(.vertical, RapidTheme.Space.xs)
        .accessibilityIdentifier("YouziSimple.Sidebar.Project.\(project.id.uuidString)")
    }

    private var accountMenu: some View {
        Menu {
            Button("设置…", action: onOpenSettings)
                .accessibilityIdentifier("YouziSimple.Account.Settings")
            Divider()
            Button {
                experienceMode.mode = .professional
            } label: {
                Label("专业模式", systemImage: "slider.horizontal.3")
            }
            .accessibilityIdentifier(YouziExperienceMode.professional.accessibilityIdentifier)
        } label: {
            HStack(spacing: RapidTheme.Space.sm) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 18))
                VStack(alignment: .leading, spacing: RapidTheme.Space.xxs) {
                    Text("柚子")
                        .font(RapidFont.bodyEmphasis)
                    Text("简约模式")
                        .font(RapidFont.caption)
                        .foregroundStyle(RapidTheme.textSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(RapidFont.caption)
                    .foregroundStyle(RapidTheme.textSecondary)
            }
            .padding(.horizontal, RapidTheme.Space.md)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .padding(RapidTheme.Space.sm)
        .accessibilityIdentifier("YouziSimple.AccountMenu")
    }

    private func navigationRow(_ destination: YouziSimpleDestination) -> some View {
        let isSelected = selection == destination
        return Button {
            if destination == .newTask {
                startNewTask()
            } else {
                selection = destination
            }
        } label: {
            HStack(spacing: RapidTheme.Space.sm) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(isSelected ? RapidTheme.selectionBar : .clear)
                    .frame(width: RapidTheme.Layout.selectionBarWidth, height: 20)
                    .accessibilityHidden(true)
                Image(systemName: destination.systemImage)
                    .frame(width: 20)
                Text(destination.title)
                    .font(isSelected ? RapidFont.bodyEmphasis : RapidFont.body)
                Spacer(minLength: 0)
            }
            .foregroundStyle(RapidTheme.textPrimary)
            .padding(.horizontal, RapidTheme.Space.sm)
            .frame(minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: RapidTheme.Radius.card, style: .continuous)
                    .fill(isSelected ? RapidTheme.selectionFill : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(destination.accessibilityIdentifier)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var destination: some View {
        switch selection {
        case .newTask:
            YouziSimpleTaskView(
                taskID: selectedTaskID,
                projectID: selectedProjectID,
                assistantAlias: assistantAlias,
                onPrepareAssistant: onPrepareAssistant,
                onOpenProfessional: { experienceMode.mode = .professional },
                onShowTemplates: { showingTemplates = true },
                onTaskPersisted: { selectedTaskID = $0 },
                onNavigate: { selection = $0 }
            )
        case .workspaces:
            YouziSimpleWorkspacesPage(
                workspaces: productModel.workspaces,
                projects: productModel.projects,
                tasks: productModel.tasks,
                files: productModel.files,
                onOpenTask: openTask,
                onOpenProject: openProject,
                onCreateManagedWorkspace: createManagedWorkspace,
                onChooseWorkspaceFolder: chooseWorkspaceFolder,
                onCreateProject: createProject
            )
        case .helpers:
            YouziSimpleHelpersPage(
                helpers: productModel.document.helpers,
                onStartTask: startTask(with:)
            )
        case .knowMe:
            YouziSimpleKnowMePage(nodes: productModel.document.memoryNodes)
        case .results:
            YouziSimpleResultsPage(
                artifacts: productModel.artifacts,
                fileForArtifact: productModel.file(for:),
                onPreview: previewArtifact,
                onRevealInFinder: revealArtifact,
                onExport: exportArtifact
            )
        }
    }

    @ViewBuilder
    private var templateSheet: some View {
        if let catalog = Self.bundledTemplates {
            YouziSimpleTemplateGallery(catalog: catalog, onCreateDraft: createDraft(from:))
        } else {
            ContentUnavailableView(
                "模板暂时不可用",
                systemImage: "doc.badge.ellipsis",
                description: Text("请关闭此窗口后重试。")
            )
        }
    }

    private func artifactPreview(_ artifact: YouziArtifact) -> some View {
        VStack(alignment: .leading, spacing: RapidTheme.Space.lg) {
            HStack {
                Text(artifact.title)
                    .font(RapidFont.pageTitle)
                Spacer(minLength: 0)
                Button("关闭") { selectedArtifactID = nil }
                    .buttonStyle(.bordered)
            }
            Divider()
            if let preview = artifact.previewText, !preview.isEmpty {
                ScrollView {
                    Text(preview)
                        .font(RapidFont.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView(
                    "没有文本预览",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("可在成果列表中导出，或在 Finder 中查看。")
                )
            }
        }
        .padding(RapidTheme.Space.xl)
        .accessibilityIdentifier("YouziSimple.ArtifactPreview")
    }

    private var recentTasks: [YouziTask] {
        productModel.tasks
            .filter { $0.status != .archived }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var activeWorkspaces: [YouziWorkspace] {
        productModel.workspaces.filter { $0.state == .active }
    }

    private var unplacedProjects: [YouziProject] {
        let placedIDs = Set(activeWorkspaces.flatMap { projects(in: $0).map(\.id) })
        return productModel.projects.filter { $0.state == .active && !placedIDs.contains($0.id) }
    }

    private func projects(in workspace: YouziWorkspace) -> [YouziProject] {
        let IDs = Set(
            productModel.tasks.lazy
                .filter { $0.workspaceID == workspace.id }
                .compactMap(\.projectID)
        )
        return productModel.projects.filter { $0.state == .active && IDs.contains($0.id) }
    }

    private func tasks(in project: YouziProject) -> [YouziTask] {
        productModel.tasks
            .filter { $0.projectID == project.id && $0.status != .archived }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private func conversations(in folder: ChatFolder) -> [ChatConversation] {
        chat.conversations.filter { $0.folderID == folder.id && !$0.isArchived }
    }

    private func startNewTask() {
        chat.newConversation()
        selectedTaskID = nil
        selectedProjectID = nil
        selection = .newTask
    }

    private func openTask(_ task: YouziTask) {
        selectedTaskID = task.id
        selectedProjectID = task.projectID
        if let conversationID = task.conversationID,
           chat.conversations.contains(where: { $0.id == conversationID }) {
            chat.selectConversation(conversationID)
        } else {
            chat.newConversation()
        }
        selection = .newTask
    }

    private func openConversation(_ id: UUID) {
        chat.selectConversation(id)
        let task = productModel.tasks.first { $0.conversationID == id }
        selectedTaskID = task?.id
        selectedProjectID = task?.projectID
        selection = .newTask
    }

    private func openProject(_ project: YouziProject) {
        selectedProjectID = project.id
        if let task = tasks(in: project).first {
            openTask(task)
        } else {
            chat.newConversation()
            selectedTaskID = nil
            selection = .newTask
        }
    }

    private func createProject(_ name: String) {
        _ = productModel.createProject(name: name)
    }

    private func createManagedWorkspace(_ name: String) {
        _ = productModel.createManagedWorkspace(name: name)
    }

    private func chooseWorkspaceFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择文件夹"
        guard panel.runModal() == .OK, let URL = panel.url else { return }
        _ = productModel.createBookmarkedWorkspace(
            name: URL.lastPathComponent,
            directoryURL: URL
        )
    }

    private func startTask(with helper: YouziHelper) {
        chat.newConversation()
        let task = productModel.createTaskDraft(
            title: "与\(helper.name)一起开始",
            request: "",
            helperID: helper.id
        )
        selectedTaskID = task?.id
        selectedProjectID = nil
        selection = .newTask
    }

    private func seedBundledTemplates() {
        guard let catalog = Self.bundledTemplates else { return }
        let templates = catalog.templates.map { entry in
            YouziTemplate(
                id: entry.id,
                name: entry.name,
                category: entry.category,
                summary: entry.summary,
                samplePreview: entry.samplePreview,
                prefilledRequest: entry.prefilledRequest,
                requiredInputs: entry.requiredInputs,
                source: YouziManifestSource(
                    kind: .builtIn,
                    identifier: "youzi-templates-v1",
                    version: catalog.catalogVersion
                ),
                createdAt: Date(timeIntervalSince1970: 0),
                updatedAt: Date(timeIntervalSince1970: 0)
            )
        }
        let isCurrent = templates.allSatisfy { bundled in
            productModel.template(id: bundled.id) == bundled
        }
        if !isCurrent { productModel.seedTemplates(templates) }
    }

    private func createDraft(from entry: YouziBundledTemplateCatalog.Entry) {
        chat.newConversation()
        if let task = productModel.instantiateTemplate(id: entry.id) {
            selectedTaskID = task.id
            selectedProjectID = task.projectID
            selection = .newTask
        }
        showingTemplates = false
    }

    private func previewArtifact(_ artifact: YouziArtifact) {
        if artifact.previewText?.isEmpty == false {
            selectedArtifactID = artifact.id
            return
        }
        do {
            try productModel.withFileURL(id: artifact.fileID) { URL in
                guard NSWorkspace.shared.open(URL) else {
                    throw CocoaError(.fileReadUnknown)
                }
            }
        } catch {
            fileActionError = "无法打开这份成果。"
        }
    }

    private func revealArtifact(_ artifact: YouziArtifact) {
        do {
            try productModel.withFileURL(id: artifact.fileID) { URL in
                NSWorkspace.shared.activateFileViewerSelecting([URL])
            }
        } catch {
            fileActionError = "无法在 Finder 中定位这份成果。"
        }
    }

    private func exportArtifact(_ artifact: YouziArtifact) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = productModel.file(for: artifact)?.displayName ?? artifact.title
        panel.prompt = "导出"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try productModel.exportFile(id: artifact.fileID, to: destination)
        } catch {
            fileActionError = "无法导出这份成果。"
        }
    }

    private var selectedArtifactBinding: Binding<YouziArtifact?> {
        Binding(
            get: {
                guard let selectedArtifactID else { return nil }
                return productModel.artifact(id: selectedArtifactID)
            },
            set: { selectedArtifactID = $0?.id }
        )
    }

    private var fileActionAlertBinding: Binding<Bool> {
        Binding(
            get: { fileActionError != nil },
            set: { if !$0 { fileActionError = nil } }
        )
    }
}

private extension YouziTaskStatus {
    var systemImage: String {
        switch self {
        case .draft: "square.and.pencil"
        case .inProgress: "circle.dotted"
        case .awaitingConfirmation: "person.crop.circle.badge.questionmark"
        case .completed: "checkmark.circle"
        case .failed: "exclamationmark.circle"
        case .archived: "archivebox"
        }
    }
}
