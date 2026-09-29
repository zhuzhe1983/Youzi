import SwiftUI

private enum YouziCapabilityCenterTab: String, CaseIterable, Identifiable {
    case helpers
    case skills
    case applications

    var id: String { rawValue }

    var title: String {
        switch self {
        case .helpers: "帮手"
        case .skills: "会做的事"
        case .applications: "已连接应用"
        }
    }

    var systemImage: String {
        switch self {
        case .helpers: "person.2"
        case .skills: "wand.and.stars"
        case .applications: "link"
        }
    }
}

/// Calm, product-language capability management for Simple Mode. It projects
/// the same durable graph and live MCP owners used by Professional Mode; no
/// card here creates a second registry or treats selection as permission.
struct YouziSimpleHelpersPage: View {
    @Environment(YouziProductModel.self) private var productModel
    @Environment(MCPConfigStore.self) private var mcpConfig
    @Environment(MCPCatalog.self) private var mcpCatalog
    @Environment(MCPToolRegistry.self) private var mcpTools
    @Environment(YouziMCPConnectedApplicationController.self) private var connectedApplications

    let onStartTask: (YouziHelper) -> Void
    let onOpenAdvancedConnectors: () -> Void

    @State private var tab: YouziCapabilityCenterTab = .helpers
    @State private var query = ""
    @State private var selectedID: UUID?
    @State private var applicationActionInFlight: UUID?
    @State private var applicationActionMessage: String?
    @State private var accountPendingForget: UUID?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                ScrollView {
                    content
                        .padding(RapidTheme.Space.xl)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if selectedID != nil {
                    Divider()
                    detail
                        .frame(width: 320)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .background(RapidTheme.surfaceCanvas)
        .animation(.easeInOut(duration: 0.18), value: selectedID)
        .onChange(of: tab) { _, _ in selectedID = nil }
        .task {
            await inspectConnectedApplications()
        }
        .confirmationDialog(
            "移除这个连接？",
            isPresented: Binding(
                get: { accountPendingForget != nil },
                set: { if !$0 { accountPendingForget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("移除连接与本地凭据", role: .destructive) {
                guard let accountID = accountPendingForget else { return }
                accountPendingForget = nil
                runApplicationAction(accountID: accountID) {
                    await connectedApplications.forget(accountID: accountID)
                }
            }
            Button("取消", role: .cancel) { accountPendingForget = nil }
        } message: {
            Text("如果仍有任务、项目或自动化在使用它，柚子会保留连接并告诉你先处理引用。")
        }
        .accessibilityIdentifier("YouziSimple.Surface.helpers")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: RapidTheme.Space.lg) {
            HStack(alignment: .center, spacing: RapidTheme.Space.lg) {
                VStack(alignment: .leading, spacing: RapidTheme.Space.xs) {
                    Text("帮手中心")
                        .font(RapidFont.pageTitle)
                    Text("选择谁来帮、需要什么能力，以及任务可以使用哪些应用。")
                        .font(RapidFont.body)
                        .foregroundStyle(RapidTheme.textSecondary)
                }
                Spacer(minLength: RapidTheme.Space.lg)
                HStack(spacing: RapidTheme.Space.sm) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(RapidTheme.textSecondary)
                    TextField("搜索", text: $query)
                        .textFieldStyle(.plain)
                        .frame(width: 190)
                        .accessibilityIdentifier("YouziSimple.Capabilities.Search")
                    if !query.isEmpty {
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(RapidTheme.textSecondary)
                        .accessibilityLabel("清除搜索")
                    }
                }
                .padding(.horizontal, RapidTheme.Space.md)
                .frame(height: 38)
                .background(
                    RoundedRectangle(cornerRadius: RapidTheme.Radius.input, style: .continuous)
                        .fill(RapidTheme.surfaceRaised)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: RapidTheme.Radius.input, style: .continuous)
                        .strokeBorder(RapidTheme.hairline, lineWidth: 1)
                )
            }

            HStack(spacing: RapidTheme.Space.xs) {
                ForEach(YouziCapabilityCenterTab.allCases) { item in
                    Button {
                        tab = item
                    } label: {
                        Label(item.title, systemImage: item.systemImage)
                            .font(tab == item ? RapidFont.bodyEmphasis : RapidFont.body)
                            .padding(.horizontal, RapidTheme.Space.md)
                            .frame(height: 36)
                            .background(
                                Capsule().fill(
                                    tab == item ? RapidTheme.selectionFill : Color.clear
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(RapidTheme.textPrimary)
                    .accessibilityAddTraits(tab == item ? .isSelected : [])
                    .accessibilityIdentifier("YouziSimple.Capabilities.Tab.\(item.rawValue)")
                }
            }
        }
        .padding(.horizontal, RapidTheme.Space.xl)
        .padding(.top, RapidTheme.Space.xl)
        .padding(.bottom, RapidTheme.Space.lg)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .helpers:
            helperGrid
        case .skills:
            skillGrid
        case .applications:
            applicationGrid
        }
    }

    private var helperGrid: some View {
        capabilityGrid(items: filteredHelpers) { helper in
            helperCard(helper)
        } empty: {
            emptyState(
                title: query.isEmpty ? "帮手正在准备" : "没有找到这个帮手",
                message: query.isEmpty
                    ? "你仍然可以从“新任务”直接开始，柚子会使用通用工作方式。"
                    : "试试更简短的名称或用途。",
                systemImage: "person.2"
            )
        }
    }

    private var skillGrid: some View {
        capabilityGrid(items: filteredSkills) { skill in
            skillCard(skill)
        } empty: {
            emptyState(
                title: query.isEmpty ? "还没有可用能力" : "没有找到这项能力",
                message: "可在专业模式中检查本地技能包，日常任务不会因此获得额外权限。",
                systemImage: "wand.and.stars"
            )
        }
    }

    private var applicationGrid: some View {
        let applications = filteredApplications
        return VStack(alignment: .leading, spacing: RapidTheme.Space.lg) {
            if applications.isEmpty {
                emptyState(
                    title: query.isEmpty ? "还没有已连接应用" : "没有找到这个应用",
                    message: "连接本地或自定义 MCP 后，它会在这里显示真实状态和可用能力。",
                    systemImage: "link.badge.plus",
                    actionTitle: "管理连接器",
                    action: onOpenAdvancedConnectors
                )
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 250), spacing: RapidTheme.Space.md)],
                    spacing: RapidTheme.Space.md
                ) {
                    ForEach(applications) { application in
                        applicationCard(application)
                    }
                }
                Button("管理连接器…", action: onOpenAdvancedConnectors)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("YouziSimple.Capabilities.ManageConnectors")
            }
        }
    }

    private func capabilityGrid<Item: Identifiable, Card: View, Empty: View>(
        items: [Item],
        @ViewBuilder card: @escaping (Item) -> Card,
        @ViewBuilder empty: () -> Empty
    ) -> some View {
        Group {
            if items.isEmpty {
                empty()
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 250), spacing: RapidTheme.Space.md)],
                    spacing: RapidTheme.Space.md
                ) {
                    ForEach(items) { item in card(item) }
                }
            }
        }
    }

    private func helperCard(_ helper: YouziHelper) -> some View {
        VStack(alignment: .leading, spacing: RapidTheme.Space.md) {
            HStack(alignment: .top) {
                YouziLogo(size: 40)
                Spacer(minLength: 0)
                Button {
                    productModel.setHelperFavorite(
                        id: helper.id,
                        favorite: !helper.isFavorite
                    )
                } label: {
                    Image(systemName: helper.isFavorite ? "heart.fill" : "heart")
                }
                .buttonStyle(.plain)
                .foregroundStyle(helper.isFavorite ? RapidTheme.brandPrimary : RapidTheme.textSecondary)
                .accessibilityLabel(helper.isFavorite ? "取消收藏" : "收藏")
            }
            VStack(alignment: .leading, spacing: RapidTheme.Space.xs) {
                Text(helper.name)
                    .font(RapidFont.sectionTitle)
                Text(helper.summary)
                    .font(RapidFont.secondary)
                    .foregroundStyle(RapidTheme.textSecondary)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
            HStack {
                Button("了解") { selectedID = helper.id }
                    .buttonStyle(.bordered)
                Spacer(minLength: 0)
                Button("开始任务") { onStartTask(helper) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(RapidTheme.Space.lg)
        .frame(minHeight: 210, alignment: .top)
        .capabilityCenterCard(isSelected: selectedID == helper.id)
        .accessibilityIdentifier("YouziSimple.Helper.\(helper.id.uuidString)")
    }

    private func skillCard(_ skill: YouziSkill) -> some View {
        let isUsable = skill.state == .active && package(for: skill)?.recoveryCode == nil
        return VStack(alignment: .leading, spacing: RapidTheme.Space.md) {
            HStack {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(RapidTheme.brandPrimary)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(RapidTheme.selectionFill))
                Spacer(minLength: 0)
                statusPill(isUsable ? "可用" : "需要处理", positive: isUsable)
            }
            VStack(alignment: .leading, spacing: RapidTheme.Space.xs) {
                Text(skill.name)
                    .font(RapidFont.sectionTitle)
                Text(skill.summary)
                    .font(RapidFont.secondary)
                    .foregroundStyle(RapidTheme.textSecondary)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
            HStack {
                Button("查看") { selectedID = skill.id }
                    .buttonStyle(.bordered)
                Spacer(minLength: 0)
                Button(skill.state == .active ? "停用" : "启用") {
                    productModel.setSkillState(
                        id: skill.id,
                        state: skill.state == .active ? .disabled : .active
                    )
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(RapidTheme.Space.lg)
        .frame(minHeight: 210, alignment: .top)
        .capabilityCenterCard(isSelected: selectedID == skill.id)
        .accessibilityIdentifier("YouziSimple.Skill.\(skill.id.uuidString)")
    }

    private func applicationCard(
        _ application: YouziConnectedApplicationCapability
    ) -> some View {
        VStack(alignment: .leading, spacing: RapidTheme.Space.md) {
            HStack {
                Image(systemName: "app.connected.to.app.below.fill")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(RapidTheme.brandPrimary)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(RapidTheme.selectionFill))
                Spacer(minLength: 0)
                statusPill(
                    application.status.displayName,
                    positive: application.status == .live
                )
            }
            VStack(alignment: .leading, spacing: RapidTheme.Space.xs) {
                Text(application.accountDisplayName ?? application.connectorName ?? "连接应用")
                    .font(RapidFont.sectionTitle)
                Text(application.summaryText)
                    .font(RapidFont.secondary)
                    .foregroundStyle(RapidTheme.textSecondary)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
            Button("查看状态") { selectedID = application.id }
                .buttonStyle(.bordered)
        }
        .padding(RapidTheme.Space.lg)
        .frame(minHeight: 210, alignment: .top)
        .capabilityCenterCard(isSelected: selectedID == application.id)
        .accessibilityIdentifier("YouziSimple.Application.\(application.id.uuidString)")
    }

    @ViewBuilder
    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RapidTheme.Space.lg) {
                HStack {
                    Text("详情")
                        .font(RapidFont.sectionTitle)
                    Spacer(minLength: 0)
                    Button { selectedID = nil } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭详情")
                }
                Divider()
                switch tab {
                case .helpers:
                    if let helper = selectedHelper { helperDetail(helper) }
                case .skills:
                    if let skill = selectedSkill { skillDetail(skill) }
                case .applications:
                    if let application = selectedApplication {
                        applicationDetail(application)
                    }
                }
            }
            .padding(RapidTheme.Space.xl)
        }
        .background(RapidTheme.surfaceRaised)
        .accessibilityIdentifier("YouziSimple.Capabilities.Detail")
    }

    private func helperDetail(_ helper: YouziHelper) -> some View {
        VStack(alignment: .leading, spacing: RapidTheme.Space.lg) {
            detailTitle(helper.name, subtitle: helper.summary, systemImage: "person.crop.circle")
            detailSection("会怎么帮") {
                ForEach(Array(helper.methodology.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: RapidTheme.Space.sm) {
                        Text("\(index + 1)")
                            .font(RapidFont.caption)
                            .foregroundStyle(RapidTheme.brandPrimary)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(RapidTheme.selectionFill))
                        Text(step).font(RapidFont.secondary)
                    }
                }
            }
            let recommended = productModel.skills.filter {
                helper.recommendedSkillIDs.contains($0.id)
            }
            if !recommended.isEmpty {
                detailSection("可能会用到") {
                    YouziCapabilityFlowLayout(spacing: RapidTheme.Space.xs) {
                        ForEach(recommended) { skill in
                            Text(skill.name).capabilityTag()
                        }
                    }
                }
            }
            Button("用这个帮手开始任务") { onStartTask(helper) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }

    private func skillDetail(_ skill: YouziSkill) -> some View {
        VStack(alignment: .leading, spacing: RapidTheme.Space.lg) {
            detailTitle(skill.name, subtitle: skill.summary, systemImage: "wand.and.stars")
            detailSection("运行位置") {
                Text(skill.executionLocation.displayName)
                    .font(RapidFont.secondary)
            }
            if !skill.requestedPermissions.isEmpty {
                detailSection("需要确认") {
                    YouziCapabilityFlowLayout(spacing: RapidTheme.Space.xs) {
                        ForEach(skill.requestedPermissions, id: \.rawValue) { permission in
                            Text(permission.displayName).capabilityTag()
                        }
                    }
                    Text("这是能力声明，不代表已经获得权限；实际使用时仍会按任务确认。")
                        .font(RapidFont.caption)
                        .foregroundStyle(RapidTheme.textSecondary)
                }
            }
            Text("版本 \(skill.packageVersion) · \(skill.source.kind.displayName)")
                .font(RapidFont.caption)
                .foregroundStyle(RapidTheme.textSecondary)
        }
    }

    private func applicationDetail(
        _ application: YouziConnectedApplicationCapability
    ) -> some View {
        VStack(alignment: .leading, spacing: RapidTheme.Space.lg) {
            detailTitle(
                application.accountDisplayName ?? application.connectorName ?? "连接应用",
                subtitle: application.status.displayName,
                systemImage: "link"
            )
            detailSection("当前可用于任务") {
                if application.candidateToolNames.isEmpty {
                    Text("暂时没有可调用能力。")
                        .font(RapidFont.secondary)
                        .foregroundStyle(RapidTheme.textSecondary)
                } else {
                    ForEach(application.candidateToolNames, id: \.self) { tool in
                        Label(tool, systemImage: "checkmark.circle.fill")
                            .font(RapidFont.secondary)
                            .foregroundStyle(RapidTheme.textPrimary)
                    }
                }
            }
            if !application.issues.isEmpty {
                Label("有 \(application.issues.count) 项需要处理", systemImage: "exclamationmark.circle")
                    .font(RapidFont.secondary)
                    .foregroundStyle(RapidTheme.textSecondary)
            }
            if let message = applicationActionMessage {
                Text(message)
                    .font(RapidFont.caption)
                    .foregroundStyle(RapidTheme.textSecondary)
                    .accessibilityIdentifier("YouziSimple.Application.ActionResult")
            }
            if let accountID = application.connectionAccountID {
                HStack(spacing: RapidTheme.Space.sm) {
                    Button(application.status == .disabled ? "恢复" : "暂停") {
                        runApplicationAction(accountID: accountID) {
                            if application.status == .disabled {
                                return await connectedApplications.resume(accountID: accountID)
                            }
                            return await connectedApplications.pause(accountID: accountID)
                        }
                    }
                    .buttonStyle(.bordered)

                    Button("断开") {
                        runApplicationAction(accountID: accountID) {
                            connectedApplications.disconnect(accountID: accountID)
                        }
                    }
                    .buttonStyle(.bordered)

                    Button("移除", role: .destructive) {
                        accountPendingForget = accountID
                    }
                    .buttonStyle(.borderless)
                }
                .disabled(applicationActionInFlight != nil)
            }
            Button("在专业模式中管理", action: onOpenAdvancedConnectors)
                .buttonStyle(.bordered)
        }
    }

    @MainActor
    private func inspectConnectedApplications() async {
        guard applicationActionInFlight == nil else { return }
        applicationActionInFlight = UUID()
        let result = await connectedApplications.inspect()
        productModel.refresh()
        applicationActionMessage = result.userFacingMessage
        applicationActionInFlight = nil
    }

    private func runApplicationAction(
        accountID: UUID,
        operation: @escaping @MainActor () async -> YouziMCPConnectedApplicationActionResult
    ) {
        guard applicationActionInFlight == nil else { return }
        applicationActionInFlight = accountID
        Task { @MainActor in
            let result = await operation()
            productModel.refresh()
            applicationActionMessage = result.userFacingMessage
            applicationActionInFlight = nil
        }
    }

    private func detailTitle(_ title: String, subtitle: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: RapidTheme.Space.sm) {
            Image(systemName: systemImage)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(RapidTheme.brandPrimary)
            Text(title).font(RapidFont.sectionTitle)
            Text(subtitle)
                .font(RapidFont.secondary)
                .foregroundStyle(RapidTheme.textSecondary)
        }
    }

    private func detailSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: RapidTheme.Space.sm) {
            Text(title)
                .font(RapidFont.groupLabel)
                .foregroundStyle(RapidTheme.textSecondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func emptyState(
        title: String,
        message: String,
        systemImage: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: RapidTheme.Space.md) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(RapidTheme.brandPrimary)
            Text(title).font(RapidFont.sectionTitle)
            Text(message)
                .font(RapidFont.secondary)
                .foregroundStyle(RapidTheme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.borderedProminent)
            }
        }
        .padding(RapidTheme.Space.xxl)
        .frame(maxWidth: .infinity, minHeight: 300)
        .capabilityCenterCard(isSelected: false)
    }

    private func statusPill(_ text: String, positive: Bool) -> some View {
        Text(text)
            .font(RapidFont.caption)
            .foregroundStyle(positive ? RapidTheme.brandPrimary : RapidTheme.textSecondary)
            .padding(.horizontal, RapidTheme.Space.sm)
            .frame(height: 24)
            .background(Capsule().fill(positive ? RapidTheme.selectionFill : RapidTheme.surfaceCanvas))
    }

    private var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredHelpers: [YouziHelper] {
        productModel.helpers
            .filter { $0.state != .archived }
            .filter { matches([$0.name, $0.summary]) }
            .sorted { ($0.isFavorite ? 0 : 1, $0.name) < ($1.isFavorite ? 0 : 1, $1.name) }
    }

    private var filteredSkills: [YouziSkill] {
        productModel.skills
            .filter { $0.state != .archived }
            .filter { matches([$0.name, $0.summary]) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var connectorProjection: YouziConnectorCapabilityProjection {
        YouziConnectorCapabilityFacade().project(
            document: productModel.document,
            runtime: .capture(
                configStore: mcpConfig,
                catalog: mcpCatalog,
                registry: mcpTools
            )
        )
    }

    private var filteredApplications: [YouziConnectedApplicationCapability] {
        connectorProjection.applications.filter {
            matches([$0.connectorName ?? "", $0.accountDisplayName ?? ""])
        }
    }

    private var selectedHelper: YouziHelper? {
        selectedID.flatMap(productModel.helper(id:))
    }

    private var selectedSkill: YouziSkill? {
        selectedID.flatMap(productModel.skill(id:))
    }

    private var selectedApplication: YouziConnectedApplicationCapability? {
        guard let selectedID else { return nil }
        return connectorProjection.applications.first { $0.id == selectedID }
    }

    private func package(for skill: YouziSkill) -> YouziSkillPackageRecord? {
        productModel.skillPackages.first { $0.id == skill.id }
    }

    private func matches(_ values: [String]) -> Bool {
        guard !normalizedQuery.isEmpty else { return true }
        return values.contains { value in
            value.localizedCaseInsensitiveContains(normalizedQuery)
        }
    }
}

private extension View {
    func capabilityCenterCard(isSelected: Bool) -> some View {
        background(
            RoundedRectangle(cornerRadius: RapidTheme.Radius.card, style: .continuous)
                .fill(RapidTheme.surfaceRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RapidTheme.Radius.card, style: .continuous)
                .strokeBorder(
                    isSelected ? RapidTheme.brandPrimary.opacity(0.7) : RapidTheme.hairline,
                    lineWidth: isSelected ? 1.5 : 1
                )
        )
    }

    func capabilityTag() -> some View {
        font(RapidFont.caption)
            .foregroundStyle(RapidTheme.textSecondary)
            .padding(.horizontal, RapidTheme.Space.sm)
            .frame(height: 26)
            .background(Capsule().fill(RapidTheme.surfaceCanvas))
    }
}

private extension YouziConnectedApplicationCapability {
    var summaryText: String {
        if !candidateToolNames.isEmpty {
            return "当前有 \(candidateToolNames.count) 项能力可供任务选择。"
        }
        switch status {
        case .definition: return "可以连接后供任务使用。"
        case .configured, .authorized: return "配置已保存，正在等待运行时连接。"
        case .live: return "已经连接，暂时没有已启用能力。"
        case .disabled: return "当前已停用，不会出现在任务中。"
        case .unavailable: return "当前无法使用，可以检查连接状态。"
        case .error: return "连接信息需要在专业模式中处理。"
        }
    }
}

private extension YouziConnectedApplicationStatus {
    var displayName: String {
        switch self {
        case .definition: "未连接"
        case .configured: "已配置"
        case .authorized: "已授权"
        case .live: "已连接"
        case .disabled: "已停用"
        case .unavailable: "暂不可用"
        case .error: "需要处理"
        }
    }
}

private extension YouziMCPConnectedApplicationActionResult {
    var userFacingMessage: String? {
        switch outcome {
        case .completed:
            switch action {
            case .inspect: return issues.isEmpty ? nil : "连接状态已更新，有 \(issues.count) 项需要处理。"
            case .createOrImport: return "应用已加入柚子。"
            case .pause: return "应用已暂停，不会再被任务调用。"
            case .resume: return "应用已恢复，可以在任务中选择。"
            case .update: return "连接设置已更新。"
            case .disconnect: return "应用已断开。"
            case .forget: return "连接与本地凭据已移除。"
            }
        case .needsAttention:
            return "连接状态已更新，但仍有 \(issues.count) 项需要处理。"
        case .failed:
            switch failure {
            case .accountStillReferenced:
                return "这个连接仍被任务、项目或自动化使用，请先移除这些引用。"
            case .credentialCleanupFailed:
                return "连接已停用，但本地凭据尚未清理，请重试。"
            case .invalidMCPBinding:
                return "连接配置不完整，请在专业模式中检查。"
            case .operationalWriteFailed:
                return "无法更新 MCP 配置，请在专业模式中检查。"
            case .domainWriteFailed:
                return "连接状态未能安全保存，请重试。"
            case .accountNotFound:
                return "这个连接已经不存在，列表已刷新。"
            case .none:
                return "操作没有完成，请重试。"
            }
        }
    }
}

private extension YouziSkillExecutionLocation {
    var displayName: String {
        switch self {
        case .local: "仅在本机"
        case .network: "使用网络"
        case .hybrid: "本机与网络"
        }
    }
}

private extension YouziPermissionKind {
    var displayName: String {
        switch self {
        case .workspaceRead: "读取工作资料"
        case .workspaceWrite: "修改工作资料"
        case .networkAccess: "访问网络"
        case .connectorRead: "读取连接应用"
        case .connectorWrite: "修改连接应用"
        case .externalPublish: "向外发布"
        case .destructiveLocalAction: "高风险本地操作"
        case .microphone: "使用麦克风"
        case .saveAudio: "保存音频"
        }
    }
}

private extension YouziManifestSourceKind {
    var displayName: String {
        switch self {
        case .builtIn: "Youzi 内置"
        case .userCreated: "个人创建"
        case .localPackage: "本地技能包"
        case .managedCatalog: "受管理目录"
        }
    }
}

/// Wrapping layout for short capability labels. Keeping it local avoids
/// coupling Simple Mode to the private Dictation chip layout.
private struct YouziCapabilityFlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maximumWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var measuredWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maximumWidth, x > 0 {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            measuredWidth = max(measuredWidth, min(x + size.width, maximumWidth))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: measuredWidth, height: y + lineHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
