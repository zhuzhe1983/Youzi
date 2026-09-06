import SwiftUI

/// Security controls bind to the same live gates used by tool execution. This
/// page intentionally does not imply an OS sandbox or backup engine exists.
struct SettingsSecurityPanel: View {
    @Environment(BrowseApprovalStore.self) private var browse
    @Environment(MCPToolApprovalStore.self) private var mcp
    @Environment(MCPConfigStore.self) private var config
    @Environment(YouziProductModel.self) private var product
    @Environment(SettingsRouter.self) private var router
    @Environment(YouziI18nConfig.self) private var i18n
    @State private var relaxing: Gate?
    @State private var resettingGrants = false
    @AppStorage(BrowseNetworkPreference.proxyCompatibilityKey) private var proxyCompatibility = true
    enum Gate { case browsing, connectors }

    var body: some View {
        VStack(alignment: .leading, spacing: RapidTheme.Space.lg) {
            SectionHeader(t("安全中心", "Security Center"),
                          subtitle: t("管理真实的工具访问审批。更改立即生效，不会中断已经开始的操作。", "Manage live tool approval gates. Changes apply immediately, not retroactively to running operations."),
                          emphasis: .page)
                .accessibilityIdentifier("Settings.Security.Panel")
            SettingsSection(t("网络安全", "Network Safety")) {
                Toggle(isOn: Binding(get: { browse.mode == .ask }, set: {
                    if $0 { browse.mode = .ask } else { relaxing = .browsing }
                })) {
                    SettingsRowLabel(title: t("浏览网页前询问", "Ask Before Browsing"),
                                     description: t("展示模型请求的完整 URL，由你决定是否访问。此项约束内置浏览工具，不是全局网络防火墙。", "Review the complete URL requested by the model. Controls the built-in browse tool, not all app or connector traffic."))
                }
                .toggleStyle(TrailingSettingsToggleStyle())
                .accessibilityIdentifier("Settings.Security.BrowseApproval")
                SettingsRowDivider()
                Toggle(isOn: $proxyCompatibility) {
                    SettingsRowLabel(title: t("兼容本机代理（Fake-IP）", "Local Proxy Compatibility (Fake-IP)"),
                                     description: t("默认开启。允许公共域名使用代理分配的 Fake-IP；仍拦截明确的本机、私网地址。仅信任你自己的代理，实际目标由代理决定；关闭可恢复严格 DNS 检查。", "On by default. Allows proxy-assigned Fake-IP for public names, not explicit local/private targets. Trust only your own proxy: it controls the real destination. Turn off for strict DNS checks."))
                }
                .toggleStyle(TrailingSettingsToggleStyle())
                .accessibilityIdentifier("Settings.Security.ProxyCompatibility")
                SettingsRowDivider()
                SettingsRowLabel(title: t("网络边界", "Network Boundaries"),
                                 description: t("内置浏览工具检查目标地址；代理兼容模式的实际转发由代理负责。网页搜索会将查询发送给配置的搜索服务。MCP 服务可能有独立网络能力。", "The built-in browse tool checks destination addresses; in compatibility mode, the proxy controls actual forwarding. Web search sends queries to your configured provider. MCP services may access the network independently."))
            }
            SettingsSection(t("连接器与命令安全", "Connector & Command Safety")) {
                Toggle(isOn: Binding(get: { mcp.mode == .ask }, set: {
                    if $0 { mcp.mode = .ask } else { relaxing = .connectors }
                })) {
                    SettingsRowLabel(title: t("未授权工具调用前询问", "Ask for Unapproved Tools"),
                                     description: t("已记住的「始终允许」仍有效，可在下方撤销。关闭后将自动批准所有 MCP 工具调用。", "Remembered Always Allow grants still apply; revoke them below. Turning this off automatically approves all MCP tool calls."))
                }
                .toggleStyle(TrailingSettingsToggleStyle())
                .accessibilityIdentifier("Settings.Security.MCPApproval")
                SettingsRowDivider()
                HStack {
                    SettingsRowLabel(title: t("配置的连接器 · \(config.servers.count)", "Configured Connectors · \(config.servers.count)"),
                                     description: t("本地 MCP 程序以当前用户权限运行。工具审批不等于进程隔离；只运行可信的连接器。", "Local MCP programs run with your user permissions. Tool approval is not process isolation; only run trusted connectors."))
                    Button(t("管理", "Manage")) { router.requestedCategory = .connectors }
                        .buttonStyle(.rapidSecondaryCompact)
                        .accessibilityIdentifier("SettingsSecurityPanel.Button.3953e09426")
                }
            }
            SettingsSection(t("已记住的授权 · \(mcp.grantedTools.count)", "Remembered Grants · \(mcp.grantedTools.count)")) {
                if mcp.mode == .autoApproveAll {
                    Text(t("自动批准已开启：撤销单项授权不会阻止调用。请先开启上方的询问开关。", "Auto-approval is on: revoking an individual grant does not block calls. Enable the approval switch above first."))
                        .font(RapidFont.secondary).foregroundStyle(RapidTheme.statusWarning)
                        .padding(.vertical, RapidTheme.Space.sm)
                }
                if mcp.grantedTools.isEmpty {
                    Text(t("暂无已记住的授权", "No remembered grants"))
                        .font(RapidFont.secondary).foregroundStyle(RapidTheme.textSecondary)
                        .padding(.vertical, RapidTheme.Space.sm)
                } else {
                    ForEach(mcp.grantedTools.sorted(), id: \.self) { tool in
                        HStack {
                            Text(tool).font(RapidFont.body).lineLimit(2).textSelection(.enabled)
                            Spacer(minLength: 0)
                            Button(t("撤销", "Revoke")) { mcp.revokeGrant(forTool: tool) }
                                .buttonStyle(.rapidSecondaryCompact)
                                .accessibilityIdentifier("SettingsSecurityPanel.Button.a757c3ef39")
                        }.padding(.vertical, RapidTheme.Space.sm)
                    }
                    Button(t("撤销全部并恢复逐次审批", "Revoke All and Require Approval")) { resettingGrants = true }
                        .buttonStyle(.rapidSecondaryCompact).padding(.vertical, RapidTheme.Space.sm)
                        .accessibilityIdentifier("SettingsSecurityPanel.Button.018b4f13e6")
                }
            }
            SettingsSection(t("文件安全", "File Safety")) {
                SettingsRowLabel(title: t("工作空间 · \(product.workspaces.count)", "Workspaces · \(product.workspaces.count)"),
                                 description: t("Youzi 管理的文件访问使用工作空间授权与受控路径检查。此保护不覆盖外部 MCP 进程的任意读写，也不是全局文件白名单。", "Youzi-managed file access uses workspace authorization and scoped path checks. This does not constrain arbitrary reads or writes by external MCP processes, and is not a global file allowlist."))
                DisclosureGroup(t("查看工作空间", "View Workspaces")) {
                    ForEach(product.workspaces) { workspace in
                        Text(workspace.name).font(RapidFont.body)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, RapidTheme.Space.xs)
                    }
                }.font(RapidFont.body).padding(.top, RapidTheme.Space.sm)
                    .accessibilityIdentifier("SettingsSecurityPanel.DisclosureGroup.2be1b5be49")
            }
            SettingsSection(t("数据安全", "Data Safety")) {
                SettingsRowLabel(title: t("分享与数据流转", "Sharing & Data Transfers"),
                                 description: t("只有主动选择 macOS 分享服务才会发送副本。删除本地分享记录不会撤回已交付内容。使用远程模型、搜索或连接器时，相关数据可能离开本机。", "Copies are sent only when you choose a macOS sharing service. Removing history does not recall delivered content. Remote models, search, and connectors may send relevant data off this Mac."))
                SettingsRowDivider()
                SettingsRowLabel(title: t("沙箱与自动备份：尚未提供", "Process Sandbox & Automatic Backups: Not Available"),
                                 description: t("当前没有覆盖所有 AI 操作的隔离沙箱、命令前缀规则或文件修改前自动备份。请不要将工具审批当作这些保护；重要文件仍需自行备份。", "There is no all-agent process sandbox, command-prefix policy, or automatic pre-edit file backup. Tool approvals are not a substitute; keep independent backups of important files."))
            }
        }
        .alert(t("允许自动批准？", "Allow Automatic Approval?"),
               isPresented: Binding(get: { relaxing != nil }, set: { if !$0 { relaxing = nil } })) {
            Button(t("保持询问", "Keep Asking"), role: .cancel) { relaxing = nil }
                .accessibilityIdentifier("SettingsSecurityPanel.Button.16cbfc4c55")
            Button(t("允许自动批准", "Allow Automatic Approval"), role: .destructive) {
                switch relaxing {
                case .browsing: browse.mode = .autoApproveAll
                case .connectors: mcp.mode = .autoApproveAll
                case nil: break
                }
                relaxing = nil
            }
                .accessibilityIdentifier("SettingsSecurityPanel.Button.a3d941c8e1")
        } message: {
            Text(t("模型后续操作将不再逐次请求你的确认，可能向外部发送数据或通过连接器读写文件。", "Future operations may send data externally or read/write files through connectors without individual confirmation."))
        }
        .alert(t("撤销全部授权？", "Revoke All Grants?"), isPresented: $resettingGrants) {
            Button(t("取消", "Cancel"), role: .cancel) {}
                .accessibilityIdentifier("SettingsSecurityPanel.Button.3fbd0a8e92")
            Button(t("撤销并恢复审批", "Revoke and Require Approval"), role: .destructive) {
                mcp.mode = .ask
                mcp.resetGrants()
                browse.mode = .ask
            }
                .accessibilityIdentifier("SettingsSecurityPanel.Button.3ef2d6b7d9")
        } message: {
            Text(t("后续浏览与 MCP 工具调用会重新询问。不会终止已经开始的操作。", "Future browse and MCP calls will ask again. Already running operations are not terminated."))
        }

    }

    private func t(_ zh: String, _ en: String) -> String { i18n.text(zh: zh, en: en) }
}
