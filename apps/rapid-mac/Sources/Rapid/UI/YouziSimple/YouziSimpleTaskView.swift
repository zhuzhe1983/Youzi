import SwiftUI

/// Simple Mode's task surface. It deliberately talks to the app-owned
/// `ChatViewModel` and `ServerManager` from the environment: the simplified
/// presentation changes language and hierarchy, never the underlying task or
/// model lifecycle.
struct YouziSimpleTaskView: View {
    @Environment(ChatViewModel.self) private var chat
    @Environment(ServerManager.self) private var server

    let assistantAlias: String
    let onPrepareAssistant: () -> Void
    let onOpenProfessional: () -> Void
    let onNavigate: (YouziSimpleDestination) -> Void

    /// Scene storage keeps an unfinished request intact while onboarding or
    /// Professional Mode temporarily replaces this presentation.
    @SceneStorage("YouziSimple.NewTask.draft.v1") private var draft = ""
    @State private var focusRequest = 0

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
        VStack(spacing: 0) {
            if chat.messages.isEmpty {
                welcome
            } else {
                transcript
            }
            Divider()
            composer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RapidTheme.surfaceCanvas)
        .accessibilityIdentifier("YouziSimple.Surface.newTask")
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
                        Button("选择工作空间…") {
                            onNavigate(.workspaces)
                        }
                        Button("使用帮手或已连接应用…") {
                            onNavigate(.helpers)
                        }
                    } label: {
                        Label("添加", systemImage: "plus")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityIdentifier("YouziSimple.NewTask.Add")

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
        draft = ""
        focusRequest &+= 1
        chat.send(request, alias: assistantAlias)
    }

}
