import Foundation

// MARK: - Sanitized operational snapshot

/// A non-secret point-in-time projection of the existing MCP owners.
///
/// This is not a registry and cannot execute or persist anything. It carries
/// only the identity and availability facts needed to join a stable Youzi
/// account binding to the real MCP configuration, catalog, and enablement
/// switches. Command arguments, environment values, URLs, credentials, tool
/// descriptions, response bodies, and raw errors are deliberately absent.
struct YouziMCPRuntimeSnapshot: Sendable, Equatable {
    enum ConfigurationState: String, Sendable, Equatable {
        case readable
        case unreadable
    }

    enum CatalogState: String, Sendable, Equatable {
        case notConfigured
        case ready
        case unavailable
        case failed
    }

    struct ConfiguredServer: Sendable, Equatable {
        let name: String
        let isEnabled: Bool

        init(name: String, isEnabled: Bool = true) {
            self.name = name
            self.isEnabled = isEnabled
        }
    }

    struct LiveServer: Sendable, Equatable {
        enum State: String, Sendable, Equatable {
            case connected
            case disconnected
            case failed
            case unknown
        }

        let name: String
        let state: State
    }

    struct Tool: Sendable, Equatable {
        let name: String
        /// Nil means the operational catalog did not provide an authoritative
        /// server mapping. Such a tool can never be attributed to an account.
        let serverName: String?
        let isEnabled: Bool

        init(name: String, serverName: String?, isEnabled: Bool = true) {
            self.name = name
            self.serverName = serverName
            self.isEnabled = isEnabled
        }
    }

    let connectorsEnabled: Bool
    let configurationState: ConfigurationState
    let configuredServers: [ConfiguredServer]
    let catalogState: CatalogState
    let liveServers: [LiveServer]
    let tools: [Tool]

    init(
        connectorsEnabled: Bool,
        configurationState: ConfigurationState = .readable,
        configuredServers: [ConfiguredServer] = [],
        catalogState: CatalogState = .notConfigured,
        liveServers: [LiveServer] = [],
        tools: [Tool] = []
    ) {
        self.connectorsEnabled = connectorsEnabled
        self.configurationState = configurationState
        self.configuredServers = configuredServers
        self.catalogState = catalogState
        self.liveServers = liveServers
        self.tools = tools
    }

    /// Capture the current real MCP operational owners without retaining them
    /// or copying their secret-bearing configuration into product state.
    @MainActor
    static func capture(
        configStore: MCPConfigStore,
        catalog: MCPCatalog,
        registry: MCPToolRegistry
    ) -> YouziMCPRuntimeSnapshot {
        let catalogState: CatalogState
        if catalog.fetchError != nil {
            catalogState = .unavailable
        } else if catalog.subsystemError != nil {
            catalogState = .failed
        } else if catalog.isConfigured {
            catalogState = .ready
        } else {
            catalogState = .notConfigured
        }

        return YouziMCPRuntimeSnapshot(
            connectorsEnabled: configStore.isEnabled,
            configurationState: configStore.loadError == nil ? .readable : .unreadable,
            configuredServers: configStore.servers.map {
                ConfiguredServer(name: $0.name, isEnabled: $0.enabled)
            },
            catalogState: catalogState,
            liveServers: catalog.servers.map {
                LiveServer(name: $0.name, state: sanitizedServerState($0.state))
            },
            tools: catalog.tools.map {
                let name = $0.function.name
                return Tool(
                    name: name,
                    serverName: catalog.serverForTool[name],
                    isEnabled: registry.isToolEnabled(name)
                )
            }
        )
    }

    private static func sanitizedServerState(_ rawValue: String) -> LiveServer.State {
        switch rawValue.lowercased() {
        case "connected": return .connected
        case "disconnected": return .disconnected
        case "error", "failed": return .failed
        default: return .unknown
        }
    }
}

// MARK: - Domain-facing projection

enum YouziConnectedApplicationStatus: String, Sendable, Equatable {
    /// A connector definition exists, but there is no configured account.
    case definition
    /// The exact bound server exists, but the account is not connected.
    case configured
    /// The domain account association is connected, but the engine has not
    /// loaded MCP. This is not tool-execution permission.
    case authorized
    /// The exact bound server is connected in the live catalog.
    case live
    /// A domain or existing MCP enable switch is off.
    case disabled
    /// The binding/runtime is absent or cannot currently be checked.
    case unavailable
    /// Persisted or runtime identity is inconsistent or explicitly failed.
    case error
}

