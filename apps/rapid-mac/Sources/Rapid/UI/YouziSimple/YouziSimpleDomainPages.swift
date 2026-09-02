import SwiftUI

struct YouziSimpleWorkspacesPage: View {
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
                    title: "工作空间",
                    subtitle: "管理柚子可以使用的文件夹，并在这里继续长期项目。"
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
                Label("文件夹", systemImage: "folder")
                    .font(RapidFont.sectionTitle)
                Spacer(minLength: 0)
                TextField("工作空间名称", text: $workspaceName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 190)
                    .accessibilityIdentifier("YouziSimple.Workspaces.WorkspaceName")
                Button("新建空间") {
                    let name = workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    onCreateManagedWorkspace(name)
                    workspaceName = ""
                }
                .buttonStyle(.bordered)
                .disabled(workspaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("YouziSimple.Workspaces.CreateManaged")
                Button("选择文件夹…", action: onChooseWorkspaceFolder)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("YouziSimple.Workspaces.ChooseFolder")
            }

            if activeWorkspaces.isEmpty {
                honestEmptyState(
                    icon: "folder.badge.plus",
                    title: "还没有工作文件夹",
                    message: "为任务选择文件夹后，柚子会在这里显示它和其中的资料。"
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
                Label("项目", systemImage: "square.stack.3d.up")
                    .font(RapidFont.sectionTitle)
                Spacer(minLength: 0)
                TextField("项目名称", text: $projectName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                    .accessibilityIdentifier("YouziSimple.Workspaces.ProjectName")
                Button("新建项目") {
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
                    title: "还没有项目",
                    message: "项目会把相关任务、长期说明和资料放在一起。"
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
                    Text("这个工作空间暂时没有任务或资料。")
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
                    Text("\(workspace.location.displayName) · \(relatedTasks.count) 个任务 · \(relatedFiles.count) 个文件")
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
                    Text(project.summary.isEmpty ? "还没有项目说明" : project.summary)
                        .font(RapidFont.secondary)
                        .foregroundStyle(RapidTheme.textSecondary)
                        .lineLimit(2)
                    Text("\(relatedTasks.count) 个任务 · \(resourceCount) 份资料")
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
    let helpers: [YouziHelper]
    let onStartTask: (YouziHelper) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: RapidTheme.Space.xl) {
                YouziSimpleDomainPageHeader(
                    title: "帮手",
                    subtitle: "选择一种熟悉的工作方式，再从可编辑的任务草稿开始。"
                )

                if activeHelpers.isEmpty {
                    Text("当可用帮手安装后，会显示在这里。你仍然可以在“新任务”中直接向柚子提出需求。")
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
                                Text("来源版本 \(helper.source.version)")
                                    .font(RapidFont.caption)
                                    .foregroundStyle(RapidTheme.textSecondary)
                            }
                            Spacer(minLength: 0)
                            Button("用这个帮手新建任务") {
                                onStartTask(helper)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(RapidTheme.Space.lg)
                        .youziSimpleCard()
                        .accessibilityIdentifier("YouziSimple.Helper.\(helper.id.uuidString)")
                    }
                }
            }
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(RapidTheme.Space.xl)
        }
        .accessibilityIdentifier("YouziSimple.Surface.helpers")
    }

    private var activeHelpers: [YouziHelper] {
        helpers
            .filter { $0.state == .active }
            .sorted { ($0.isFavorite ? 0 : 1, $0.name) < ($1.isFavorite ? 0 : 1, $1.name) }
    }
}

struct YouziSimpleKnowMePage: View {
    let nodes: [YouziMemoryNode]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: RapidTheme.Space.xl) {
                YouziSimpleDomainPageHeader(
                    title: "知我",
                    subtitle: "查看你已确认让柚子记住的事实、偏好和目标。"
                )

                if confirmedNodes.isEmpty {
                    Text("还没有已确认的内容。柚子不会把未确认的推测当作了解你的事实。")
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
                            Text("\(node.citationIDs.count) 条依据")
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
    var displayName: String {
        switch self {
        case .managed: "柚子管理的文件夹"
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
