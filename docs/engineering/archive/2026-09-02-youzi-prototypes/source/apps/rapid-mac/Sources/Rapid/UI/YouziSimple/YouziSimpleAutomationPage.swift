import SwiftUI

struct YouziSimpleAutomationPage: View {
    @Environment(YouziProductModel.self) private var productModel
    @Environment(YouziAutomationCenter.self) private var automationCenter

    @State private var selectedAutomationID: UUID?
    @State private var editorSeed: YouziAutomationEditorSeed?

    private var automations: [YouziAutomation] {
        productModel.scheduledAutomations
            .filter { $0.state != .archived }
            .sorted {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    private var selectedAutomation: YouziAutomation? {
        guard let selectedAutomationID else { return automations.first }
        return automations.first { $0.id == selectedAutomationID } ?? automations.first
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if automations.isEmpty {
                emptyState
            } else {
                HSplitView {
                    automationList
                        .frame(minWidth: 260, idealWidth: 300, maxWidth: 360)
                    if let selectedAutomation {
                        automationDetail(selectedAutomation)
                            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }
        .sheet(item: $editorSeed) { seed in
            YouziSimpleAutomationEditor(seed: seed)
                .environment(productModel)
                .environment(automationCenter)
                .frame(minWidth: 720, minHeight: 700)
        }
        .alert("定时任务没有完成", isPresented: errorBinding) {
            Button("好", role: .cancel) { automationCenter.clearFeedback() }
        } message: {
            Text(errorCopy(automationCenter.lastError))
        }
        .task {
            await automationCenter.refresh()
            if selectedAutomationID == nil { selectedAutomationID = automations.first?.id }
        }
        .onChange(of: automations.map(\.id)) { _, ids in
            if let selectedAutomationID, ids.contains(selectedAutomationID) { return }
            self.selectedAutomationID = ids.first
        }
        .accessibilityIdentifier("YouziSimple.Automations.Page")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: RapidTheme.Space.md) {
            VStack(alignment: .leading, spacing: RapidTheme.Space.xs) {
                Text("定时帮我")
                    .font(RapidFont.windowTitle)
                    .foregroundStyle(RapidTheme.textPrimary)
                Label("仅在 Youzi 运行时执行", systemImage: "power")
                    .font(RapidFont.secondary)
                    .foregroundStyle(RapidTheme.textSecondary)
            }
            Spacer(minLength: 0)
            Button {
                editorSeed = .new
            } label: {
                Label("新建定时任务", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("YouziSimple.Automations.Create")
        }
        .padding(RapidTheme.Space.xl)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("还没有定时任务", systemImage: "calendar.badge.clock")
        } description: {
            Text("设置后，Youzi 会在你指定的时间开始任务。仅在 Youzi 运行时执行。")
        } actions: {
            Button("创建第一个定时任务") { editorSeed = .new }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("YouziSimple.Automations.Empty")
    }

    private var automationList: some View {
        List(selection: $selectedAutomationID) {
            ForEach(automations) { automation in
                VStack(alignment: .leading, spacing: RapidTheme.Space.xs) {
                    HStack(spacing: RapidTheme.Space.xs) {
                        Circle()
                            .fill(statusColor(automation.state))
                            .frame(width: 8, height: 8)
                        Text(automation.name)
                            .font(RapidFont.bodyEmphasis)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    Text(scheduleCopy(automation.trigger))
                        .font(RapidFont.caption)
                        .foregroundStyle(RapidTheme.textSecondary)
                        .lineLimit(2)
                    Text(stateCopy(automation.state))
                        .font(RapidFont.caption)
                        .foregroundStyle(
                            automation.state == .needsAttention
                                ? RapidTheme.statusError : RapidTheme.textSecondary
                        )
                }
                .padding(.vertical, RapidTheme.Space.xs)
                .tag(automation.id)
                .accessibilityIdentifier(
                    "YouziSimple.Automations.Row.\(automation.id.uuidString)"
                )
            }
        }
        .listStyle(.sidebar)
    }

    private func automationDetail(_ automation: YouziAutomation) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RapidTheme.Space.xl) {
                HStack(alignment: .top, spacing: RapidTheme.Space.md) {
                    VStack(alignment: .leading, spacing: RapidTheme.Space.xs) {
                        Text(automation.name)
                            .font(RapidFont.windowTitle)
                        Text(scheduleCopy(automation.trigger))
                            .font(RapidFont.body)
                            .foregroundStyle(RapidTheme.textSecondary)
                    }
                    Spacer(minLength: 0)
                    statusBadge(automation.state)
                }

                if automation.state == .needsAttention {
                    attentionCard(automation)
                }

                actionBar(automation)
                definitionCard(automation)
                historySection(automation)
            }
            .padding(RapidTheme.Space.xl)
            .frame(maxWidth: 880, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .accessibilityIdentifier("YouziSimple.Automations.Detail")
    }

    private func actionBar(_ automation: YouziAutomation) -> some View {
        HStack(spacing: RapidTheme.Space.sm) {
            Button {
                Task { await automationCenter.runNow(automationID: automation.id) }
            } label: {
                Label("立即运行", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(automation.state != .active || automationCenter.isWorking)
            .accessibilityIdentifier("YouziSimple.Automations.RunNow")

            if automation.state == .paused {
                Button("启用") {
                    Task { await automationCenter.resume(automationID: automation.id) }
                }
            } else if automation.state == .active {
                Button("暂停") {
                    Task { await automationCenter.pause(automationID: automation.id) }
                }
            }

            Button("编辑") {
                editorSeed = YouziAutomationEditorSeed(
                    automation: automation,
                    permissions: automationCenter.permissionDrafts(for: automation)
                )
            }

            Menu {
                Button("归档", role: .destructive) {
                    Task { await automationCenter.archive(automationID: automation.id) }
                }
            } label: {
                Label("更多", systemImage: "ellipsis")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            Spacer(minLength: 0)
        }
        .controlSize(.large)
    }

    private func attentionCard(_ automation: YouziAutomation) -> some View {
        VStack(alignment: .leading, spacing: RapidTheme.Space.sm) {
            Label("需要你确认后才能继续", systemImage: "exclamationmark.triangle.fill")
                .font(RapidFont.bodyEmphasis)
                .foregroundStyle(RapidTheme.statusError)
            Text("任务内容、时间或权限快照已变化。请检查设置并重新确认；旧授权不会沿用到新版本。")
                .font(RapidFont.secondary)
                .foregroundStyle(RapidTheme.textSecondary)
            Button("检查并重新确认") {
                editorSeed = YouziAutomationEditorSeed(
                    automation: automation,
                    permissions: automationCenter.permissionDrafts(for: automation)
                )
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(RapidTheme.Space.lg)
        .background(RapidTheme.statusError.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("YouziSimple.Automations.NeedsAttention")
    }

    private func definitionCard(_ automation: YouziAutomation) -> some View {
        VStack(alignment: .leading, spacing: RapidTheme.Space.md) {
            Text("执行快照")
                .font(RapidFont.sectionTitle)
            LabeledContent("要做什么", value: automation.action.request)
            LabeledContent("错过时间", value: missedRunCopy(automation.missedRunPolicy))
            LabeledContent(
                "失败重试",
                value: automation.retryPolicy.maximumAttempts > 1
                    ? "最多 \(automation.retryPolicy.maximumAttempts) 次"
                    : "不自动重试"
            )
            LabeledContent("完成通知", value: automation.notificationEnabled ? "开启" : "关闭")
            Label("仅在 Youzi 运行时执行", systemImage: "power")
                .font(RapidFont.caption)
                .foregroundStyle(RapidTheme.textSecondary)
        }
        .padding(RapidTheme.Space.lg)
        .background(RapidTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))
    }

    private func historySection(_ automation: YouziAutomation) -> some View {
        let runs = productModel.automationRuns
            .filter { $0.automationID == automation.id }
            .sorted { $0.createdAt > $1.createdAt }
        return VStack(alignment: .leading, spacing: RapidTheme.Space.md) {
            Text("运行历史")
                .font(RapidFont.sectionTitle)
            if runs.isEmpty {
                Text("还没有运行记录。")
                    .font(RapidFont.secondary)
                    .foregroundStyle(RapidTheme.textSecondary)
            } else {
                ForEach(runs) { run in
                    HStack(alignment: .top, spacing: RapidTheme.Space.md) {
                        Image(systemName: runStatusIcon(run.status))
                            .foregroundStyle(runStatusColor(run.status))
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: RapidTheme.Space.xs) {
                            Text(runStatusCopy(run))
                                .font(RapidFont.bodyEmphasis)
                            Text(run.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(RapidFont.caption)
                                .foregroundStyle(RapidTheme.textSecondary)
                            if let summary = run.summary, !summary.isEmpty {
                                Text(summary)
                                    .font(RapidFont.secondary)
                                    .foregroundStyle(RapidTheme.textSecondary)
                                    .lineLimit(3)
                            }
                            if run.status == .retryScheduled, let nextRetryAt = run.nextRetryAt {
                                Text("将在 \(nextRetryAt.formatted(date: .omitted, time: .shortened)) 重试")
                                    .font(RapidFont.caption)
                                    .foregroundStyle(RapidTheme.statusWarning)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(RapidTheme.Space.md)
                    .background(RapidTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityIdentifier(
                        "YouziSimple.Automations.Run.\(run.id.uuidString)"
                    )
                }
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { automationCenter.lastError != nil },
            set: { if !$0 { automationCenter.clearFeedback() } }
        )
    }
}

private struct YouziAutomationEditorSeed: Identifiable {
    let id = UUID()
    let automation: YouziAutomation?
    let permissions: [YouziAutomationPermissionDraft]

    static var new: Self { .init(automation: nil, permissions: []) }
}

private enum YouziAutomationEditorStep: Int, CaseIterable, Identifiable {
    case task
    case schedule
    case confirm

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .task: "任务"
        case .schedule: "时间"
        case .confirm: "确认"
        }
    }
}

private enum YouziAutomationFrequency: String, CaseIterable, Identifiable {
    case manual
    case daily
    case weekdays
    case weekly
    case interval
    case custom

    var id: String { rawValue }
    var title: String {
        switch self {
        case .manual: "仅手动"
        case .daily: "每天"
        case .weekdays: "工作日"
        case .weekly: "每周"
        case .interval: "固定间隔"
        case .custom: "自定义"
        }
    }
}

private enum YouziAutomationAccountAccess: String, CaseIterable, Identifiable {
    case read
    case write
    case publish

    var id: String { rawValue }
    var title: String {
        switch self {
        case .read: "只读"
        case .write: "允许修改"
        case .publish: "允许发送或发布"
        }
    }

    var permissionKind: YouziPermissionKind {
        switch self {
        case .read: .connectorRead
        case .write: .connectorWrite
        case .publish: .externalPublish
        }
    }
}

private struct YouziSimpleAutomationEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(YouziProductModel.self) private var productModel
    @Environment(YouziAutomationCenter.self) private var automationCenter

    let seed: YouziAutomationEditorSeed

    @State private var step: YouziAutomationEditorStep = .task
    @State private var sourceTaskID: UUID?
    @State private var name: String
    @State private var request: String
    @State private var projectID: UUID?
    @State private var workspaceID: UUID?
    @State private var helperID: UUID?
    @State private var selectedSkillIDs: Set<UUID>
    @State private var selectedAccountIDs: Set<UUID>
    @State private var accountAccess: [UUID: YouziAutomationAccountAccess]
    @State private var frequency: YouziAutomationFrequency
    @State private var timeOfDay: Date
    @State private var weekday: Int
    @State private var intervalMinutes: Int
    @State private var customCron: String
    @State private var timeZoneIdentifier: String
    @State private var missedRunPolicy: YouziAutomationMissedRunPolicy
    @State private var maximumAttempts: Int
    @State private var notificationEnabled: Bool

    init(seed: YouziAutomationEditorSeed) {
        self.seed = seed
        let automation = seed.automation
        let parsed = Self.parse(automation?.trigger)
        _name = State(initialValue: automation?.name ?? "")
        _request = State(initialValue: automation?.action.request ?? "")
        _projectID = State(initialValue: automation?.action.projectID)
        _workspaceID = State(initialValue: automation?.action.workspaceID)
        _helperID = State(initialValue: automation?.action.helperID)
        _selectedSkillIDs = State(initialValue: Set(automation?.action.skillIDs ?? []))
        _selectedAccountIDs = State(
            initialValue: Set(automation?.action.connectionAccountIDs ?? [])
        )
        _accountAccess = State(initialValue: Dictionary(
            uniqueKeysWithValues: (automation?.action.connectionAccountIDs ?? []).map { id in
                let permissions = seed.permissions.filter {
                    $0.targetIdentifier == id.uuidString.lowercased()
                }
                let access: YouziAutomationAccountAccess
                if permissions.contains(where: { $0.kind == .externalPublish }) {
                    access = .publish
                } else if permissions.contains(where: { $0.kind == .connectorWrite }) {
                    access = .write
                } else {
                    access = .read
                }
                return (id, access)
            }
        ))
        _frequency = State(initialValue: parsed.frequency)
        _timeOfDay = State(initialValue: parsed.timeOfDay)
        _weekday = State(initialValue: parsed.weekday)
        _intervalMinutes = State(initialValue: parsed.intervalMinutes)
        _customCron = State(initialValue: parsed.customCron)
        _timeZoneIdentifier = State(initialValue: parsed.timeZoneIdentifier)
        _missedRunPolicy = State(initialValue: automation?.missedRunPolicy ?? .runOnce)
        _maximumAttempts = State(initialValue: automation?.retryPolicy.maximumAttempts ?? 1)
        _notificationEnabled = State(initialValue: automation?.notificationEnabled ?? true)
    }

    var body: some View {
        VStack(spacing: 0) {
            editorHeader
            Divider()
            ScrollView {
                Group {
                    switch step {
                    case .task: taskStep
                    case .schedule: scheduleStep
                    case .confirm: confirmStep
                    }
                }
                .padding(RapidTheme.Space.xl)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            Divider()
            editorFooter
        }
        .alert("无法保存", isPresented: editorErrorBinding) {
            Button("好", role: .cancel) { automationCenter.clearFeedback() }
        } message: {
            Text(errorCopy(automationCenter.lastError))
        }
        .accessibilityIdentifier("YouziSimple.Automations.Editor")
    }

    private var editorHeader: some View {
        VStack(alignment: .leading, spacing: RapidTheme.Space.md) {
            HStack {
                Text(seed.automation == nil ? "新建定时任务" : "编辑定时任务")
                    .font(RapidFont.windowTitle)
                Spacer(minLength: 0)
                Button("取消") { dismiss() }
            }
            HStack(spacing: RapidTheme.Space.sm) {
                stepIndicator(.task)
                stepDivider
                stepIndicator(.schedule)
                stepDivider
                stepIndicator(.confirm)
            }
        }
        .padding(RapidTheme.Space.xl)
    }

    private func stepIndicator(_ item: YouziAutomationEditorStep) -> some View {
        HStack(spacing: RapidTheme.Space.xs) {
            Text("\(item.rawValue + 1)")
                .font(RapidFont.caption)
                .frame(width: 24, height: 24)
                .background(
                    item.rawValue <= step.rawValue
                        ? RapidTheme.brandPrimary : RapidTheme.surfaceRaised,
                    in: Circle()
                )
                .foregroundStyle(
                    item.rawValue <= step.rawValue ? Color.white : RapidTheme.textSecondary
                )
            Text(item.title)
                .font(RapidFont.secondary)
                .foregroundStyle(
                    item == step ? RapidTheme.textPrimary : RapidTheme.textSecondary
                )
        }
    }

    private var stepDivider: some View {
        Rectangle()
            .fill(RapidTheme.hairlineStrong)
            .frame(height: 1)
    }

    private var taskStep: some View {
        VStack(alignment: .leading, spacing: RapidTheme.Space.xl) {
            editorSection("任务内容") {
                Picker("从已有任务带入", selection: $sourceTaskID) {
                    Text("不带入").tag(Optional<UUID>.none)
                    ForEach(productModel.tasks.filter { $0.status != .archived }) { task in
                        Text(task.title.isEmpty ? "未命名任务" : task.title)
                            .tag(Optional(task.id))
                    }
                }
                .onChange(of: sourceTaskID) { _, id in applyTask(id) }
                TextField("名称", text: $name, prompt: Text("例如：每天整理项目进展"))
                Text("要做什么")
                    .font(RapidFont.secondary)
                TextEditor(text: $request)
                    .frame(minHeight: 100)
                    .padding(RapidTheme.Space.xs)
                    .background(RapidTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
            }

            editorSection("工作范围") {
                Picker("项目", selection: $projectID) {
                    Text("不指定").tag(Optional<UUID>.none)
                    ForEach(productModel.projects.filter { $0.state == .active }) { project in
                        Text(project.name).tag(Optional(project.id))
                    }
                }
                Picker("工作空间", selection: $workspaceID) {
                    Text("由任务创建").tag(Optional<UUID>.none)
                    ForEach(productModel.workspaces.filter { $0.state == .active }) { workspace in
                        Text(workspace.name).tag(Optional(workspace.id))
                    }
                }
            }

            editorSection("帮手与技能") {
                Picker("帮手", selection: $helperID) {
                    Text("使用默认帮手").tag(Optional<UUID>.none)
                    ForEach(productModel.helpers.filter { $0.state == .active }) { helper in
                        Text(helper.name).tag(Optional(helper.id))
                    }
                }
                selectableRows(
                    productModel.skills.filter { $0.state == .active },
                    selection: $selectedSkillIDs,
                    title: { $0.name },
                    subtitle: { $0.summary }
                )
            }

            editorSection("已连接应用") {
                if activeAccounts.isEmpty {
                    Text("没有可用的已连接应用。")
                        .font(RapidFont.secondary)
                        .foregroundStyle(RapidTheme.textSecondary)
                } else {
                    ForEach(activeAccounts) { account in
                        VStack(alignment: .leading, spacing: RapidTheme.Space.sm) {
                            Toggle(account.displayName, isOn: selectedBinding(account.id))
                            if selectedAccountIDs.contains(account.id) {
                                Picker("允许范围", selection: accessBinding(account.id)) {
                                    ForEach(YouziAutomationAccountAccess.allCases) { access in
                                        Text(access.title).tag(access)
                                    }
                                }
                                .padding(.leading, RapidTheme.Space.lg)
                            }
                        }
                    }
                }
            }
        }
    }

    private var scheduleStep: some View {
        VStack(alignment: .leading, spacing: RapidTheme.Space.xl) {
            editorSection("执行时间") {
                Picker("频率", selection: $frequency) {
                    ForEach(YouziAutomationFrequency.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }

                if frequency == .daily || frequency == .weekdays || frequency == .weekly {
                    DatePicker("时间", selection: $timeOfDay, displayedComponents: .hourAndMinute)
                }
                if frequency == .weekly {
                    Picker("星期", selection: $weekday) {
                        ForEach(0 ..< 7, id: \.self) { value in
                            Text(Self.weekdaySymbols[value]).tag(value)
                        }
                    }
                }
                if frequency == .interval {
                    Stepper("每 \(intervalMinutes) 分钟", value: $intervalMinutes, in: 5 ... 1_440, step: 5)
                }
                if frequency == .custom {
                    TextField("Cron（分 时 日 月 周）", text: $customCron)
                    Text("支持 *、列表、范围和步长，例如 0 9 * * MON-FRI。")
                        .font(RapidFont.caption)
                        .foregroundStyle(RapidTheme.textSecondary)
                }
                if frequency == .daily || frequency == .weekdays
                    || frequency == .weekly || frequency == .custom {
                    TextField("时区", text: $timeZoneIdentifier)
                    Menu("常用时区") {
                        ForEach(Self.commonTimeZones, id: \.self) { zone in
                            Button(zone) { timeZoneIdentifier = zone }
                        }
                    }
                    LabeledContent("夏令时处理", value: "缺失时刻跳过；重复时刻运行两次")
                        .font(RapidFont.secondary)
                }
                Label("仅在 Youzi 运行时执行", systemImage: "power")
                    .font(RapidFont.secondary)
                    .foregroundStyle(RapidTheme.textSecondary)
            }

            editorSection("离线与失败") {
                Picker("错过执行时间", selection: $missedRunPolicy) {
                    Text("下次启动时补跑一次").tag(YouziAutomationMissedRunPolicy.runOnce)
                    Text("跳过").tag(YouziAutomationMissedRunPolicy.skip)
                }
                Stepper("最多尝试 \(maximumAttempts) 次", value: $maximumAttempts, in: 1 ... 4)
                Toggle("完成后通知我", isOn: $notificationEnabled)
                    .onChange(of: notificationEnabled) { _, enabled in
                        guard enabled else { return }
                        Task { await automationCenter.requestNotificationAuthorization() }
                    }
            }
        }
    }

    private var confirmStep: some View {
        VStack(alignment: .leading, spacing: RapidTheme.Space.xl) {
            editorSection("请确认任务快照") {
                summaryRow("名称", name.isEmpty ? "未填写" : name)
                summaryRow("任务", request.isEmpty ? "未填写" : request)
                summaryRow("时间", scheduleSummary)
                summaryRow("工作空间", namedWorkspace)
                summaryRow("帮手", namedHelper)
                summaryRow("技能", selectedSkillNames)
                summaryRow("已连接应用", selectedAccountNames)
                summaryRow("失败重试", maximumAttempts > 1 ? "最多 \(maximumAttempts) 次" : "不自动重试")
            }

            editorSection("长期权限快照") {
                if permissionDrafts.isEmpty {
                    Label("不需要额外权限", systemImage: "checkmark.shield")
                        .foregroundStyle(RapidTheme.statusReady)
                } else {
                    ForEach(permissionDrafts) { permission in
                        HStack(alignment: .top, spacing: RapidTheme.Space.sm) {
                            Image(systemName: permissionIcon(permission.kind))
                                .foregroundStyle(RapidTheme.brandPrimary)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: RapidTheme.Space.xxs) {
                                Text(permissionTitle(permission.kind))
                                    .font(RapidFont.bodyEmphasis)
                                Text(permission.purpose)
                                    .font(RapidFont.caption)
                                    .foregroundStyle(RapidTheme.textSecondary)
                            }
                        }
                    }
                    Text("这些授权只属于这一版定时任务。修改任务、时间或权限后，旧授权会失效并要求重新确认。")
                        .font(RapidFont.caption)
                        .foregroundStyle(RapidTheme.textSecondary)
                }
            }

            Label("仅在 Youzi 运行时执行", systemImage: "power")
                .font(RapidFont.bodyEmphasis)
                .padding(RapidTheme.Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RapidTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var editorFooter: some View {
        HStack(spacing: RapidTheme.Space.sm) {
            if step != .task {
                Button("上一步") { step = YouziAutomationEditorStep(rawValue: step.rawValue - 1)! }
            }
            Spacer(minLength: 0)
            if step == .confirm {
                if !permissionDrafts.isEmpty {
                    Button("不授权，保存草稿") {
                        Task { await save(decision: .denied) }
                    }
                    .disabled(automationCenter.isWorking)
                }
                Button(seed.automation == nil ? "确认并启用" : "保存并重新确认") {
                    Task { await save(decision: .allowed) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canAdvance || automationCenter.isWorking)
                .accessibilityIdentifier("YouziSimple.Automations.Confirm")
            } else {
                Button("下一步") {
                    step = YouziAutomationEditorStep(rawValue: step.rawValue + 1)!
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canAdvance)
            }
        }
        .controlSize(.large)
        .padding(RapidTheme.Space.xl)
    }

    private func save(decision: YouziPermissionDecision) async {
        let id = await automationCenter.saveAndDecide(definitionDraft, decision: decision)
        if id != nil { dismiss() }
    }

    private var definitionDraft: YouziAutomationDefinitionDraft {
        YouziAutomationDefinitionDraft(
            automationID: seed.automation?.id,
            name: name,
            trigger: trigger,
            action: YouziAutomationAction(
                request: request,
                projectID: projectID,
                workspaceID: workspaceID,
                helperID: helperID,
                skillIDs: Array(selectedSkillIDs),
                connectionAccountIDs: Array(selectedAccountIDs)
            ),
            permissions: permissionDrafts,
            missedRunPolicy: missedRunPolicy,
            retryPolicy: .init(
                maximumAttempts: maximumAttempts,
                baseDelaySeconds: 30
            ),
            notificationEnabled: notificationEnabled
        )
    }

    private var trigger: YouziAutomationTrigger {
        switch frequency {
        case .manual:
            return .manual
        case .interval:
            return .interval(seconds: TimeInterval(intervalMinutes * 60), anchorAt: Date())
        case .daily, .weekdays, .weekly, .custom:
            return .schedule(
                cronExpression: cronExpression,
                timeZoneIdentifier: timeZoneIdentifier
            )
        }
    }

    private var cronExpression: String {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: timeOfDay)
        let minute = calendar.component(.minute, from: timeOfDay)
        switch frequency {
        case .daily: return "\(minute) \(hour) * * *"
        case .weekdays: return "\(minute) \(hour) * * MON-FRI"
        case .weekly: return "\(minute) \(hour) * * \(weekday)"
        case .custom: return customCron
        case .manual, .interval: return ""
        }
    }

    private var permissionDrafts: [YouziAutomationPermissionDraft] {
        var values: [YouziAutomationPermissionDraft] = []
        if let workspaceID {
            values.append(.init(
                kind: .workspaceRead,
                targetIdentifier: workspaceID.uuidString.lowercased(),
                purpose: "读取所选工作空间中的任务资料"
            ))
        }
        for accountID in selectedAccountIDs.sorted(by: uuidOrder) {
            let access = effectiveAccountAccess(accountAccess[accountID])
            for kind in accountPermissionKinds(access) {
                values.append(.init(
                    kind: kind,
                    targetIdentifier: accountID.uuidString.lowercased(),
                    purpose: accountPurpose(kind)
                ))
            }
        }

        let requestedKinds = Set(selectedSkills.flatMap(\.requestedPermissions))
        for kind in requestedKinds.sorted(by: { $0.rawValue < $1.rawValue }) {
            switch kind {
            case .networkAccess:
                values.append(.init(
                    kind: kind,
                    targetIdentifier: "builtin.network",
                    purpose: "让所选技能访问网络"
                ))
            case .workspaceRead:
                break // Every selected workspace already receives the exact read grant above.
            case .workspaceWrite:
                if let workspaceID {
                    values.append(.init(
                        kind: kind,
                        targetIdentifier: workspaceID.uuidString.lowercased(),
                        purpose: "让所选技能把成果写入工作空间"
                    ))
                }
            case .connectorRead, .connectorWrite, .externalPublish:
                break // Account rows carry the strongest explicit scope once.
            case .destructiveLocalAction:
                values.append(.init(
                    kind: kind,
                    targetIdentifier: "builtin.local-action",
                    purpose: "允许所选技能执行已明确说明的本地操作"
                ))
            case .microphone:
                values.append(.init(
                    kind: kind,
                    targetIdentifier: "builtin.microphone",
                    purpose: "允许所选技能使用麦克风"
                ))
            case .saveAudio:
                values.append(.init(
                    kind: kind,
                    targetIdentifier: "builtin.audio",
                    purpose: "允许所选技能保存音频"
                ))
            }
        }
        return Dictionary(values.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            .values.sorted { $0.id < $1.id }
    }

    private var requiredAccountAccess: YouziAutomationAccountAccess? {
        let kinds = Set(selectedSkills.flatMap(\.requestedPermissions))
        if kinds.contains(.externalPublish) { return .publish }
        if kinds.contains(.connectorWrite) { return .write }
        if kinds.contains(.connectorRead) { return .read }
        return nil
    }

    private var canAdvance: Bool {
        switch step {
        case .task:
            return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !needsWorkspace
                && (!needsAccount || !selectedAccountIDs.isEmpty)
        case .schedule, .confirm:
            switch frequency {
            case .custom:
                return (try? YouziCronExpression(customCron)) != nil
                    && TimeZone(identifier: timeZoneIdentifier) != nil
            case .daily, .weekdays, .weekly:
                return TimeZone(identifier: timeZoneIdentifier) != nil
            case .interval:
                return intervalMinutes >= 5
            case .manual:
                return true
            }
        }
    }

    private var needsWorkspace: Bool {
        let kinds = Set(selectedSkills.flatMap(\.requestedPermissions))
        return (kinds.contains(.workspaceRead) || kinds.contains(.workspaceWrite))
            && workspaceID == nil
    }

    private var needsAccount: Bool {
        let kinds = Set(selectedSkills.flatMap(\.requestedPermissions))
        return kinds.contains(.connectorRead) || kinds.contains(.connectorWrite)
            || kinds.contains(.externalPublish)
    }

    private var selectedSkills: [YouziSkill] {
        productModel.skills.filter { selectedSkillIDs.contains($0.id) }
    }

    private var activeAccounts: [YouziConnectionAccount] {
        productModel.connectionAccounts.filter { $0.state == .connected }
    }

    private var scheduleSummary: String {
        scheduleCopy(trigger)
    }

    private var namedWorkspace: String {
        guard let workspaceID else { return "由任务创建" }
        return productModel.workspace(id: workspaceID)?.name ?? "工作空间不可用"
    }

    private var namedHelper: String {
        guard let helperID else { return "默认帮手" }
        return productModel.helper(id: helperID)?.name ?? "帮手不可用"
    }

    private var selectedSkillNames: String {
        let names = selectedSkills.map(\.name).sorted()
        return names.isEmpty ? "无" : names.joined(separator: "、")
    }

    private var selectedAccountNames: String {
        let names = activeAccounts.filter { selectedAccountIDs.contains($0.id) }.map(\.displayName)
        return names.isEmpty ? "无" : names.sorted().joined(separator: "、")
    }

    private var editorErrorBinding: Binding<Bool> {
        Binding(
            get: { automationCenter.lastError != nil },
            set: { if !$0 { automationCenter.clearFeedback() } }
        )
    }

    private func applyTask(_ id: UUID?) {
        guard let id, let task = productModel.task(id: id) else { return }
        name = task.title
        request = task.request
        projectID = task.projectID
        workspaceID = task.workspaceID
        helperID = task.helperID
        selectedSkillIDs = Set(task.skillIDs)
        selectedAccountIDs = Set(task.connectionAccountIDs)
        for id in task.connectionAccountIDs where accountAccess[id] == nil {
            accountAccess[id] = requiredAccountAccess ?? .read
        }
    }

    @ViewBuilder
    private func editorSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: RapidTheme.Space.md) {
            Text(title).font(RapidFont.sectionTitle)
            content()
            if title == "帮手与技能", needsWorkspace {
                Label("所选技能需要工作空间，请先选择一个。", systemImage: "exclamationmark.triangle")
                    .font(RapidFont.caption)
                    .foregroundStyle(RapidTheme.statusError)
            }
            if title == "已连接应用", needsAccount && selectedAccountIDs.isEmpty {
                Label("所选技能需要已连接应用，请至少选择一个。", systemImage: "exclamationmark.triangle")
                    .font(RapidFont.caption)
                    .foregroundStyle(RapidTheme.statusError)
            }
        }
        .padding(RapidTheme.Space.lg)
        .background(RapidTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func selectableRows<Item: Identifiable>(
        _ items: [Item],
        selection: Binding<Set<Item.ID>>,
        title: @escaping (Item) -> String,
        subtitle: @escaping (Item) -> String
    ) -> some View where Item.ID == UUID {
        ForEach(items) { item in
            Toggle(isOn: Binding(
                get: { selection.wrappedValue.contains(item.id) },
                set: { selected in
                    if selected { selection.wrappedValue.insert(item.id) }
                    else { selection.wrappedValue.remove(item.id) }
                }
            )) {
                VStack(alignment: .leading, spacing: RapidTheme.Space.xxs) {
                    Text(title(item)).font(RapidFont.bodyEmphasis)
                    Text(subtitle(item))
                        .font(RapidFont.caption)
                        .foregroundStyle(RapidTheme.textSecondary)
                }
            }
        }
    }

    private func selectedBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { selectedAccountIDs.contains(id) },
            set: { selected in
                if selected {
                    selectedAccountIDs.insert(id)
                    accountAccess[id] = accountAccess[id] ?? requiredAccountAccess ?? .read
                } else {
                    selectedAccountIDs.remove(id)
                }
            }
        )
    }

    private func accessBinding(_ id: UUID) -> Binding<YouziAutomationAccountAccess> {
        Binding(
            get: { effectiveAccountAccess(accountAccess[id]) },
            set: { accountAccess[id] = effectiveAccountAccess($0) }
        )
    }

    private func effectiveAccountAccess(
        _ configured: YouziAutomationAccountAccess?
    ) -> YouziAutomationAccountAccess {
        let configured = configured ?? .read
        guard let requiredAccountAccess else { return configured }
        return Self.accessRank(configured) >= Self.accessRank(requiredAccountAccess)
            ? configured : requiredAccountAccess
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value)
                .foregroundStyle(RapidTheme.textSecondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private static let weekdaySymbols = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
    private static let commonTimeZones = [
        "Asia/Shanghai", "Asia/Tokyo", "Europe/London", "Europe/Paris",
        "America/New_York", "America/Chicago", "America/Denver", "America/Los_Angeles",
    ]

    private static func accessRank(_ access: YouziAutomationAccountAccess) -> Int {
        switch access {
        case .read: 0
        case .write: 1
        case .publish: 2
        }
    }

    private static func parse(_ trigger: YouziAutomationTrigger?) -> (
        frequency: YouziAutomationFrequency,
        timeOfDay: Date,
        weekday: Int,
        intervalMinutes: Int,
        customCron: String,
        timeZoneIdentifier: String
    ) {
        let now = Date()
        guard let trigger else {
            return (.daily, now, 1, 60, "0 9 * * *", TimeZone.current.identifier)
        }
        switch trigger {
        case .manual:
            return (.manual, now, 1, 60, "0 9 * * *", TimeZone.current.identifier)
        case .interval(let seconds, _):
            return (.interval, now, 1, max(5, Int(seconds / 60)), "", TimeZone.current.identifier)
        case .schedule(let expression, let zone):
            let parts = expression.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            if parts.count == 5, let minute = Int(parts[0]), let hour = Int(parts[1]),
               let date = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: now) {
                if parts[2] == "*", parts[3] == "*", parts[4] == "*" {
                    return (.daily, date, 1, 60, expression, zone)
                }
                if parts[2] == "*", parts[3] == "*", parts[4].uppercased() == "MON-FRI" {
                    return (.weekdays, date, 1, 60, expression, zone)
                }
                if parts[2] == "*", parts[3] == "*", let day = Int(parts[4]), (0 ... 6).contains(day) {
                    return (.weekly, date, day, 60, expression, zone)
                }
            }
            return (.custom, now, 1, 60, expression, zone)
        }
    }
}

private func uuidOrder(_ lhs: UUID, _ rhs: UUID) -> Bool {
    lhs.uuidString.lowercased() < rhs.uuidString.lowercased()
}

private func scheduleCopy(_ trigger: YouziAutomationTrigger) -> String {
    switch trigger {
    case .manual:
        return "仅手动运行"
    case .interval(let seconds, _):
        let minutes = Int(seconds / 60)
        return minutes.isMultiple(of: 60)
            ? "每 \(minutes / 60) 小时"
            : "每 \(minutes) 分钟"
    case .schedule(let expression, let zone):
        return "\(expression) · \(zone)"
    }
}

private func stateCopy(_ state: YouziAutomationState) -> String {
    switch state {
    case .draft: "草稿"
    case .active: "已启用"
    case .paused: "已暂停"
    case .needsAttention: "需要处理"
    case .archived: "已归档"
    }
}

private func missedRunCopy(_ policy: YouziAutomationMissedRunPolicy) -> String {
    switch policy {
    case .runOnce: "下次启动时补跑一次"
    case .skip: "跳过"
    }
}

private func statusColor(_ state: YouziAutomationState) -> Color {
    switch state {
    case .active: RapidTheme.statusReady
    case .needsAttention: RapidTheme.statusError
    case .paused, .draft: RapidTheme.statusWarning
    case .archived: RapidTheme.textSecondary
    }
}

private func statusBadge(_ state: YouziAutomationState) -> some View {
    Text(stateCopy(state))
        .font(RapidFont.caption)
        .foregroundStyle(statusColor(state))
        .padding(.horizontal, RapidTheme.Space.sm)
        .padding(.vertical, RapidTheme.Space.xs)
        .background(statusColor(state).opacity(0.1), in: Capsule())
}

private func runStatusCopy(_ run: YouziAutomationRun) -> String {
    switch run.status {
    case .queued: "等待运行"
    case .running: "正在运行"
    case .awaitingConfirmation: "等待确认"
    case .retryScheduled: "等待重试（第 \(run.attemptCount) 次）"
    case .completed: "已完成"
    case .failed: "运行失败"
    case .cancelled: "已取消"
    case .skipped: "已跳过"
    }
}

private func runStatusIcon(_ status: YouziAutomationRunStatus) -> String {
    switch status {
    case .queued, .retryScheduled: "clock"
    case .running: "progress.indicator"
    case .awaitingConfirmation: "hand.raised"
    case .completed: "checkmark.circle.fill"
    case .failed: "xmark.circle.fill"
    case .cancelled: "slash.circle"
    case .skipped: "forward.end"
    }
}

private func runStatusColor(_ status: YouziAutomationRunStatus) -> Color {
    switch status {
    case .completed: RapidTheme.statusReady
    case .failed: RapidTheme.statusError
    case .retryScheduled, .awaitingConfirmation: RapidTheme.statusWarning
    default: RapidTheme.textSecondary
    }
}

private func permissionTitle(_ kind: YouziPermissionKind) -> String {
    switch kind {
    case .workspaceRead: "读取工作空间"
    case .workspaceWrite: "写入工作空间"
    case .networkAccess: "访问网络"
    case .connectorRead: "读取已连接应用"
    case .connectorWrite: "修改已连接应用"
    case .externalPublish: "发送或发布到外部"
    case .destructiveLocalAction: "执行本地操作"
    case .microphone: "使用麦克风"
    case .saveAudio: "保存音频"
    }
}

private func permissionIcon(_ kind: YouziPermissionKind) -> String {
    switch kind {
    case .workspaceRead, .workspaceWrite: "folder"
    case .networkAccess: "network"
    case .connectorRead, .connectorWrite: "link"
    case .externalPublish: "paperplane"
    case .destructiveLocalAction: "exclamationmark.shield"
    case .microphone: "mic"
    case .saveAudio: "waveform"
    }
}

private func accountPermissionKinds(
    _ access: YouziAutomationAccountAccess
) -> [YouziPermissionKind] {
    switch access {
    case .read: [.connectorRead]
    case .write: [.connectorRead, .connectorWrite]
    case .publish: [.connectorRead, .connectorWrite, .externalPublish]
    }
}

private func accountPurpose(_ kind: YouziPermissionKind) -> String {
    switch kind {
    case .connectorRead: "读取为这个定时任务选择的应用内容"
    case .connectorWrite: "在所选应用中创建或修改内容"
    case .externalPublish: "通过所选应用向外发送或发布内容"
    default: "使用为这个定时任务选择的应用能力"
    }
}

private func errorCopy(_ error: YouziAutomationCenterError?) -> String {
    switch error {
    case .invalidName: "请填写定时任务名称。"
    case .invalidRequest: "请填写要完成的任务。"
    case .invalidSchedule: "执行时间或时区无效，请检查后重试。"
    case .invalidPermissionSnapshot: "权限快照已经变化，请重新检查任务范围。"
    case .definitionChanged: "这项定时任务刚刚发生变化，请重新打开后确认。"
    case .permissionRequired: "需要重新确认长期权限后才能启用。"
    case .storageUnavailable: "Youzi 暂时无法保存，请确认数据目录可用后重试。"
    case .automationUnavailable: "这项定时任务已不存在或不可用。"
    case .alreadyRunning: "这项任务已经在运行。"
    case .runtimeUnavailable: "当前无法运行，请确认 Youzi 服务就绪后重试。"
    case .notificationUnavailable: "通知未开启；任务仍可运行，你可以在系统设置中开启通知。"
    case nil: "请重试。"
    }
}