enum YouziConnectedApplicationToolStatus: String, Sendable, Equatable {
    case candidate
    case disabled
    case undeclared
    case unavailable
}

struct YouziConnectedApplicationTool: Sendable, Equatable {
    let name: String
    let status: YouziConnectedApplicationToolStatus
}

enum YouziConnectorCapabilityRecordKind: String, Sendable, Equatable {
    case connector
    case connectionAccount
    case connectorBinding
}

enum YouziConnectorCapabilityRecovery: Sendable, Equatable {
    case repairDomainRecords(kind: YouziConnectorCapabilityRecordKind, id: UUID)
    case connectAccount(id: UUID)
    case resumeAccount(id: UUID)
    case reconcileBinding(accountID: UUID)
    case enableConnector(id: UUID)
    case enableConnectors
    case enableServer(name: String)
    case refreshRuntime
    case openAdvancedConnectorSettings
    case enableTool(name: String)
}

/// Sanitized, deterministic diagnostics. No case carries a raw runtime error,
/// response body, environment value, command argument, URL, or credential.
enum YouziConnectorCapabilityIssue: Sendable, Equatable {
    case duplicateRecord(kind: YouziConnectorCapabilityRecordKind, id: UUID)
    case orphanBinding(accountID: UUID)
    case missingConnector(accountID: UUID, connectorID: UUID)
    case inactiveConnector(connectorID: UUID, state: YouziRecordState)
    case accountNotConnected(accountID: UUID, state: YouziConnectionState)
    case accountNeedsAttention(accountID: UUID)
    case missingBinding(accountID: UUID)
    case invalidBinding(accountID: UUID)
    case mismatchedRuntimeBinding(accountID: UUID, connectorID: UUID)
    case staleMCPBinding(accountID: UUID, serverName: String)
    case connectorsDisabled
    case configurationUnreadable
    case duplicateConfiguredServer(name: String)
    case configuredServerDisabled(name: String)
    case runtimeNotConfigured
    case runtimeUnavailable
    case runtimeFailed
    case duplicateLiveServer(name: String)
    case liveServerUnavailable(name: String)
    case liveServerFailed(name: String)
    case unmappedRuntimeTool(name: String)
    case duplicateRuntimeTool(serverName: String, toolName: String)
    case duplicateConnectorToolDeclaration(connectorID: UUID, toolName: String)
    case undeclaredRuntimeTool(connectorID: UUID, toolName: String)
    case declaredToolUnavailable(connectorID: UUID, toolName: String)
    case toolDisabled(toolName: String)

    var recovery: YouziConnectorCapabilityRecovery {
        switch self {
        case .duplicateRecord(let kind, let id):
            return .repairDomainRecords(kind: kind, id: id)
        case .orphanBinding(let accountID),
             .missingBinding(let accountID),
             .invalidBinding(let accountID),
             .staleMCPBinding(let accountID, _):
            return .reconcileBinding(accountID: accountID)
        case .missingConnector(let accountID, _):
            return .repairDomainRecords(kind: .connectionAccount, id: accountID)
        case .inactiveConnector(let connectorID, _):
            return .enableConnector(id: connectorID)
        case .accountNotConnected(let accountID, let state):
            return state == .disabled
                ? .resumeAccount(id: accountID)
                : .connectAccount(id: accountID)
        case .accountNeedsAttention(let accountID):
            return .connectAccount(id: accountID)
        case .mismatchedRuntimeBinding:
            return .openAdvancedConnectorSettings
        case .connectorsDisabled:
            return .enableConnectors
        case .configurationUnreadable,
             .runtimeNotConfigured,
             .runtimeUnavailable,
             .runtimeFailed,
             .duplicateLiveServer,
             .liveServerUnavailable,
             .liveServerFailed:
            return .refreshRuntime
        case .duplicateConfiguredServer:
            return .openAdvancedConnectorSettings
        case .configuredServerDisabled(let name):
            return .enableServer(name: name)
        case .unmappedRuntimeTool,
             .duplicateRuntimeTool,
             .duplicateConnectorToolDeclaration,
             .undeclaredRuntimeTool,
             .declaredToolUnavailable:
            return .openAdvancedConnectorSettings
        case .toolDisabled(let name):
            return .enableTool(name: name)
        }
    }

