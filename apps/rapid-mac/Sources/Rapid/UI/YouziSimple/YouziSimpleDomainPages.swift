import SwiftUI

struct YouziSimpleWorkspacesPage: View {
    @Environment(YouziI18nConfig.self) private var i18n
    let workspaces: [YouziWorkspace]
    let projects: [YouziProject]
    let tasks: [YouziTask]
    let files: [YouziFile]
    let onOpenTask: (YouziTask) -> Void
    let onOpenProject: (YouziProject) -> Void
    let onCreateManagedWorkspace: (String) -> Void
    let onChooseWorkspaceFolder: () -> Void
    let onCreateProject: (String) -> Void

    @State private var workspaceName = ""
    @State private var projectName = ""

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: RapidTheme.Space.xl) {
                YouziSimpleDomainPageHeader(
                    title: i18n.text(zh: "工作空间", en: "Workspaces"),
                    subtitle: i18n.text(zh: "管理柚子可以使用的文件夹，并在这里继续长期项目。", en: "Manage folders Youzi can use and continue long-term projects here.")
                )

                workspaceSection
                projectSection
            }
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(RapidTheme.Space.xl)
        }
        .accessibilityIdentifier("YouziSimple.Surface.workspaces")
    }

    private var activeWorkspaces: [YouziWorkspace] {
        workspaces.filter { $0.state == .active }
    }

    private var activeProjects: [YouziProject] {
        projects.filter { $0.state == .active }
    }

    private var workspaceSection: some View {
        VStack(alignment: .leading, spacing: RapidTheme.Space.md) {
            HStack(spacing: RapidTheme.Space.md) {
                Label(i18n.text(zh: "文件夹", en: "Folders"), systemImage: "folder")
                    .font(RapidFont.sectionTitle)
                Spacer(minLength: 0)
                TextField(i18n.text(zh: "工作空间名称", en: "Workspace name"), text: $workspaceName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 190)
                    .accessibilityIdentifier("YouziSimple.Workspaces.WorkspaceName")
                Button(i18n.text(zh: "新建空间", en: "New Workspace")) {
                    let name = workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    onCreateManagedWorkspace(name)
                    workspaceName = ""
                }
                .buttonStyle(.bordered)
                .disabled(workspaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("YouziSimple.Workspaces.CreateManaged")
                Button(i18n.text(zh: "选择文件夹…", en: "Select Folder…"), action: onChooseWorkspaceFolder)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("YouziSimple.Workspaces.ChooseFolder")
            }

            if activeWorkspaces.isEmpty {
                honestEmptyState(
                    icon: "folder.badge.plus",
                    title: i18n.text(zh: "还没有工作文件夹", en: "No Workspaces Yet"),
                    message: i18n.text(zh: "为任务选择文件夹后，柚子会在这里显示它和其中的资料。", en: "Once you select a folder for a task, Youzi will display it and its files here.")
                )
            } else {
                ForEach(activeWorkspaces) { workspace in
                    workspaceCard(workspace)
                }
            }
        }
    }

    private var projectSection: some View {
        VStack(alignment: .leading, spacing: RapidTheme.Space.md) {
            HStack(spacing: RapidTheme.Space.md) {
                Label(i18n.text(zh: "项目", en: "Projects"), systemImage: "square.stack.3d.up")
                    .font(RapidFont.sectionTitle)
                Spacer(minLength: 0)
                TextField(i18n.text(zh: "项目名称", en: "Project name"), text: $projectName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                    .accessibilityIdentifier("YouziSimple.Workspaces.ProjectName")
                Button(i18n.text(zh: "新建项目", en: "New Project")) {
                    let name = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    onCreateProject(name)
                    projectName = ""
                }
                .buttonStyle(.bordered)
                .disabled(projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("YouziSimple.Workspaces.CreateProject")
            }

            if activeProjects.isEmpty {
                honestEmptyState(
                    icon: "square.stack.3d.up",
                    title: i18n.text(zh: "还没有项目", en: "No Projects Yet"),
                    message: i18n.text(zh: "项目会把相关任务、长期说明和资料放在一起。", en: "Projects organize related tasks, long-term instructions, and files together.")
                )
            } else {
                ForEach(activeProjects.sorted { $0.updatedAt > $1.updatedAt }) { project in
                    projectCard(project)
                }
            }
        }
    }

    private func workspaceCard(_ workspace: YouziWorkspace) -> some View {
        let relatedTasks = tasks.filter { $0.workspaceID == workspace.id && $0.status != .archived }
        let relatedFiles = files.filter { file in
            if case let .workspace(workspaceID, _) = file.location {
                return workspaceID == workspace.id
            }
            return false
        }

        return DisclosureGroup {
            VStack(alignment: .leading, spacing: RapidTheme.Space.sm) {
                if relatedFiles.isEmpty && relatedTasks.isEmpty {
                    Text(i18n.text(zh: "这个工作空间暂时没有任务或资料。", en: "No tasks or files in this workspace yet."))
                        .font(RapidFont.caption)
                        .foregroundStyle(RapidTheme.textSecondary)
                }
                ForEach(relatedFiles.prefix(5)) { file in
                    Label(file.displayName, systemImage: "doc")
                        .font(RapidFont.secondary)
                        .foregroundStyle(RapidTheme.textSecondary)
                }
                ForEach(relatedTasks.prefix(5)) { task in
                    Button { onOpenTask(task) } label: {
                        Label(task.title, systemImage: "text.bubble")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("YouziSimple.Workspace.Task.\(task.id.uuidString)")
                }
            }
            .padding(.top, RapidTheme.Space.sm)
        } label: {
            HStack(spacing: RapidTheme.Space.md) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(RapidTheme.brandPrimary)
                VStack(alignment: .leading, spacing: RapidTheme.Space.xs) {
                    Text(workspace.name)
                        .font(RapidFont.bodyEmphasis)
                    Text("\(workspace.location.displayName(isChinese: i18n.isChinese)) · \(i18n.text(zh: "\(relatedTasks.count) 个任务", en: "\(relatedTasks.count) tasks")) · \(i18n.text(zh: "\(relatedFiles.count) 个文件", en: "\(relatedFiles.count) files"))")
                        .font(RapidFont.caption)
                        .foregroundStyle(RapidTheme.textSecondary)
                }
            }
        }
        .padding(RapidTheme.Space.lg)
        .youziSimpleCard()
        .accessibilityIdentifier("YouziSimple.Workspace.\(workspace.id.uuidString)")
    }

    private func projectCard(_ project: YouziProject) -> some View {
        let relatedTasks = tasks.filter { $0.projectID == project.id && $0.status != .archived }
        let resourceCount = files.lazy.filter { project.resourceFileIDs.contains($0.id) }.count

        return Button { onOpenProject(project) } label: {
            HStack(alignment: .top, spacing: RapidTheme.Space.md) {
                Image(systemName: "square.stack.3d.up.fill")
                    .foregroundStyle(RapidTheme.brandPrimary)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: RapidTheme.Space.xs) {
                    Text(project.name)
                        .font(RapidFont.bodyEmphasis)
                        .foregroundStyle(RapidTheme.textPrimary)
                    Text(project.summary.isEmpty ? i18n.text(zh: "还没有项目说明", en: "No project summary yet") : project.summary)
                        .font(RapidFont.secondary)
                        .foregroundStyle(RapidTheme.textSecondary)
                        .lineLimit(2)
                    Text("\(i18n.text(zh: "\(relatedTasks.count) 个任务", en: "\(relatedTasks.count) tasks")) · \(i18n.text(zh: "\(resourceCount) 份资料", en: "\(resourceCount) files"))")
                        .font(RapidFont.caption)
                        .foregroundStyle(RapidTheme.textSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .foregroundStyle(RapidTheme.textSecondary)
            }
            .padding(RapidTheme.Space.lg)
            .contentShape(Rectangle())
            .youziSimpleCard()
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("YouziSimple.Project.\(project.id.uuidString)")
    }

    private func honestEmptyState(icon: String, title: String, message: String) -> some View {
        HStack(alignment: .top, spacing: RapidTheme.Space.md) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(RapidTheme.brandPrimary)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: RapidTheme.Space.xs) {
                Text(title)
                    .font(RapidFont.bodyEmphasis)
                Text(message)
                    .font(RapidFont.secondary)
                    .foregroundStyle(RapidTheme.textSecondary)
            }
        }
        .padding(RapidTheme.Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .youziSimpleCard()
    }
}

struct YouziSimpleHelpersPage: View {
    @Environment(YouziI18nConfig.self) private var i18n
    @Environment(YouziProductModel.self) private var productModel
    let helpers: [YouziHelper]
    var skills: [YouziSkill] = []
    var connectors: [YouziConnector] = []
    let onStartTask: (YouziHelper) -> Void

    @Environment(\.openURL) private var openURL
    @State private var selectedTab: CapabilityTab = .experts
    @State private var showingAddExpertSheet = false
    @State private var showingAddConnectorSheet = false

    // New expert form state
    @State private var newExpertName = ""
    @State private var newExpertSummary = ""
    @State private var newExpertInstructions = ""

    // New connector form state
    @State private var newConnectorName = ""
    @State private var newConnectorServerName = ""
    @State private var newConnectorSummary = ""

    enum CapabilityTab: String, CaseIterable, Identifiable {
        case experts = "experts"
        case skills = "skills"
        case connectors = "connectors"

        var id: String { rawValue }

        func localizedTitle(isChinese: Bool) -> String {
            switch self {
            case .experts: isChinese ? "专家" : "Experts"
            case .skills: isChinese ? "技能" : "Skills"
            case .connectors: isChinese ? "连接" : "Connectors"
            }
        }

        var iconName: String {
            switch self {
            case .experts: "person.2.fill"
            case .skills: "bolt.fill"
            case .connectors: "point.3.connected.trianglepath.dotted"
            }
        }
    }

    private func tabCount(_ tab: CapabilityTab) -> Int {
        switch tab {
        case .experts: activeHelpers.count
        case .skills: skills.filter { $0.state == .active }.count
        case .connectors: connectors.filter { $0.state == .active }.count
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: RapidTheme.Space.xl) {
                YouziSimpleDomainPageHeader(
                    title: i18n.text(zh: "专家·技能·连接", en: "Experts · Skills · Connectors"),
                    subtitle: i18n.text(zh: "选择一种工作方式、辅助能力或外部工具，让柚子更好地为你服务。", en: "Choose a workflow, specialized capability, or external tool to empower Youzi.")
                )

                tabBar

                switch selectedTab {
                case .experts:
                    expertsSection
                case .skills:
                    skillsSection
                case .connectors:
                    connectorsSection
                }
            }
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(RapidTheme.Space.xl)
        }
        .accessibilityIdentifier("YouziSimple.Surface.helpers")
        .sheet(isPresented: $showingAddExpertSheet) {
            addExpertSheet
                .frame(minWidth: 460, minHeight: 400)
        }
        .sheet(isPresented: $showingAddConnectorSheet) {
            addConnectorSheet
                .frame(minWidth: 460, minHeight: 380)
        }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(CapabilityTab.allCases) { tab in
                let isSelected = selectedTab == tab
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                        selectedTab = tab
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.iconName)
                            .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        Text(tab.localizedTitle(isChinese: i18n.isChinese))
                            .font(RapidFont.bodyEmphasis)
                        Text("(\(tabCount(tab)))")
                            .font(RapidFont.caption)
                            .foregroundStyle(isSelected ? RapidTheme.brandPrimary : RapidTheme.textSecondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isSelected ? RapidTheme.brandPrimaryTint : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(isSelected ? RapidTheme.brandPrimary.opacity(0.35) : Color.clear, lineWidth: 1)
                    )
                    .foregroundStyle(isSelected ? RapidTheme.brandPrimary : RapidTheme.textPrimary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(RapidTheme.surfaceSidebar)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(RapidTheme.hairline, lineWidth: 1)
        )
    }

    private var activeHelpers: [YouziHelper] {
        helpers
            .filter { $0.state == .active }
            .sorted { ($0.isFavorite ? 0 : 1, $0.name) < ($1.isFavorite ? 0 : 1, $1.name) }
    }

    @ViewBuilder
    private var expertsSection: some View {
        HStack(alignment: .top, spacing: RapidTheme.Space.md) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(RapidTheme.brandPrimary)
            VStack(alignment: .leading, spacing: 3) {
                Text(i18n.text(zh: "专家来源与配置", en: "Expert Sources & Setup"))
                    .font(RapidFont.bodyEmphasis)
                Text(i18n.text(
                    zh: "专家基于预置智能体角色、工作流方法论与专属指令构建。支持系统内置与用户自定义专家。点击右侧按钮可新建自定义专家。",
                    en: "Experts combine persona instructions, methodology, and tools. Built-in and custom experts are supported."
                ))
                .font(RapidFont.caption)
                .foregroundStyle(RapidTheme.textSecondary)
            }
            Spacer(minLength: 0)
            Button {
                newExpertName = ""
                newExpertSummary = ""
                newExpertInstructions = ""
                showingAddExpertSheet = true
            } label: {
                Text(i18n.text(zh: "+ 添加专家", en: "+ Add Expert"))
            }
            .buttonStyle(.borderedProminent)
            .tint(RapidTheme.brandPrimary)
        }
        .padding(RapidTheme.Space.md)
        .background(
            RoundedRectangle(cornerRadius: RapidTheme.Radius.card, style: .continuous)
                .fill(RapidTheme.surfaceRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RapidTheme.Radius.card, style: .continuous)
                .strokeBorder(RapidTheme.hairline, lineWidth: 1)
        )

        if activeHelpers.isEmpty {
            Text(i18n.text(zh: "当可用专家安装后，会显示在这里。你仍然可以在“新任务”中直接向柚子提出需求。", en: "Available experts will appear here once installed. You can always ask Youzi directly in New Task."))
                .font(RapidFont.body)
                .foregroundStyle(RapidTheme.textSecondary)
                .padding(RapidTheme.Space.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .youziSimpleCard()
        } else {
            ForEach(activeHelpers) { helper in
                HStack(alignment: .top, spacing: RapidTheme.Space.lg) {
                    YouziLogo(size: 40)
                    VStack(alignment: .leading, spacing: RapidTheme.Space.xs) {
                        Text(helper.name)
                            .font(RapidFont.sectionTitle)
                        Text(helper.summary)
                            .font(RapidFont.secondary)
                            .foregroundStyle(RapidTheme.textSecondary)
                        Text(i18n.text(zh: "来源版本 \(helper.source.version)", en: "Source version \(helper.source.version)"))
                            .font(RapidFont.caption)
                            .foregroundStyle(RapidTheme.textSecondary)
                    }
                    Spacer(minLength: 0)
                    Button {
                        onStartTask(helper)
                    } label: {
                        Text(i18n.text(zh: "用这个专家新建任务", en: "Start Task with Expert"))
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(RapidTheme.Space.lg)
                .youziSimpleCard()
                .accessibilityIdentifier("YouziSimple.Helper.\(helper.id.uuidString)")
            }
        }

        VStack(alignment: .leading, spacing: RapidTheme.Space.md) {
            Text(i18n.text(zh: "开源 Agent 推荐", en: "Recommended Open-Source Agents"))
                .font(RapidFont.sectionTitle)
                .foregroundStyle(RapidTheme.textPrimary)

            ForEach(YouziOpenSourceCatalog.agents) { agent in
                openSourceRow(item: agent, iconName: "person.crop.circle.badge.checkmark")
            }
        }
        .padding(.top, RapidTheme.Space.md)
    }

    @ViewBuilder
    private var skillsSection: some View {
        HStack(alignment: .top, spacing: RapidTheme.Space.md) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(RapidTheme.brandPrimary)
            VStack(alignment: .leading, spacing: 3) {
                Text(i18n.text(zh: "技能来源与使用频次", en: "Skill Sources & Frequency"))
                    .font(RapidFont.bodyEmphasis)
                Text(i18n.text(
                    zh: "技能来自系统内置扩展与能力插件。在聊天窗口上方提供常用技能快速呼出入口，系统会自动统计各技能的使用频次并优先呈现常用技能。",
                    en: "Skills come from built-in system modules and extensions. Frequently used skills appear above the chat compose box."
                ))
                .font(RapidFont.caption)
                .foregroundStyle(RapidTheme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(RapidTheme.Space.md)
        .background(
            RoundedRectangle(cornerRadius: RapidTheme.Radius.card, style: .continuous)
                .fill(RapidTheme.surfaceRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RapidTheme.Radius.card, style: .continuous)
                .strokeBorder(RapidTheme.hairline, lineWidth: 1)
        )

        let activeSkills = skills.filter { $0.state == .active }
        if !activeSkills.isEmpty {
            VStack(alignment: .leading, spacing: RapidTheme.Space.md) {
                Text(i18n.text(zh: "已安装技能", en: "Installed Skills"))
                    .font(RapidFont.sectionTitle)
                    .foregroundStyle(RapidTheme.textPrimary)

                ForEach(activeSkills) { skill in
                    HStack(alignment: .top, spacing: RapidTheme.Space.md) {
                        Image(systemName: "bolt.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(RapidTheme.brandPrimary)
                        VStack(alignment: .leading, spacing: RapidTheme.Space.xxs) {
                            Text(skill.name)
                                .font(RapidFont.bodyEmphasis)
                            Text(skill.summary)
                                .font(RapidFont.secondary)
                                .foregroundStyle(RapidTheme.textSecondary)
                            Text(i18n.text(zh: "版本 \(skill.packageVersion)", en: "Version \(skill.packageVersion)"))
                                .font(RapidFont.caption)
                                .foregroundStyle(RapidTheme.textSecondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(RapidTheme.Space.lg)
                    .youziSimpleCard()
                }
            }
        }

        VStack(alignment: .leading, spacing: RapidTheme.Space.md) {
            Text(i18n.text(zh: "开源技能推荐", en: "Recommended Open-Source Skills"))
                .font(RapidFont.sectionTitle)
                .foregroundStyle(RapidTheme.textPrimary)

            ForEach(YouziOpenSourceCatalog.skills) { item in
                openSourceRow(item: item, iconName: "sparkles")
            }
        }
        .padding(.top, RapidTheme.Space.md)
    }

    @ViewBuilder
    private var connectorsSection: some View {
        HStack(alignment: .top, spacing: RapidTheme.Space.md) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(RapidTheme.brandPrimary)
            VStack(alignment: .leading, spacing: 3) {
                Text(i18n.text(zh: "连接器来源与 MCP 配置", en: "Connector Sources & MCP Setup"))
                    .font(RapidFont.bodyEmphasis)
                Text(i18n.text(
                    zh: "连接器基于开源标准 Model Context Protocol (MCP)。可连接本地文件、数据库、GitHub 等外部工具服务，支持自由添加与扩展。",
                    en: "Connectors adhere to the open-source Model Context Protocol (MCP). Connect local tools and APIs to enhance AI context."
                ))
                .font(RapidFont.caption)
                .foregroundStyle(RapidTheme.textSecondary)
            }
            Spacer(minLength: 0)
            Button {
                newConnectorName = ""
                newConnectorServerName = ""
                newConnectorSummary = ""
                showingAddConnectorSheet = true
            } label: {
                Text(i18n.text(zh: "+ 添加连接器", en: "+ Add Connector"))
            }
            .buttonStyle(.borderedProminent)
            .tint(RapidTheme.brandPrimary)
        }
        .padding(RapidTheme.Space.md)
        .background(
            RoundedRectangle(cornerRadius: RapidTheme.Radius.card, style: .continuous)
                .fill(RapidTheme.surfaceRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RapidTheme.Radius.card, style: .continuous)
                .strokeBorder(RapidTheme.hairline, lineWidth: 1)
        )

        let activeConnectors = connectors.filter { $0.state == .active }
        if !activeConnectors.isEmpty {
            VStack(alignment: .leading, spacing: RapidTheme.Space.md) {
                Text(i18n.text(zh: "已配置连接器", en: "Configured Connectors"))
                    .font(RapidFont.sectionTitle)
                    .foregroundStyle(RapidTheme.textPrimary)

                ForEach(activeConnectors) { connector in
                    HStack(alignment: .top, spacing: RapidTheme.Space.md) {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .font(.system(size: 28))
                            .foregroundStyle(RapidTheme.brandPrimary)
                        VStack(alignment: .leading, spacing: RapidTheme.Space.xxs) {
                            Text(connector.name)
                                .font(RapidFont.bodyEmphasis)
                            Text(connector.summary)
                                .font(RapidFont.secondary)
                                .foregroundStyle(RapidTheme.textSecondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(RapidTheme.Space.lg)
                    .youziSimpleCard()
                }
            }
        }

        VStack(alignment: .leading, spacing: RapidTheme.Space.md) {
            Text(i18n.text(zh: "开源 MCP 服务推荐", en: "Recommended Open-Source MCP Servers"))
                .font(RapidFont.sectionTitle)
                .foregroundStyle(RapidTheme.textPrimary)

            ForEach(YouziOpenSourceCatalog.mcpServers) { item in
                openSourceRow(item: item, iconName: "arrow.triangle.branch")
            }
        }
        .padding(.top, RapidTheme.Space.md)
    }

    private func openSourceRow(item: YouziOpenSourceCatalog.Item, iconName: String) -> some View {
        HStack(alignment: .top, spacing: RapidTheme.Space.md) {
            Image(systemName: iconName)
                .font(.system(size: 24))
                .foregroundStyle(RapidTheme.textSecondary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: RapidTheme.Space.xxs) {
                Text(item.name)
                    .font(RapidFont.bodyEmphasis)
                Text(item.summary)
                    .font(RapidFont.secondary)
                    .foregroundStyle(RapidTheme.textSecondary)
            }
            Spacer(minLength: 0)
            if let url = item.url {
                Button {
                    openURL(url)
                } label: {
                    Label(i18n.text(zh: "查看", en: "View"), systemImage: "arrow.up.right")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(RapidTheme.Space.lg)
        .youziSimpleCard()
    }

    private var addExpertSheet: some View {
        VStack(alignment: .leading, spacing: RapidTheme.Space.lg) {
            HStack {
                Text(i18n.text(zh: "添加自定义专家", en: "Add Custom Expert"))
                    .font(RapidFont.pageTitle)
                Spacer()
                Button(i18n.text(zh: "取消", en: "Cancel")) {
                    showingAddExpertSheet = false
                }
                .buttonStyle(.plain)
            }

            Divider()

            VStack(alignment: .leading, spacing: RapidTheme.Space.sm) {
                Text(i18n.text(zh: "专家名称", en: "Expert Name"))
                    .font(RapidFont.bodyEmphasis)
                TextField(i18n.text(zh: "例如：全栈工程师", en: "e.g., Full Stack Engineer"), text: $newExpertName)
                    .textFieldStyle(.roundedBorder)

                Text(i18n.text(zh: "角色简述", en: "Role Summary"))
                    .font(RapidFont.bodyEmphasis)
                TextField(i18n.text(zh: "一句话描述该专家的主要特长", en: "Brief summary of strengths"), text: $newExpertSummary)
                    .textFieldStyle(.roundedBorder)

                Text(i18n.text(zh: "系统指令与角色设定", en: "System Instructions"))
                    .font(RapidFont.bodyEmphasis)
                TextEditor(text: $newExpertInstructions)
                    .font(RapidFont.secondary)
                    .frame(minHeight: 120)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(RapidTheme.hairline, lineWidth: 1)
                    )
            }

            Spacer()

            HStack {
                Spacer()
                Button {
                    let name = newExpertName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    let helper = YouziHelper(
                        name: name,
                        summary: newExpertSummary.trimmingCharacters(in: .whitespaces),
                        systemInstructions: newExpertInstructions.trimmingCharacters(in: .whitespaces),
                        source: YouziManifestSource(kind: .userCreated, identifier: UUID().uuidString, version: "1.0.0"),
                        state: .active,
                        isFavorite: false
                    )
                    productModel.save(helper)
                    showingAddExpertSheet = false
                } label: {
                    Text(i18n.text(zh: "保存专家", en: "Save Expert"))
                }
                .buttonStyle(.borderedProminent)
                .disabled(newExpertName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(RapidTheme.Space.xl)
    }

    private var addConnectorSheet: some View {
        VStack(alignment: .leading, spacing: RapidTheme.Space.lg) {
            HStack {
                Text(i18n.text(zh: "添加 MCP 连接器", en: "Add MCP Connector"))
                    .font(RapidFont.pageTitle)
                Spacer()
                Button(i18n.text(zh: "取消", en: "Cancel")) {
                    showingAddConnectorSheet = false
                }
                .buttonStyle(.plain)
            }

            Divider()

            VStack(alignment: .leading, spacing: RapidTheme.Space.sm) {
                Text(i18n.text(zh: "连接器名称", en: "Connector Name"))
                    .font(RapidFont.bodyEmphasis)
                TextField(i18n.text(zh: "例如：SQLite 本地数据库", en: "e.g., SQLite Database"), text: $newConnectorName)
                    .textFieldStyle(.roundedBorder)

                Text(i18n.text(zh: "MCP 服务标识", en: "MCP Server Name"))
                    .font(RapidFont.bodyEmphasis)
                TextField(i18n.text(zh: "例如：sqlite-local", en: "e.g., sqlite-local"), text: $newConnectorServerName)
                    .textFieldStyle(.roundedBorder)

                Text(i18n.text(zh: "连接器描述", en: "Description"))
                    .font(RapidFont.bodyEmphasis)
                TextField(i18n.text(zh: "简要说明该连接器提供的工具与数据能力", en: "Brief summary of tools"), text: $newConnectorSummary)
                    .textFieldStyle(.roundedBorder)
            }

            Spacer()

            HStack {
                Spacer()
                Button {
                    let name = newConnectorName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    let sName = newConnectorServerName.trimmingCharacters(in: .whitespaces).isEmpty
                        ? name
                        : newConnectorServerName.trimmingCharacters(in: .whitespaces)
                    let connector = YouziConnector(
                        name: name,
                        summary: newConnectorSummary.trimmingCharacters(in: .whitespaces),
                        adapter: .mcp,
                        authentication: .none,
                        source: YouziManifestSource(kind: .userCreated, identifier: UUID().uuidString, version: "1.0.0"),
                        state: .active
                    )
                    productModel.save(connector)
                    showingAddConnectorSheet = false
                } label: {
                    Text(i18n.text(zh: "保存连接器", en: "Save Connector"))
                }
                .buttonStyle(.borderedProminent)
                .disabled(newConnectorName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(RapidTheme.Space.xl)
    }
}

struct YouziSimpleKnowMePage: View {
    @Environment(YouziI18nConfig.self) private var i18n
    let nodes: [YouziMemoryNode]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: RapidTheme.Space.xl) {
                YouziSimpleDomainPageHeader(
                    title: i18n.text(zh: "知我", en: "About Me"),
                    subtitle: i18n.text(zh: "查看你已确认让柚子记住的事实、偏好和目标。", en: "View facts, preferences, and goals you have confirmed for Youzi to remember.")
                )

                if confirmedNodes.isEmpty {
                    Text(i18n.text(zh: "还没有已确认的内容。柚子不会把未确认的推测当作了解你的事实。", en: "No confirmed memory yet. Youzi does not treat unconfirmed guesses as facts."))
                        .font(RapidFont.body)
                        .foregroundStyle(RapidTheme.textSecondary)
                        .padding(RapidTheme.Space.lg)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .youziSimpleCard()
                } else {
                    ForEach(confirmedNodes) { node in
                        VStack(alignment: .leading, spacing: RapidTheme.Space.xs) {
                            Label(node.label, systemImage: node.kind.systemImage)
                                .font(RapidFont.bodyEmphasis)
                            Text(node.content)
                                .font(RapidFont.body)
                                .textSelection(.enabled)
                            Text(i18n.text(zh: "\(node.citationIDs.count) 条依据", en: "\(node.citationIDs.count) citations"))
                                .font(RapidFont.caption)
                                .foregroundStyle(RapidTheme.textSecondary)
                        }
                        .padding(RapidTheme.Space.lg)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .youziSimpleCard()
                        .accessibilityIdentifier("YouziSimple.Memory.\(node.id.uuidString)")
                    }
                }
            }
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(RapidTheme.Space.xl)
        }
        .accessibilityIdentifier("YouziSimple.Surface.knowMe")
    }

    private var confirmedNodes: [YouziMemoryNode] {
        nodes
            .filter { $0.state == .confirmed }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
}

private struct YouziSimpleDomainPageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: RapidTheme.Space.sm) {
            Text(title)
                .font(RapidFont.pageTitle)
            Text(subtitle)
                .font(RapidFont.body)
                .foregroundStyle(RapidTheme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension View {
    func youziSimpleCard() -> some View {
        background(
            RoundedRectangle(cornerRadius: RapidTheme.Radius.card, style: .continuous)
                .fill(RapidTheme.surfaceRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RapidTheme.Radius.card, style: .continuous)
                .strokeBorder(RapidTheme.hairline, lineWidth: 1)
        )
    }
}

private extension YouziWorkspaceLocation {
    func displayName(isChinese: Bool = true) -> String {
        switch self {
        case .managed: isChinese ? "柚子管理的文件夹" : "Youzi Managed Folder"
        case let .securityScopedBookmark(_, displayPath):
            URL(fileURLWithPath: displayPath).lastPathComponent
        }
    }
}

private extension YouziMemoryNodeKind {
    var systemImage: String {
        switch self {
        case .preference: "heart"
        case .goal: "target"
        case .habit: "repeat"
        case .person, .user: "person"
        case .organization: "building.2"
        case .location: "mappin"
        case .project: "square.stack.3d.up"
        case .topic: "number"
        case .event: "calendar"
        case .file: "doc"
        case .artifact: "sparkles.rectangle.stack"
        }
    }
}
