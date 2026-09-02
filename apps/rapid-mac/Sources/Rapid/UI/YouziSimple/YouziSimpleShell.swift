import SwiftUI

/// The first task-first Simple Mode shell. All live data comes from the same
/// environment objects Professional Mode uses; these pages only reorganize and
/// rename that state for a lower-cognitive-load presentation.
struct YouziSimpleShell: View {
    @Environment(YouziExperienceModeConfig.self) private var experienceMode
    @Environment(ChatViewModel.self) private var chat
    @Environment(MemoryStore.self) private var memoryStore

    let assistantAlias: String
    let onPrepareAssistant: () -> Void
    let onOpenSettings: () -> Void

    @State private var selection: YouziSimpleDestination = .newTask

    var body: some View {
        NavigationSplitView {
            sidebar
                .background(RapidTheme.surfaceSidebar)
                .navigationSplitViewColumnWidth(min: 196, ideal: 224, max: 260)
        } detail: {
            destination
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RapidTheme.surfaceCanvas)
        }
        .navigationSplitViewStyle(.balanced)
        .accessibilityIdentifier("YouziSimple.Shell")
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
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

            VStack(spacing: RapidTheme.Space.xxs) {
                ForEach(YouziSimpleDestination.allCases) { destination in
                    navigationRow(destination)
                }
            }
            .padding(.horizontal, RapidTheme.Space.sm)

            Divider()
                .padding(.vertical, RapidTheme.Space.md)
                .padding(.horizontal, RapidTheme.Space.lg)

            Text("最近任务")
                .font(RapidFont.groupLabel)
                .foregroundStyle(RapidTheme.textSecondary)
                .padding(.horizontal, RapidTheme.Space.lg)
                .padding(.bottom, RapidTheme.Space.sm)

            ScrollView {
                LazyVStack(spacing: RapidTheme.Space.xxs) {
                    if recentTasks.isEmpty {
                        Text("最近任务会显示在这里。")
                            .font(RapidFont.caption)
                            .foregroundStyle(RapidTheme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, RapidTheme.Space.lg)
                            .padding(.vertical, RapidTheme.Space.sm)
                    } else {
                        ForEach(recentTasks) { conversation in
                            Button {
                                chat.selectConversation(conversation.id)
                                selection = .newTask
                            } label: {
                                HStack(spacing: RapidTheme.Space.sm) {
                                    Image(systemName: "text.bubble")
                                        .foregroundStyle(RapidTheme.textSecondary)
                                    Text(conversation.title)
                                        .font(RapidFont.secondary)
                                        .foregroundStyle(RapidTheme.textPrimary)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, RapidTheme.Space.md)
                                .frame(minHeight: 36)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier(
                                "YouziSimple.RecentTask.\(conversation.id.uuidString)"
                            )
                        }
                    }
                }
                .padding(.horizontal, RapidTheme.Space.sm)
            }
            .scrollIndicators(.never)

            Divider()
                .padding(.horizontal, RapidTheme.Space.lg)

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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func navigationRow(_ destination: YouziSimpleDestination) -> some View {
        let isSelected = selection == destination
        return Button {
            if destination == .newTask {
                chat.newConversation()
            }
            selection = destination
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
                assistantAlias: assistantAlias,
                onPrepareAssistant: onPrepareAssistant,
                onOpenProfessional: { experienceMode.mode = .professional },
                onNavigate: { selection = $0 }
            )
        case .workspaces:
            YouziSimpleEmptyPage(
                destination: .workspaces,
                title: "让工作各得其所",
                message: "工作空间是柚子在任务中可以使用的文件夹。需要处理本地文件时，你可以选择一个工作空间。",
                actionTitle: "新建任务",
                action: startNewTask
            )
        case .helpers:
            YouziHelpersPage(onStartTask: startNewTask)
        case .knowMe:
            YouziKnowMePage(memoryStore: memoryStore)
        case .results:
            YouziResultsPage(
                conversations: chat.conversations.filter { !$0.isArchived },
                onOpen: openTask,
                onStartTask: startNewTask
            )
        }
    }

    private var recentTasks: [ChatConversation] {
        Array(chat.conversations.lazy.filter { !$0.isArchived }.prefix(6))
    }

    private func startNewTask() {
        chat.newConversation()
        selection = .newTask
    }

    private func openTask(_ id: UUID) {
        chat.selectConversation(id)
        selection = .newTask
    }
}

private struct YouziSimpleEmptyPage: View {
    let destination: YouziSimpleDestination
    let title: String
    let message: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: RapidTheme.Space.lg) {
            Image(systemName: destination.systemImage)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(RapidTheme.brandPrimary)
                .frame(width: 72, height: 72)
                .background(Circle().fill(RapidTheme.brandPrimaryTint))
            Text(title)
                .font(RapidFont.pageTitle)
            Text(message)
                .font(RapidFont.body)
                .foregroundStyle(RapidTheme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            Button(actionTitle, action: action)
                .buttonStyle(.borderedProminent)
        }
        .padding(RapidTheme.Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("YouziSimple.Surface.\(destination.rawValue)")
    }
}

