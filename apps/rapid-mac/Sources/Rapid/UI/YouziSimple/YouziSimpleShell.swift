import AppKit
import SwiftUI

/// The task-first Simple Mode presentation of the app-owned product graph.
/// Professional Mode and Simple Mode share the same runtime and persistence;
/// this shell only changes information architecture and language.
struct YouziSimpleShell: View {
    @Environment(YouziExperienceModeConfig.self) private var experienceMode
    @Environment(ChatViewModel.self) private var chat
    @Environment(YouziSharingCenter.self) private var sharing
    @Environment(YouziProductModel.self) private var productModel
    @Environment(YouziI18nConfig.self) private var i18n

    @Binding var assistantAlias: String
    var catalogEntries: [ModelEntry] = []
    let onPrepareAssistant: () -> Void

    @State private var selection: YouziSimpleDestination = .newTask
    @State private var selectedTaskID: UUID?
    @State private var selectedProjectID: UUID?
    @State private var selectedArtifactID: UUID?
    @State private var showingTemplates = false
    @State private var fileActionError: String?
    @State private var isRecentTasksExpanded = false
    @State private var hoveredTaskID: UUID?
    @State private var renamingTask: YouziTask?
    @State private var renameText = ""

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
        .onChange(of: sharing.errorMessage) { _, error in
            if let error { fileActionError = error }
        }
        .accessibilityIdentifier("YouziSimple.Shell")
        .sheet(isPresented: $showingTemplates) {
            templateSheet
                .frame(minWidth: 680, minHeight: 620)
        }
        .sheet(item: selectedArtifactBinding) { artifact in
            artifactPreview(artifact)
                .frame(minWidth: 560, minHeight: 420)
        }
        .alert(i18n.text(zh: "文件操作没有完成", en: "File operation could not be completed"), isPresented: fileActionAlertBinding) {
            Button(i18n.text(zh: "好", en: "OK"), role: .cancel) {}
        } message: {
            Text(fileActionError ?? i18n.text(zh: "请重试。", en: "Please try again."))
        }
        .alert(i18n.text(zh: "重命名任务", en: "Rename Task"), isPresented: renameAlertBinding) {
            TextField(i18n.text(zh: "任务名称", en: "Task Name"), text: $renameText)
            Button(i18n.text(zh: "确定", en: "OK")) {
                if let task = renamingTask {
                    let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        productModel.renameTask(task.id, to: trimmed, chat: chat)
                    }
                }
                renamingTask = nil
            }
            Button(i18n.text(zh: "取消", en: "Cancel"), role: .cancel) {
                renamingTask = nil
            }
        }
        .onAppear(perform: seedBundledTemplates)
    }

    private var sidebar: some View {
        GeometryReader { proxy in
            let totalH = proxy.size.height
            let headerH = max(38, totalH * 0.05)
            let footerH = max(44, totalH * 0.05)
            // Separate the three content areas with breathing room, not rules.
            let sectionGap = RapidTheme.Space.md
            let dividerTotalH: CGFloat = 2
            let remainingH = max(0, totalH - headerH - footerH - dividerTotalH - sectionGap * 2)
            let sectionH = remainingH / 3.0

            VStack(alignment: .leading, spacing: 0) {
                brand
                    .frame(height: headerH)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Divider()

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: RapidTheme.Space.xxs) {
                        ForEach(YouziSimpleDestination.allCases) { destination in
                            navigationRow(destination)
                        }
                    }
                    .padding(.horizontal, RapidTheme.Space.sm)
                    .padding(.vertical, RapidTheme.Space.xs)
                }
                .frame(height: sectionH)

                Spacer(minLength: 0)
                    .frame(height: sectionGap)

                ScrollView(.vertical, showsIndicators: false) {
                    recentTaskSection
                        .padding(.horizontal, RapidTheme.Space.sm)
                        .padding(.vertical, RapidTheme.Space.xs)
                }
                .frame(height: sectionH)

                Spacer(minLength: 0)
                    .frame(height: sectionGap)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: RapidTheme.Space.sm) {
                        workspaceTree
                        conversationFolderTree
                    }
                    .padding(.horizontal, RapidTheme.Space.sm)
                    .padding(.vertical, RapidTheme.Space.xs)
                }
                .frame(height: sectionH)

                Divider()

                accountMenu
                    .frame(height: footerH)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var brand: some View {
        HStack(spacing: RapidTheme.Space.sm) {
            YouziLogo(size: 26)
            Text("柚子")
                .font(RapidFont.windowTitle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, RapidTheme.Space.md)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(i18n.text(zh: "柚子，简约模式", en: "Youzi, Simple Mode"))
    }

    private var recentTaskSection: some View {
        VStack(alignment: .leading, spacing: RapidTheme.Space.xxs) {
            HStack {
                sidebarLabel(i18n.text(zh: "任务", en: "Tasks"))
                Spacer()
                if !recentTasks.isEmpty {
                    Text("\(recentTasks.count)")
                        .font(RapidFont.caption)
                        .foregroundStyle(RapidTheme.textTertiary)
                        .padding(.trailing, RapidTheme.Space.sm)
                }
            }
            if recentTasks.isEmpty {
                Text(i18n.text(zh: "任务会显示在这里。", en: "Tasks will appear here."))
                    .font(RapidFont.caption)
                    .foregroundStyle(RapidTheme.textSecondary)
                    .padding(.horizontal, RapidTheme.Space.md)
                    .padding(.vertical, RapidTheme.Space.sm)
            } else {
                let displayedTasks = isRecentTasksExpanded ? recentTasks : Array(recentTasks.prefix(5))
                ForEach(displayedTasks) { task in
                    taskRow(task, prefix: "YouziSimple.RecentTask")
                }
                if recentTasks.count > 5 {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isRecentTasksExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: RapidTheme.Space.xs) {
                            Text(isRecentTasksExpanded ? i18n.text(zh: "收起", en: "Collapse") : i18n.text(zh: "展开更多 (\(recentTasks.count - 5))", en: "Show more (\(recentTasks.count - 5))"))
                                .font(RapidFont.caption)
                            Image(systemName: isRecentTasksExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9))
                        }
                        .foregroundStyle(RapidTheme.textSecondary)
                        .padding(.horizontal, RapidTheme.Space.md)
                        .padding(.vertical, RapidTheme.Space.xxs)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("YouziSimple.RecentTasks.ExpandToggle")
                }
            }
        }
    }

    @ViewBuilder
    private var workspaceTree: some View {
        if !activeWorkspaces.isEmpty || !unplacedProjects.isEmpty {
            VStack(alignment: .leading, spacing: RapidTheme.Space.xxs) {
                sidebarLabel(i18n.text(zh: "工作空间与项目", en: "Workspaces & Projects"))
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
                            .font(RapidFont.body)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, RapidTheme.Space.sm)
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
                sidebarLabel(i18n.text(zh: "对话文件夹", en: "Chat Folders"))
                ForEach(chat.folders) { folder in
                    DisclosureGroup {
                        ForEach(conversations(in: folder)) { conversation in
                            Button { openConversation(conversation.id) } label: {
                                Label(conversation.title, systemImage: "text.bubble")
                                    .font(RapidFont.body)
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
                            .font(RapidFont.body)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, RapidTheme.Space.sm)
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
            .padding(.horizontal, RapidTheme.Space.sm)
            .padding(.bottom, RapidTheme.Space.xxs)
    }

    private func taskRow(_ task: YouziTask, prefix: String) -> some View {
        let isSelected = selectedTaskID == task.id
        let isHovered = hoveredTaskID == task.id
        return HStack(spacing: RapidTheme.Space.xs) {
            Button {
                openTask(task)
            } label: {
                HStack(spacing: RapidTheme.Space.xs) {
                    if task.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(RapidTheme.brandPrimary)
                            .frame(width: 16)
                    } else {
                        Image(systemName: task.status.systemImage)
                            .font(.system(size: 12))
                            .foregroundStyle(RapidTheme.textSecondary)
                            .frame(width: 16)
                    }
                    Text(task.title.isEmpty ? i18n.text(zh: "未命名任务", en: "Untitled Task") : task.title)
                        .font(RapidFont.body)
                        .foregroundStyle(RapidTheme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("\(prefix).\(task.id.uuidString)")

            if isHovered {
                HStack(spacing: 2) {
                    Button {
                        productModel.setTaskPinned(task.id, !task.isPinned, chat: chat)
                    } label: {
                        Image(systemName: task.isPinned ? "pin.slash" : "pin")
                            .font(.system(size: 11))
                            .foregroundStyle(RapidTheme.textSecondary)
                            .padding(2)
                    }
                    .buttonStyle(.plain)
                    .help(task.isPinned ? i18n.text(zh: "取消置顶", en: "Unpin") : i18n.text(zh: "置顶任务", en: "Pin"))

                    Menu {
                        Button {
                            renamingTask = task
                            renameText = task.title
                        } label: {
                            Label(i18n.text(zh: "重命名", en: "Rename"), systemImage: "pencil")
                        }

                        Button {
                            productModel.setTaskPinned(task.id, !task.isPinned, chat: chat)
                        } label: {
                            Label(
                                task.isPinned ? i18n.text(zh: "取消置顶", en: "Unpin") : i18n.text(zh: "置顶任务", en: "Pin"),
                                systemImage: task.isPinned ? "pin.slash" : "pin"
                            )
                        }

                        Button(i18n.text(zh: "分享对话文本…", en: "Share Conversation Text…")) {
                            sharing.shareTask(task, chat: chat)
                        }
                        .disabled(sharing.isSharing)

                        if !activeWorkspaces.isEmpty {
                            Menu(i18n.text(zh: "移动到工作空间", en: "Move to Workspace")) {
                                ForEach(activeWorkspaces) { ws in
                                    Button(ws.name) {
                                        productModel.assignWorkspace(ws.id, toTask: task.id)
                                    }
                                }
                            }
                        }

                        Divider()

                        Button(role: .destructive) {
                            productModel.setTaskArchived(task.id, true, chat: chat)
                        } label: {
                            Label(i18n.text(zh: "归档任务", en: "Archive Task"), systemImage: "archivebox")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 11))
                            .foregroundStyle(RapidTheme.textSecondary)
                            .padding(2)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 18, height: 18)
                }
            } else {
                Text(relativeTimeString(from: task.updatedAt))
                    .font(RapidFont.caption)
                    .foregroundStyle(RapidTheme.textTertiary)
            }
        }
        .padding(.horizontal, RapidTheme.Space.sm)
        .frame(minHeight: 32)
        .background(
            RoundedRectangle(cornerRadius: RapidTheme.Radius.card, style: .continuous)
                .fill(isSelected ? RapidTheme.selectionFill : (isHovered ? RapidTheme.hoverFill : Color.clear))
        )
        .onHover { hovering in
            if hovering {
                hoveredTaskID = task.id
            } else if hoveredTaskID == task.id {
                hoveredTaskID = nil
            }
        }
        .contextMenu {
            Button {
                renamingTask = task
                renameText = task.title
            } label: {
                Label(i18n.text(zh: "重命名", en: "Rename"), systemImage: "pencil")
            }

            Button {
                productModel.setTaskPinned(task.id, !task.isPinned, chat: chat)
            } label: {
                Label(
                    task.isPinned ? i18n.text(zh: "取消置顶", en: "Unpin") : i18n.text(zh: "置顶任务", en: "Pin"),
                    systemImage: task.isPinned ? "pin.slash" : "pin"
                )
            }

            Button(i18n.text(zh: "分享对话文本…", en: "Share Conversation Text…")) {
                sharing.shareTask(task, chat: chat)
            }
            .disabled(sharing.isSharing)

            if !activeWorkspaces.isEmpty {
                Menu(i18n.text(zh: "移动到工作空间", en: "Move to Workspace")) {
                    ForEach(activeWorkspaces) { ws in
                        Button(ws.name) {
                            productModel.assignWorkspace(ws.id, toTask: task.id)
                        }
                    }
                }
            }

            Divider()

            Button(role: .destructive) {
                productModel.setTaskArchived(task.id, true, chat: chat)
            } label: {
                Label(i18n.text(zh: "归档任务", en: "Archive Task"), systemImage: "archivebox")
            }
        }
    }

    private func projectRow(_ project: YouziProject) -> some View {
        DisclosureGroup {
            ForEach(tasks(in: project).prefix(5)) { task in
                taskRow(task, prefix: "YouziSimple.ProjectTask")
                    .padding(.leading, RapidTheme.Space.sm)
            }
            Button(i18n.text(zh: "打开项目工作台", en: "Open project workbench")) { openProject(project) }
                .buttonStyle(.plain)
                .font(RapidFont.caption)
                .foregroundStyle(RapidTheme.brandPrimary)
                .padding(.leading, RapidTheme.Space.lg)
        } label: {
            Label(project.name, systemImage: "square.stack.3d.up")
                .font(RapidFont.body)
                .lineLimit(1)
        }
        .padding(.horizontal, RapidTheme.Space.sm)
        .padding(.vertical, RapidTheme.Space.xs)
        .accessibilityIdentifier("YouziSimple.Sidebar.Project.\(project.id.uuidString)")
    }

    private var accountMenu: some View {
        YouziAccountMenu(catalogEntries: catalogEntries)
            .padding(.horizontal, RapidTheme.Space.xs)
    }
    // Shared presentation affordance: YouziAccountMenu()

    private func relativeTimeString(from date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 {
            return i18n.text(zh: "刚刚", en: "Just now")
        } else if interval < 3600 {
            let mins = max(1, Int(interval / 60))
            return i18n.text(zh: "\(mins)分钟前", en: "\(mins)m ago")
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return i18n.text(zh: "\(hours)小时前", en: "\(hours)h ago")
        } else if interval < 86400 * 30 {
            let days = Int(interval / 86400)
            return i18n.text(zh: "\(days)天前", en: "\(days)d ago")
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "M/d"
            return formatter.string(from: date)
        }
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
                Text(destination.localizedTitle(isChinese: i18n.isChinese))
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
                assistantAlias: $assistantAlias,
                catalogEntries: catalogEntries,
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
                skills: productModel.document.skills,
                connectors: productModel.document.connectors,
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
                onExport: exportArtifact,
                onShare: { artifact in
                    if let file = productModel.file(for: artifact) {
                        sharing.shareFile(file, product: productModel)
                    }
                }
            )
        }
    }

    @ViewBuilder
    private var templateSheet: some View {
        if let catalog = Self.bundledTemplates {
            YouziSimpleTemplateGallery(catalog: catalog, onCreateDraft: createDraft(from:))
        } else {
            ContentUnavailableView(
                i18n.text(zh: "模板暂时不可用", en: "Templates temporarily unavailable"),
                systemImage: "doc.badge.ellipsis",
                description: Text(i18n.text(zh: "请关闭此窗口后重试。", en: "Please close this window and try again."))
            )
        }
    }

    private func artifactPreview(_ artifact: YouziArtifact) -> some View {
        VStack(alignment: .leading, spacing: RapidTheme.Space.lg) {
            HStack {
                Text(artifact.title)
                    .font(RapidFont.pageTitle)
                Spacer(minLength: 0)
                Button(i18n.text(zh: "关闭", en: "Close")) { selectedArtifactID = nil }
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
                    i18n.text(zh: "没有文本预览", en: "No text preview"),
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(i18n.text(zh: "可在成果列表中导出，或在 Finder 中查看。", en: "You can export it from the deliverables list or view it in Finder."))
                )
            }
        }
        .padding(RapidTheme.Space.xl)
        .accessibilityIdentifier("YouziSimple.ArtifactPreview")
    }

    private var recentTasks: [YouziTask] {
        productModel.tasks
            .filter { $0.status != .archived }
            .sorted {
                if $0.isPinned != $1.isPinned {
                    return $0.isPinned && !$1.isPinned
                }
                return $0.updatedAt > $1.updatedAt
            }
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
        panel.prompt = i18n.text(zh: "选择文件夹", en: "Select Folder")
        guard panel.runModal() == .OK, let URL = panel.url else { return }
        _ = productModel.createBookmarkedWorkspace(
            name: URL.lastPathComponent,
            directoryURL: URL
        )
    }

    private func startTask(with helper: YouziHelper) {
        chat.newConversation()
        let task = productModel.createTaskDraft(
            title: i18n.text(zh: "与\(helper.name)一起开始", en: "Start with \(helper.name)"),
            request: "",
            helperID: helper.id
        )
        selectedTaskID = task?.id
        selectedProjectID = nil
        selection = .newTask
    }

    private func seedBundledTemplates() {
        productModel.seedMissingCapabilities(
            helpers: YouziBundledCapabilities.helpers,
            skills: YouziBundledCapabilities.skills
        )
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
            fileActionError = i18n.text(zh: "无法打开这份成果。", en: "Could not open this deliverable.")
        }
    }

    private func revealArtifact(_ artifact: YouziArtifact) {
        do {
            try productModel.withFileURL(id: artifact.fileID) { URL in
                NSWorkspace.shared.activateFileViewerSelecting([URL])
            }
        } catch {
            fileActionError = i18n.text(zh: "无法在 Finder 中定位这份成果。", en: "Could not reveal this deliverable in Finder.")
        }
    }

    private func exportArtifact(_ artifact: YouziArtifact) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = productModel.file(for: artifact)?.displayName ?? artifact.title
        panel.prompt = i18n.text(zh: "导出", en: "Export")
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try productModel.exportFile(id: artifact.fileID, to: destination)
        } catch {
            fileActionError = i18n.text(zh: "无法导出这份成果。", en: "Could not export this deliverable.")
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

    private var renameAlertBinding: Binding<Bool> {
        Binding(
            get: { renamingTask != nil },
            set: { if !$0 { renamingTask = nil } }
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