    fileprivate var sortKey: String {
        func key(_ id: UUID) -> String { id.uuidString.lowercased() }
        switch self {
        case .duplicateRecord(let kind, let id):
            return "01|\(kind.rawValue)|\(key(id))"
        case .orphanBinding(let accountID):
            return "02|\(key(accountID))"
        case .missingConnector(let accountID, let connectorID):
            return "03|\(key(accountID))|\(key(connectorID))"
        case .inactiveConnector(let connectorID, let state):
            return "04|\(key(connectorID))|\(state.rawValue)"
        case .accountNotConnected(let accountID, let state):
            return "05|\(key(accountID))|\(state.rawValue)"
        case .accountNeedsAttention(let accountID):
            return "06|\(key(accountID))"
        case .missingBinding(let accountID):
            return "07|\(key(accountID))"
        case .invalidBinding(let accountID):
            return "08|\(key(accountID))"
        case .mismatchedRuntimeBinding(let accountID, let connectorID):
            return "09|\(key(accountID))|\(key(connectorID))"
        case .staleMCPBinding(let accountID, let serverName):
            return "10|\(key(accountID))|\(serverName)"
        case .connectorsDisabled:
            return "11"
        case .configurationUnreadable:
            return "12"
        case .duplicateConfiguredServer(let name):
            return "13|\(name)"
        case .configuredServerDisabled(let name):
            return "14|\(name)"
        case .runtimeNotConfigured:
            return "15"
        case .runtimeUnavailable:
            return "16"
        case .runtimeFailed:
            return "17"
        case .duplicateLiveServer(let name):
            return "18|\(name)"
        case .liveServerUnavailable(let name):
            return "19|\(name)"
        case .liveServerFailed(let name):
            return "20|\(name)"
        case .unmappedRuntimeTool(let name):
            return "21|\(name)"
        case .duplicateRuntimeTool(let serverName, let toolName):
            return "22|\(serverName)|\(toolName)"
        case .duplicateConnectorToolDeclaration(let connectorID, let toolName):
            return "23|\(key(connectorID))|\(toolName)"
        case .undeclaredRuntimeTool(let connectorID, let toolName):
            return "24|\(key(connectorID))|\(toolName)"
        case .declaredToolUnavailable(let connectorID, let toolName):
            return "25|\(key(connectorID))|\(toolName)"
        case .toolDisabled(let toolName):
            return "26|\(toolName)"
        }
    }
}

struct YouziConnectedApplicationCapability: Sendable, Equatable, Identifiable {
    /// Account UUID when present, otherwise connector UUID for a definition row.
    let id: UUID
    let connectorID: UUID
    let connectionAccountID: UUID?
    let bindingRevision: Int?
    let connectorName: String?
    let accountDisplayName: String?
    let status: YouziConnectedApplicationStatus
    let tools: [YouziConnectedApplicationTool]
    let candidateToolNames: [String]
    let issues: [YouziConnectorCapabilityIssue]
}

struct YouziConnectorCapabilityProjection: Sendable, Equatable {
    let applications: [YouziConnectedApplicationCapability]
    let issues: [YouziConnectorCapabilityIssue]

    /// Exact per-account input for `YouziTaskCapabilityResolverInput`.
    /// Callers still key these names by connector ID for the resolver and must
    /// retain the selected account IDs; this property never grants authority.
    var candidateToolNamesByAccountID: [UUID: [String]] {
        Dictionary(
            uniqueKeysWithValues: applications.compactMap { application in
                guard let accountID = application.connectionAccountID else { return nil }
                return (accountID, application.candidateToolNames)
            }
        )
    }
}