private struct YouziHelpersPage: View {
    let onStartTask: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RapidTheme.Space.xl) {
                YouziSimplePageHeader(
                    title: "帮手",
                    subtitle: "选择熟悉的工作方式，或让柚子自动匹配合适的能力。"
                )

                VStack(alignment: .leading, spacing: RapidTheme.Space.md) {
                    HStack(alignment: .top, spacing: RapidTheme.Space.lg) {
                        YouziLogo(size: 44)
                        VStack(alignment: .leading, spacing: RapidTheme.Space.xs) {
                            Text("柚子助手")
                                .font(RapidFont.sectionTitle)
                            Text("适合写作、规划、研究和日常问题的贴心通用帮手。")
                                .font(RapidFont.secondary)
                                .foregroundStyle(RapidTheme.textSecondary)
                        }
                        Spacer(minLength: 0)
                        Label("可用", systemImage: "checkmark.circle.fill")
                            .font(RapidFont.caption)
                            .foregroundStyle(RapidTheme.green)
                    }
                    Divider()
                    HStack {
                        Label("默认在本地运行", systemImage: "lock.shield")
                            .font(RapidFont.caption)
                            .foregroundStyle(RapidTheme.textSecondary)
                        Spacer(minLength: 0)
                        Button("新建任务", action: onStartTask)
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(RapidTheme.Space.lg)
                .background(
                    RoundedRectangle(cornerRadius: RapidTheme.Radius.card, style: .continuous)
                        .fill(RapidTheme.surfaceRaised)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: RapidTheme.Radius.card, style: .continuous)
                        .strokeBorder(RapidTheme.hairline, lineWidth: 1)
                )
            }
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(RapidTheme.Space.xl)
        }
        .accessibilityIdentifier("YouziSimple.Surface.helpers")
    }
}

private struct YouziKnowMePage: View {
    let memoryStore: MemoryStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RapidTheme.Space.xl) {
                YouziSimplePageHeader(
                    title: "知我",
                    subtitle: "查看柚子可以使用的事实和偏好，让之后的帮助更懂你。"
                )

                if memoryStore.entries.isEmpty {
                    VStack(spacing: RapidTheme.Space.lg) {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .font(.system(size: 34))
                            .foregroundStyle(RapidTheme.brandPrimary)
                        Text("还没有保存内容")
                            .font(RapidFont.sectionTitle)
                        Text("当你选择保存有用的偏好或事实后，它们会显示在这里，并始终由你掌控。")
                            .font(RapidFont.body)
                            .foregroundStyle(RapidTheme.textSecondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 460)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, RapidTheme.Space.huge)
                } else {
                    LazyVStack(spacing: RapidTheme.Space.md) {
                        ForEach(memoryStore.entries) { entry in
                            HStack(alignment: .top, spacing: RapidTheme.Space.md) {
                                Image(systemName: "circle.hexagongrid")
                                    .foregroundStyle(RapidTheme.brandPrimary)
                                VStack(alignment: .leading, spacing: RapidTheme.Space.xs) {
                                    Text(entry.content)
                                        .font(RapidFont.body)
                                        .textSelection(.enabled)
                                    Text(entry.evidenceCount == 1 ? "1 条依据" : "\(entry.evidenceCount) 条依据")
                                        .font(RapidFont.caption)
                                        .foregroundStyle(RapidTheme.textSecondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(RapidTheme.Space.lg)
                            .background(
                                RoundedRectangle(cornerRadius: RapidTheme.Radius.card, style: .continuous)
                                    .fill(RapidTheme.surfaceRaised)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: RapidTheme.Radius.card, style: .continuous)
                                    .strokeBorder(RapidTheme.hairline, lineWidth: 1)
                            )
                        }
                    }
                }
            }
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(RapidTheme.Space.xl)
        }
        .accessibilityIdentifier("YouziSimple.Surface.knowMe")
    }
}

private struct YouziResultsPage: View {
    let conversations: [ChatConversation]
    let onOpen: (UUID) -> Void
    let onStartTask: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RapidTheme.Space.xl) {
                YouziSimplePageHeader(
                    title: "成果",
                    subtitle: "回到柚子帮你完成的工作。"
                )

                if conversations.isEmpty {
                    YouziSimpleEmptyPage(
                        destination: .results,
                        title: "成果会汇集在这里",
                        message: "完成任务后，你可以随时回到对话和任务成果。",
                        actionTitle: "新建任务",
                        action: onStartTask
                    )
                    .frame(minHeight: 360)
                } else {
                    LazyVStack(spacing: RapidTheme.Space.sm) {
                        ForEach(conversations) { conversation in
                            Button { onOpen(conversation.id) } label: {
                                HStack(spacing: RapidTheme.Space.md) {
                                    Image(systemName: "doc.text")
                                        .foregroundStyle(RapidTheme.brandPrimary)
                                        .frame(width: 28, height: 28)
                                        .background(Circle().fill(RapidTheme.brandPrimaryTint))
                                    VStack(alignment: .leading, spacing: RapidTheme.Space.xs) {
                                        Text(conversation.title)
                                            .font(RapidFont.bodyEmphasis)
                                            .foregroundStyle(RapidTheme.textPrimary)
                                            .lineLimit(1)
                                        Text(conversation.updatedAt, style: .relative)
                                            .font(RapidFont.caption)
                                            .foregroundStyle(RapidTheme.textSecondary)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right")
                                        .foregroundStyle(RapidTheme.textSecondary)
                                }
                                .padding(RapidTheme.Space.lg)
                                .background(
                                    RoundedRectangle(cornerRadius: RapidTheme.Radius.card, style: .continuous)
                                        .fill(RapidTheme.surfaceRaised)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: RapidTheme.Radius.card, style: .continuous)
                                        .strokeBorder(RapidTheme.hairline, lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier(
                                "YouziSimple.Results.\(conversation.id.uuidString)"
                            )
                        }
                    }
                }
            }
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(RapidTheme.Space.xl)
        }
        .accessibilityIdentifier("YouziSimple.Surface.results")
    }
}

private struct YouziSimplePageHeader: View {
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