/// Pure join between one domain document and one sanitized operational
/// snapshot. It owns no registry, persistence, secret, approval, or execution.
struct YouziConnectorCapabilityFacade: Sendable {
    func project(
        document: YouziDomainDocument,
        runtime: YouziMCPRuntimeSnapshot
    ) -> YouziConnectorCapabilityProjection {
        let connectors = RecordIndex(document.connectors)
        let accounts = RecordIndex(document.connectionAccounts)
        let bindings = RecordIndex(document.connectorBindings)
        var allIssues: [YouziConnectorCapabilityIssue] = []

        for id in sortedIDs(connectors.duplicateIDs) {
            append(.duplicateRecord(kind: .connector, id: id), to: &allIssues)
        }
        for id in sortedIDs(accounts.duplicateIDs) {
            append(.duplicateRecord(kind: .connectionAccount, id: id), to: &allIssues)
        }
        for id in sortedIDs(bindings.duplicateIDs) {
            append(.duplicateRecord(kind: .connectorBinding, id: id), to: &allIssues)
        }
        for bindingID in sortedIDs(Set(document.connectorBindings.map(\.id)))
        where accounts.records[bindingID] == nil && !accounts.duplicateIDs.contains(bindingID) {
            append(.orphanBinding(accountID: bindingID), to: &allIssues)
        }
        for tool in runtime.tools where tool.serverName == nil {
            append(.unmappedRuntimeTool(name: tool.name), to: &allIssues)
        }

        var applications: [YouziConnectedApplicationCapability] = []
        for account in accounts.records.values.sorted(by: stableIDOrder) {
            let application = projectAccount(
                account,
                connectors: connectors,
                bindings: bindings,
                runtime: runtime
            )
            applications.append(application)
            for issue in application.issues { append(issue, to: &allIssues) }
        }

        let referencedConnectorIDs = Set(document.connectionAccounts.map(\.connectorID))
        for connector in connectors.records.values.sorted(by: stableIDOrder)
        where !referencedConnectorIDs.contains(connector.id) {
            var issues: [YouziConnectorCapabilityIssue] = []
            let status: YouziConnectedApplicationStatus
            if connector.state == .active {
                status = .definition
            } else {
                status = .disabled
                append(
                    .inactiveConnector(connectorID: connector.id, state: connector.state),
                    to: &issues
                )
            }
            applications.append(
                YouziConnectedApplicationCapability(
                    id: connector.id,
                    connectorID: connector.id,
                    connectionAccountID: nil,
                    bindingRevision: nil,
                    connectorName: connector.name,
                    accountDisplayName: nil,
                    status: status,
                    tools: [],
                    candidateToolNames: [],
                    issues: finalized(issues)
                )
            )
            for issue in issues { append(issue, to: &allIssues) }
        }

        applications.sort {
            if $0.id != $1.id { return stableIDOrder($0, $1) }
            return $0.connectorID.uuidString < $1.connectorID.uuidString
        }
        return YouziConnectorCapabilityProjection(
            applications: applications,
            issues: finalized(allIssues)
        )
    }

    private func projectAccount(
        _ account: YouziConnectionAccount,
        connectors: RecordIndex<YouziConnector>,
        bindings: RecordIndex<YouziConnectorBinding>,
        runtime: YouziMCPRuntimeSnapshot
    ) -> YouziConnectedApplicationCapability {
        var issues: [YouziConnectorCapabilityIssue] = []
        let connector: YouziConnector?
        if connectors.duplicateIDs.contains(account.connectorID) {
            append(
                .duplicateRecord(kind: .connector, id: account.connectorID),
                to: &issues
            )
            connector = nil
        } else if let found = connectors.records[account.connectorID] {
            connector = found
        } else {
            append(
                .missingConnector(accountID: account.id, connectorID: account.connectorID),
                to: &issues
            )
            connector = nil
        }

        let binding: YouziConnectorBinding?
        if bindings.duplicateIDs.contains(account.id) {
            append(.duplicateRecord(kind: .connectorBinding, id: account.id), to: &issues)
            binding = nil
        } else {
            binding = bindings.records[account.id]
        }

        guard let connector else {
            return application(
                account: account,
                connector: nil,
                binding: binding,
                status: .error,
                issues: issues
            )
        }

        guard connector.state == .active else {
            append(
                .inactiveConnector(connectorID: connector.id, state: connector.state),
                to: &issues
            )
            return application(
                account: account,
                connector: connector,
                binding: binding,
                status: .disabled,
                issues: issues
            )
        }
        if account.state == .disabled {
            append(.accountNotConnected(accountID: account.id, state: .disabled), to: &issues)
            return application(
                account: account,
                connector: connector,
                binding: binding,
                status: .disabled,
                issues: issues
            )
        }
        if account.state == .needsAttention || account.recoveryCode != nil {
            append(.accountNeedsAttention(accountID: account.id), to: &issues)
            return application(
                account: account,
                connector: connector,
                binding: binding,
                status: .error,
                issues: issues
            )
        }

        guard let binding else {
            if !bindings.duplicateIDs.contains(account.id) {
                append(.missingBinding(accountID: account.id), to: &issues)
            }
            let status: YouziConnectedApplicationStatus = account.state == .connected
                ? .unavailable : .definition
            return application(
                account: account,
                connector: connector,
                binding: nil,
                status: status,
                issues: issues
            )
        }
        guard binding.configurationRevision > 0, binding.recoveryCode == nil else {
            append(.invalidBinding(accountID: account.id), to: &issues)
            return application(
                account: account,
                connector: connector,
                binding: binding,
                status: .unavailable,
                issues: issues
            )
        }
        guard connector.adapter == .mcp,
              case .mcp(let serverName) = binding.runtime,
              MCPServerConfig.isValidName(serverName)
        else {
            append(
                .mismatchedRuntimeBinding(
                    accountID: account.id,
                    connectorID: connector.id
                ),
                to: &issues
            )
            return application(
                account: account,
                connector: connector,
                binding: binding,
                status: .error,
                issues: issues
            )
        }

        guard runtime.configurationState == .readable else {
            append(.configurationUnreadable, to: &issues)
            return application(
                account: account,
                connector: connector,
                binding: binding,
                status: .error,
                issues: issues
            )
        }

        let configured = runtime.configuredServers.filter { $0.name == serverName }
        guard configured.count == 1 else {
            if configured.isEmpty {
                append(
                    .staleMCPBinding(accountID: account.id, serverName: serverName),
                    to: &issues
                )
            } else {
                append(.duplicateConfiguredServer(name: serverName), to: &issues)
            }
            return application(
                account: account,
                connector: connector,
                binding: binding,
                status: configured.isEmpty ? .unavailable : .error,
                issues: issues
            )
        }
        guard runtime.connectorsEnabled else {
            append(.connectorsDisabled, to: &issues)
            return application(
                account: account,
                connector: connector,
                binding: binding,
                status: .disabled,
                issues: issues
            )
        }
        guard configured[0].isEnabled else {
            append(.configuredServerDisabled(name: serverName), to: &issues)
            return application(
                account: account,
                connector: connector,
                binding: binding,
                status: .disabled,
                issues: issues
            )
        }

        guard account.state == .connected else {
            append(
                .accountNotConnected(accountID: account.id, state: account.state),
                to: &issues
            )
            return application(
                account: account,
                connector: connector,
                binding: binding,
                status: .configured,
                issues: issues
            )
        }

        switch runtime.catalogState {
        case .notConfigured:
            append(.runtimeNotConfigured, to: &issues)
            return application(
                account: account,
                connector: connector,
                binding: binding,
                status: .authorized,
                issues: issues
            )
        case .unavailable:
            append(.runtimeUnavailable, to: &issues)
            return application(
                account: account,
                connector: connector,
                binding: binding,
                status: .unavailable,
                issues: issues
            )
        case .failed:
            append(.runtimeFailed, to: &issues)
            return application(
                account: account,
                connector: connector,
                binding: binding,
                status: .error,
                issues: issues
            )
        case .ready:
            break
        }

        let liveServers = runtime.liveServers.filter { $0.name == serverName }
        guard liveServers.count == 1 else {
            if liveServers.isEmpty {
                append(.liveServerUnavailable(name: serverName), to: &issues)
            } else {
                append(.duplicateLiveServer(name: serverName), to: &issues)
            }
            return application(
                account: account,
                connector: connector,
                binding: binding,
                status: liveServers.isEmpty ? .unavailable : .error,
                issues: issues
            )
        }
        switch liveServers[0].state {
        case .connected:
            let toolResult = projectedTools(
                connector: connector,
                serverName: serverName,
                runtime: runtime
            )
            issues.append(contentsOf: toolResult.issues)
            return application(
                account: account,
                connector: connector,
                binding: binding,
                status: .live,
                tools: toolResult.tools,
                issues: issues
            )
        case .failed:
            append(.liveServerFailed(name: serverName), to: &issues)
            return application(
                account: account,
                connector: connector,
                binding: binding,
                status: .error,
                issues: issues
            )
        case .disconnected, .unknown:
            append(.liveServerUnavailable(name: serverName), to: &issues)
            return application(
                account: account,
                connector: connector,
                binding: binding,
                status: .unavailable,
                issues: issues
            )
        }
    }

    private func projectedTools(
        connector: YouziConnector,
        serverName: String,
        runtime: YouziMCPRuntimeSnapshot
    ) -> (
        tools: [YouziConnectedApplicationTool],
        issues: [YouziConnectorCapabilityIssue]
    ) {
        var issues: [YouziConnectorCapabilityIssue] = []
        let declarations = Dictionary(grouping: connector.toolNames, by: { $0 })
        for (name, values) in declarations where values.count > 1 {
            append(
                .duplicateConnectorToolDeclaration(
                    connectorID: connector.id,
                    toolName: name
                ),
                to: &issues
            )
        }
        let declaredNames = Set(declarations.keys)
        let runtimeTools = runtime.tools.filter { $0.serverName == serverName }
        let runtimeByName = Dictionary(grouping: runtimeTools, by: \.name)
        var tools: [YouziConnectedApplicationTool] = []

        for name in runtimeByName.keys.sorted() {
            guard let matches = runtimeByName[name] else { continue }
            if matches.count != 1 {
                append(
                    .duplicateRuntimeTool(serverName: serverName, toolName: name),
                    to: &issues
                )
                tools.append(.init(name: name, status: .unavailable))
            } else if !declaredNames.contains(name) {
                append(
                    .undeclaredRuntimeTool(connectorID: connector.id, toolName: name),
                    to: &issues
                )
                tools.append(.init(name: name, status: .undeclared))
            } else if !matches[0].isEnabled {
                append(.toolDisabled(toolName: name), to: &issues)
                tools.append(.init(name: name, status: .disabled))
            } else {
                tools.append(.init(name: name, status: .candidate))
            }
        }

        for name in declaredNames.sorted() where runtimeByName[name] == nil {
            append(
                .declaredToolUnavailable(connectorID: connector.id, toolName: name),
                to: &issues
            )
            tools.append(.init(name: name, status: .unavailable))
        }
        tools.sort { $0.name < $1.name }
        return (tools, finalized(issues))
    }

    private func application(
        account: YouziConnectionAccount,
        connector: YouziConnector?,
        binding: YouziConnectorBinding?,
        status: YouziConnectedApplicationStatus,
        tools: [YouziConnectedApplicationTool] = [],
        issues: [YouziConnectorCapabilityIssue]
    ) -> YouziConnectedApplicationCapability {
        YouziConnectedApplicationCapability(
            id: account.id,
            connectorID: account.connectorID,
            connectionAccountID: account.id,
            bindingRevision: binding?.configurationRevision,
            connectorName: connector?.name,
            accountDisplayName: account.displayName,
            status: status,
            tools: tools,
            candidateToolNames: tools.compactMap {
                $0.status == .candidate ? $0.name : nil
            }.sorted(),
            issues: finalized(issues)
        )
    }
}

// MARK: - Deterministic helpers

private struct RecordIndex<Record: Identifiable> where Record.ID == UUID {
    let records: [UUID: Record]
    let duplicateIDs: Set<UUID>

    init(_ values: [Record]) {
        let grouped = Dictionary(grouping: values, by: \.id)
        records = grouped.compactMapValues { $0.count == 1 ? $0[0] : nil }
        duplicateIDs = Set(grouped.compactMap { $0.value.count > 1 ? $0.key : nil })
    }
}

private func stableIDOrder<Record: Identifiable>(_ lhs: Record, _ rhs: Record) -> Bool
where Record.ID == UUID {
    lhs.id.uuidString.lowercased() < rhs.id.uuidString.lowercased()
}

private func sortedIDs<S: Sequence>(_ values: S) -> [UUID] where S.Element == UUID {
    values.sorted { $0.uuidString.lowercased() < $1.uuidString.lowercased() }
}

private func append(
    _ issue: YouziConnectorCapabilityIssue,
    to issues: inout [YouziConnectorCapabilityIssue]
) {
    if !issues.contains(issue) { issues.append(issue) }
}

private func finalized(
    _ issues: [YouziConnectorCapabilityIssue]
) -> [YouziConnectorCapabilityIssue] {
    var unique: [YouziConnectorCapabilityIssue] = []
    for issue in issues { append(issue, to: &unique) }
    return unique.sorted { $0.sortKey < $1.sortKey }
}
