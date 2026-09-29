import Foundation
import Observation

// MARK: - Safe reconciliation contract

enum YouziMCPReconciliationIssue: Sendable, Equatable {
    case configurationUnavailable
    case duplicateConfiguredServer(name: String)
    case duplicateLiveServer(name: String)
    case duplicateRuntimeTool(serverName: String, toolName: String)
    case invalidServerIdentity
    case identifierAllocationFailed(serverName: String)
    case duplicateBoundServer(serverName: String)
    case orphanBinding(accountID: UUID)
    case invalidBinding(accountID: UUID)
    case missingBinding(accountID: UUID)
    case missingBoundServer(accountID: UUID, serverName: String)
}

enum YouziMCPReconciliationRecovery: Sendable, Equatable {
    case retryInspection
    case openAdvancedSettings
    case reconcileAccount(UUID)
    case retryCredentialCleanup(UUID)
    case removeAccountReferences(UUID)
}

struct YouziMCPReconciliationPlan: Sendable, Equatable {
    enum Operation: Sendable, Equatable {
        case create(
            connector: YouziConnector,
            account: YouziConnectionAccount,
            binding: YouziConnectorRuntimeBinding
        )
        case refresh(
            accountID: UUID,
            toolNames: [String],
            state: YouziConnectionState,
            accountRecoveryCode: YouziRecoveryCode?,
            bindingRecoveryCode: YouziRecoveryCode?
        )
        case refreshAccountHealth(
            accountID: UUID,
            state: YouziConnectionState,
            recoveryCode: YouziRecoveryCode?
        )
    }

    let operations: [Operation]
    let issues: [YouziMCPReconciliationIssue]
}

/// Builds a deterministic, secret-free reconciliation plan from domain state
/// and the sanitized snapshot owned by `YouziConnectorCapabilityFacade`.
///
/// Display names are never a join key. The only existing-record join is the
/// exact account binding and exact MCP server name. A newly configured server
/// that resembles a stale row therefore creates a separate stable identity;
/// the stale row remains needs-attention until an explicit rename action.
@MainActor
struct YouziMCPConnectedApplicationReconciler: Sendable {
    private let makeUUID: @Sendable () -> UUID

    init(makeUUID: @escaping @Sendable () -> UUID = UUID.init) {
        self.makeUUID = makeUUID
    }

    func plan(
        document: YouziDomainDocument,
        runtime: YouziMCPRuntimeSnapshot,
        activatingAccountIDs: Set<UUID> = [],
        at date: Date
    ) -> YouziMCPReconciliationPlan {
        guard runtime.configurationState == .readable else {
            return .init(operations: [], issues: [.configurationUnavailable])
        }

        var operations: [YouziMCPReconciliationPlan.Operation] = []
        var issues: [YouziMCPReconciliationIssue] = []
        var usedIDs = Set(document.connectors.map(\.id))
            .union(document.connectionAccounts.map(\.id))
        let connectorsByID = Dictionary(
            document.connectors.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let accountsByID = Dictionary(
            document.connectionAccounts.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let configuredGroups = Dictionary(grouping: runtime.configuredServers, by: \.name)
        let liveGroups = Dictionary(grouping: runtime.liveServers, by: \.name)
        let toolGroups = Dictionary(
            grouping: runtime.tools.compactMap { tool -> (String, YouziMCPRuntimeSnapshot.Tool)? in
                guard let serverName = tool.serverName else { return nil }
                return (serverName, tool)
            },
            by: { $0.0 }
        )

        var validConfigured: [String: YouziMCPRuntimeSnapshot.ConfiguredServer] = [:]
        for name in configuredGroups.keys.sorted() {
            let entries = configuredGroups[name] ?? []
            guard MCPServerConfig.isValidName(name) else {
                issues.append(.invalidServerIdentity)
                continue
            }
            guard entries.count == 1 else {
                issues.append(.duplicateConfiguredServer(name: name))
                continue
            }
            validConfigured[name] = entries[0]
        }

        var uniqueLive: [String: YouziMCPRuntimeSnapshot.LiveServer] = [:]
        for name in liveGroups.keys.sorted() {
            let entries = liveGroups[name] ?? []
            guard MCPServerConfig.isValidName(name) else {
                issues.append(.invalidServerIdentity)
                continue
            }
            guard entries.count == 1 else {
                issues.append(.duplicateLiveServer(name: name))
                continue
            }
            uniqueLive[name] = entries[0]
        }

        var sanitizedToolNames: [String: [String]] = [:]
        for serverName in toolGroups.keys.sorted() {
            guard MCPServerConfig.isValidName(serverName) else {
                issues.append(.invalidServerIdentity)
                continue
            }
            let tools = (toolGroups[serverName] ?? []).map(\.1)
                .filter { MCPCatalog.isLegalFunctionName($0.name) }
            let groupedNames = Dictionary(grouping: tools, by: \.name)
            var names: [String] = []
            for name in groupedNames.keys.sorted() {
                let entries = groupedNames[name] ?? []
                guard entries.count == 1 else {
                    issues.append(.duplicateRuntimeTool(serverName: serverName, toolName: name))
                    continue
                }
                names.append(name)
            }
            sanitizedToolNames[serverName] = names
        }

        var validBindingsByServer: [String: [(YouziConnectorBinding, YouziConnectionAccount)]] = [:]
        var accountIDsWithBinding = Set<UUID>()
        for binding in document.connectorBindings.sorted(by: { uuidKey($0.id) < uuidKey($1.id) }) {
            guard let account = accountsByID[binding.id] else {
                issues.append(.orphanBinding(accountID: binding.id))
                continue
            }
            accountIDsWithBinding.insert(account.id)
            guard let connector = connectorsByID[account.connectorID], connector.adapter == .mcp,
                  case .mcp(let serverName) = binding.runtime,
                  MCPServerConfig.isValidName(serverName) else {
                issues.append(.invalidBinding(accountID: account.id))
                continue
            }
            validBindingsByServer[serverName, default: []].append((binding, account))
        }

        for account in document.connectionAccounts.sorted(by: { uuidKey($0.id) < uuidKey($1.id) }) {
            guard connectorsByID[account.connectorID]?.adapter == .mcp,
                  !accountIDsWithBinding.contains(account.id) else { continue }
            issues.append(.missingBinding(accountID: account.id))
            operations.append(
                .refreshAccountHealth(
                    accountID: account.id,
                    state: .needsAttention,
                    recoveryCode: .connectorUnconfigured
                )
            )
        }

        for serverName in validBindingsByServer.keys.sorted() {
            let entries = validBindingsByServer[serverName] ?? []
            guard entries.count == 1 else {
                issues.append(.duplicateBoundServer(serverName: serverName))
                continue
            }
            let (_, account) = entries[0]
            guard let configured = validConfigured[serverName] else {
                issues.append(.missingBoundServer(accountID: account.id, serverName: serverName))
                operations.append(
                    .refresh(
                        accountID: account.id,
                        toolNames: connectorsByID[account.connectorID]?.toolNames ?? [],
                        state: .needsAttention,
                        accountRecoveryCode: .connectorUnconfigured,
                        bindingRecoveryCode: .connectorUnconfigured
                    )
                )
                continue
            }

            let tools = runtime.catalogState == .ready
                ? sanitizedToolNames[serverName, default: []]
                : connectorsByID[account.connectorID]?.toolNames ?? []
            let health = accountHealth(
                current: account,
                configured: configured,
                live: uniqueLive[serverName],
                runtime: runtime,
                activate: activatingAccountIDs.contains(account.id)
            )
            operations.append(
                .refresh(
                    accountID: account.id,
                    toolNames: tools,
                    state: health.state,
                    accountRecoveryCode: health.recovery,
                    bindingRecoveryCode: health.bindingRecovery
                )
            )
        }

        for serverName in validConfigured.keys.sorted()
        where validBindingsByServer[serverName] == nil {
            guard let configured = validConfigured[serverName] else { continue }
            guard let connectorID = freshID(usedIDs: &usedIDs),
                  let accountID = freshID(usedIDs: &usedIDs) else {
                issues.append(.identifierAllocationFailed(serverName: serverName))
                continue
            }
            let live = uniqueLive[serverName]
            let liveConnected = runtime.connectorsEnabled && configured.isEnabled
                && runtime.catalogState == .ready && live?.state == .connected
            let disabled = !runtime.connectorsEnabled || !configured.isEnabled
            let accountState: YouziConnectionState = disabled
                ? .disabled
                : (liveConnected ? .connected : .notConnected)
            let recovery: YouziRecoveryCode? = disabled || liveConnected
                ? nil
                : (live?.state == .failed ? .connectorUnavailable : .runtimeUnavailable)
            let toolNames = runtime.catalogState == .ready
                ? sanitizedToolNames[serverName, default: []]
                : []
            let connector = YouziConnector(
                id: connectorID,
                name: serverName,
                summary: "自定义本地应用",
                adapter: .mcp,
                authentication: .custom,
                toolNames: toolNames,
                source: .init(
                    kind: .userCreated,
                    identifier: "youzi.mcp.\(uuidKey(connectorID))",
                    version: "1"
                ),
                createdAt: date,
                updatedAt: date
            )
            let account = YouziConnectionAccount(
                id: accountID,
                connectorID: connectorID,
                displayName: serverName,
                state: accountState,
                lastCheckedAt: date,
                recoveryCode: recovery,
                createdAt: date,
                updatedAt: date
            )
            operations.append(
                .create(connector: connector, account: account, binding: .mcp(serverName: serverName))
            )
        }

        return .init(operations: operations, issues: sortedIssues(issues))
    }

    private func accountHealth(
        current account: YouziConnectionAccount,
        configured: YouziMCPRuntimeSnapshot.ConfiguredServer,
        live: YouziMCPRuntimeSnapshot.LiveServer?,
        runtime: YouziMCPRuntimeSnapshot,
        activate: Bool
    ) -> (state: YouziConnectionState, recovery: YouziRecoveryCode?, bindingRecovery: YouziRecoveryCode?) {
        if account.recoveryCode == .credentialCleanupPending {
            return (.needsAttention, .credentialCleanupPending, nil)
        }
        if account.state == .disabled && !activate {
            return (.disabled, account.recoveryCode, nil)
        }
        if account.state == .notConnected && !activate {
            return (.notConnected, nil, nil)
        }
        guard runtime.connectorsEnabled, configured.isEnabled else {
            return (.disabled, nil, nil)
        }
        guard runtime.catalogState == .ready else {
            return (.needsAttention, .runtimeUnavailable, .runtimeUnavailable)
        }
        switch live?.state {
        case .connected?:
            return (.connected, nil, nil)
        case .failed?:
            return (.needsAttention, .connectorUnavailable, .connectorUnavailable)
        case .disconnected?, .unknown?, nil:
            return (.needsAttention, .connectorUnavailable, .connectorUnavailable)
        }
    }

    private func freshID(usedIDs: inout Set<UUID>) -> UUID? {
        for _ in 0..<32 {
            let candidate = makeUUID()
            if usedIDs.insert(candidate).inserted { return candidate }
        }
        return nil
    }

    private func sortedIssues(_ issues: [YouziMCPReconciliationIssue])
        -> [YouziMCPReconciliationIssue]
    {
        issues.sorted { issueKey($0) < issueKey($1) }.reduce(into: []) { result, issue in
            if !result.contains(issue) { result.append(issue) }
        }
    }

    private func issueKey(_ issue: YouziMCPReconciliationIssue) -> String {
        switch issue {
        case .configurationUnavailable: return "01"
        case .duplicateConfiguredServer(let name): return "02|\(name)"
        case .duplicateLiveServer(let name): return "03|\(name)"
        case .duplicateRuntimeTool(let server, let tool): return "04|\(server)|\(tool)"
        case .invalidServerIdentity: return "05"
        case .identifierAllocationFailed(let name): return "06|\(name)"
        case .duplicateBoundServer(let name): return "07|\(name)"
        case .orphanBinding(let id): return "08|\(uuidKey(id))"
        case .invalidBinding(let id): return "09|\(uuidKey(id))"
        case .missingBinding(let id): return "10|\(uuidKey(id))"
        case .missingBoundServer(let id, let name): return "11|\(uuidKey(id))|\(name)"
        }
    }

    private func uuidKey(_ id: UUID) -> String { id.uuidString.lowercased() }
}

// MARK: - Existing-owner adapters

@MainActor
protocol YouziMCPRuntimeControlling: AnyObject {
    func snapshot() -> YouziMCPRuntimeSnapshot
    func upsert(_ server: MCPServerConfig, replacing originalName: String?) throws
    func setServerEnabled(_ serverName: String, _ enabled: Bool) throws
    func removeServer(named serverName: String) throws
    func inspect() async -> YouziMCPRuntimeSnapshot
    func reloadAfterWrite() async -> YouziMCPRuntimeSnapshot
}

/// A narrow adapter over the already-composed MCP owners. It owns no config,
/// registry, approval state, connection, or persistence of its own.
@MainActor
final class YouziMCPRuntimeOwnerAdapter: YouziMCPRuntimeControlling {
    private let configStore: MCPConfigStore
    private let catalog: MCPCatalog
    private let registry: MCPToolRegistry

    init(configStore: MCPConfigStore, catalog: MCPCatalog, registry: MCPToolRegistry) {
        self.configStore = configStore
        self.catalog = catalog
        self.registry = registry
    }

    func snapshot() -> YouziMCPRuntimeSnapshot {
        .capture(configStore: configStore, catalog: catalog, registry: registry)
    }

    func upsert(_ server: MCPServerConfig, replacing originalName: String?) throws {
        try configStore.upsert(server, replacing: originalName)
    }

    func setServerEnabled(_ serverName: String, _ enabled: Bool) throws {
        try configStore.setServerEnabled(serverName, enabled)
    }

    func removeServer(named serverName: String) throws {
        try configStore.remove(named: serverName)
    }

    func inspect() async -> YouziMCPRuntimeSnapshot {
        _ = await catalog.refresh()
        return snapshot()
    }

    func reloadAfterWrite() async -> YouziMCPRuntimeSnapshot {
        _ = await catalog.reload()
        return snapshot()
    }
}

protocol YouziMCPConnectedApplicationDomainManaging: Sendable {
    func load() throws -> YouziDomainDocument
    func createConnectorAccount(
        connector: YouziConnector,
        account: YouziConnectionAccount,
        runtime: YouziConnectorRuntimeBinding,
        at date: Date
    ) throws -> YouziDomainDocument
    func reconcileMCPAccount(
        id: UUID,
        toolNames: [String],
        state: YouziConnectionState,
        accountRecoveryCode: YouziRecoveryCode?,
        bindingRecoveryCode: YouziRecoveryCode?,
        at date: Date
    ) throws -> YouziDomainDocument
    func reconcileAccountHealth(
        id: UUID,
        state: YouziConnectionState,
        recoveryCode: YouziRecoveryCode?,
        at date: Date
    ) throws -> YouziDomainDocument
    func setAccountEnabled(id: UUID, enabled: Bool, at date: Date) throws -> YouziDomainDocument
    func reconcileBinding(
        accountID: UUID,
        runtime: YouziConnectorRuntimeBinding,
        expectedRevision: Int?,
        at date: Date
    ) throws -> YouziDomainDocument
    func invalidateBindingExecutionIdentity(
        accountID: UUID,
        expectedRevision: Int,
        at date: Date
    ) throws -> YouziDomainDocument
    func disconnectAccount(id: UUID, at date: Date) throws -> YouziDomainDocument
    func beginCredentialCleanup(id: UUID, at date: Date) throws -> YouziDomainDocument
    func finishCredentialCleanup(id: UUID, at date: Date) throws -> YouziDomainDocument
    func forgetAccount(id: UUID, at date: Date) throws -> YouziDomainDocument
}

struct YouziMCPDomainLifecycleAdapter: YouziMCPConnectedApplicationDomainManaging {
    private let store: YouziDomainStore
    private let repository: YouziCapabilityRepository

    init(store: YouziDomainStore = YouziDomainStore()) {
        self.store = store
        self.repository = YouziCapabilityRepository(store: store)
    }

    func load() throws -> YouziDomainDocument { try store.load() }

    func createConnectorAccount(
        connector: YouziConnector,
        account: YouziConnectionAccount,
        runtime: YouziConnectorRuntimeBinding,
        at date: Date
    ) throws -> YouziDomainDocument {
        try repository.createConnectorAccount(
            connector: connector, account: account, runtime: runtime, at: date
        )
    }

    func reconcileMCPAccount(
        id: UUID,
        toolNames: [String],
        state: YouziConnectionState,
        accountRecoveryCode: YouziRecoveryCode?,
        bindingRecoveryCode: YouziRecoveryCode?,
        at date: Date
    ) throws -> YouziDomainDocument {
        try repository.reconcileMCPAccount(
            id: id,
            toolNames: toolNames,
            state: state,
            accountRecoveryCode: accountRecoveryCode,
            bindingRecoveryCode: bindingRecoveryCode,
            at: date
        )
    }

    func reconcileAccountHealth(
        id: UUID,
        state: YouziConnectionState,
        recoveryCode: YouziRecoveryCode?,
        at date: Date
    ) throws -> YouziDomainDocument {
        try repository.reconcileAccountHealth(
            id: id, state: state, recoveryCode: recoveryCode, at: date
        )
    }

    func setAccountEnabled(id: UUID, enabled: Bool, at date: Date) throws -> YouziDomainDocument {
        try repository.setAccountEnabled(id: id, enabled: enabled, at: date)
    }

    func reconcileBinding(
        accountID: UUID,
        runtime: YouziConnectorRuntimeBinding,
        expectedRevision: Int?,
        at date: Date
    ) throws -> YouziDomainDocument {
        try repository.reconcileBinding(
            accountID: accountID, runtime: runtime,
            expectedRevision: expectedRevision, at: date
        )
    }

    func invalidateBindingExecutionIdentity(
        accountID: UUID,
        expectedRevision: Int,
        at date: Date
    ) throws -> YouziDomainDocument {
        try repository.invalidateBindingExecutionIdentity(
            accountID: accountID, expectedRevision: expectedRevision, at: date
        )
    }

    func disconnectAccount(id: UUID, at date: Date) throws -> YouziDomainDocument {
        try repository.disconnectAccount(id: id, at: date)
    }

    func beginCredentialCleanup(id: UUID, at date: Date) throws -> YouziDomainDocument {
        try repository.beginCredentialCleanup(id: id, at: date)
    }

    func finishCredentialCleanup(id: UUID, at date: Date) throws -> YouziDomainDocument {
        try repository.finishCredentialCleanup(id: id, at: date)
    }

    func forgetAccount(id: UUID, at date: Date) throws -> YouziDomainDocument {
        try repository.forgetAccount(id: id, at: date)
    }
}

// MARK: - App-facing lifecycle controller

enum YouziMCPConnectedApplicationAction: Sendable, Equatable {
    case createOrImport
    case inspect
    case pause
    case resume
    case update
    case disconnect
    case forget
}

enum YouziMCPConnectedApplicationOutcome: Sendable, Equatable {
    case completed
    case needsAttention
    case failed
}

enum YouziMCPConnectedApplicationFailure: Sendable, Equatable {
    case accountNotFound
    case invalidMCPBinding
    case operationalWriteFailed
    case domainWriteFailed
    case credentialCleanupFailed
    case accountStillReferenced
}

struct YouziMCPConnectedApplicationActionResult: Sendable, Equatable {
    let action: YouziMCPConnectedApplicationAction
    let outcome: YouziMCPConnectedApplicationOutcome
    let accountID: UUID?
    let failure: YouziMCPConnectedApplicationFailure?
    let issues: [YouziMCPReconciliationIssue]
    let recovery: YouziMCPReconciliationRecovery?
}

@MainActor
@Observable
final class YouziMCPConnectedApplicationController {
    private let runtime: any YouziMCPRuntimeControlling
    private let domain: any YouziMCPConnectedApplicationDomainManaging
    private let vault: any YouziConnectorCredentialVault
    private let reconciler: YouziMCPConnectedApplicationReconciler
    private let now: @Sendable () -> Date

    init(
        runtime: any YouziMCPRuntimeControlling,
        domain: any YouziMCPConnectedApplicationDomainManaging,
        vault: any YouziConnectorCredentialVault,
        reconciler: YouziMCPConnectedApplicationReconciler = .init(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.runtime = runtime
        self.domain = domain
        self.vault = vault
        self.reconciler = reconciler
        self.now = now
    }

    func createOrImport(_ server: MCPServerConfig) async
        -> YouziMCPConnectedApplicationActionResult
    {
        do {
            try runtime.upsert(server, replacing: nil)
        } catch {
            return failure(.createOrImport, .operationalWriteFailed, recovery: .openAdvancedSettings)
        }
        let snapshot = await runtime.reloadAfterWrite()
        return reconcile(action: .createOrImport, snapshot: snapshot)
    }

    /// Imports an exact server that already exists in MCPConfigStore. This
    /// does not rewrite or read its secret-bearing execution configuration.
    func importConfiguredServer(named serverName: String) async
        -> YouziMCPConnectedApplicationActionResult
    {
        let snapshot = runtime.snapshot()
        guard MCPServerConfig.isValidName(serverName),
              snapshot.configuredServers.filter({ $0.name == serverName }).count == 1 else {
            return failure(.createOrImport, .operationalWriteFailed,
                           recovery: .openAdvancedSettings)
        }
        return reconcile(action: .createOrImport, snapshot: snapshot)
    }

    func inspect() async -> YouziMCPConnectedApplicationActionResult {
        let snapshot = await runtime.inspect()
        return reconcile(action: .inspect, snapshot: snapshot)
    }

    func pause(accountID: UUID) async -> YouziMCPConnectedApplicationActionResult {
        guard let context = accountContext(accountID) else {
            return failure(.pause, .accountNotFound, accountID: accountID)
        }
        guard let serverName = context.serverName else {
            return failure(.pause, .invalidMCPBinding, accountID: accountID,
                           recovery: .openAdvancedSettings)
        }
        do {
            try runtime.setServerEnabled(serverName, false)
        } catch {
            return failure(.pause, .operationalWriteFailed, accountID: accountID,
                           recovery: .openAdvancedSettings)
        }
        do {
            _ = try domain.setAccountEnabled(id: accountID, enabled: false, at: now())
        } catch {
            return failure(.pause, .domainWriteFailed, accountID: accountID,
                           recovery: .reconcileAccount(accountID))
        }
        _ = await runtime.reloadAfterWrite()
        return success(.pause, accountID: accountID)
    }

    func resume(accountID: UUID) async -> YouziMCPConnectedApplicationActionResult {
        guard let context = accountContext(accountID) else {
            return failure(.resume, .accountNotFound, accountID: accountID)
        }
        guard let serverName = context.serverName else {
            return failure(.resume, .invalidMCPBinding, accountID: accountID,
                           recovery: .openAdvancedSettings)
        }
        do {
            try runtime.setServerEnabled(serverName, true)
        } catch {
            return failure(.resume, .operationalWriteFailed, accountID: accountID,
                           recovery: .openAdvancedSettings)
        }
        do {
            _ = try domain.setAccountEnabled(id: accountID, enabled: true, at: now())
        } catch {
            return failure(.resume, .domainWriteFailed, accountID: accountID,
                           recovery: .reconcileAccount(accountID))
        }
        let snapshot = await runtime.reloadAfterWrite()
        return reconcile(action: .resume, snapshot: snapshot, activating: [accountID],
                         preferredAccountID: accountID)
    }

    func update(
        accountID: UUID,
        original: MCPServerConfig,
        updated: MCPServerConfig
    ) async -> YouziMCPConnectedApplicationActionResult {
        guard let context = accountContext(accountID),
              context.serverName == original.name,
              let revision = context.bindingRevision else {
            return failure(.update, .invalidMCPBinding, accountID: accountID,
                           recovery: .openAdvancedSettings)
        }
        let executionIdentityChanged = original.runsDifferentCode(from: updated)
        do {
            try runtime.upsert(updated, replacing: original.name)
        } catch {
            return failure(.update, .operationalWriteFailed, accountID: accountID,
                           recovery: .openAdvancedSettings)
        }

        do {
            if original.name != updated.name {
                try reconcileRenamedBinding(
                    accountID: accountID,
                    serverName: updated.name,
                    expectedRevision: revision,
                    at: now()
                )
            } else if executionIdentityChanged {
                _ = try domain.invalidateBindingExecutionIdentity(
                    accountID: accountID, expectedRevision: revision, at: now()
                )
            }
        } catch {
            return failure(.update, .domainWriteFailed, accountID: accountID,
                           recovery: .reconcileAccount(accountID))
        }

        let snapshot = await runtime.reloadAfterWrite()
        return reconcile(action: .update, snapshot: snapshot,
                         preferredAccountID: accountID)
    }

    func disconnect(accountID: UUID) -> YouziMCPConnectedApplicationActionResult {
        guard accountContext(accountID) != nil else {
            return failure(.disconnect, .accountNotFound, accountID: accountID)
        }
        do {
            _ = try domain.disconnectAccount(id: accountID, at: now())
            return success(.disconnect, accountID: accountID)
        } catch {
            return failure(.disconnect, .domainWriteFailed, accountID: accountID,
                           recovery: .reconcileAccount(accountID))
        }
    }

    func forget(accountID: UUID) async -> YouziMCPConnectedApplicationActionResult {
        guard let context = accountContext(accountID) else {
            return failure(.forget, .accountNotFound, accountID: accountID)
        }
        guard !context.isReferenced else {
            return failure(.forget, .accountStillReferenced, accountID: accountID,
                           recovery: .removeAccountReferences(accountID))
        }

        if let serverName = context.serverName {
            do {
                try runtime.removeServer(named: serverName)
            } catch {
                return failure(.forget, .operationalWriteFailed, accountID: accountID,
                               recovery: .openAdvancedSettings)
            }
        }

        if let reference = context.credentialReference {
            do {
                _ = try domain.beginCredentialCleanup(id: accountID, at: now())
                if vault.read(reference: reference, for: accountID) != .missing {
                    try vault.delete(reference: reference, for: accountID)
                }
                _ = try domain.finishCredentialCleanup(id: accountID, at: now())
            } catch {
                return failure(.forget, .credentialCleanupFailed, accountID: accountID,
                               recovery: .retryCredentialCleanup(accountID))
            }
        } else {
            do {
                _ = try domain.disconnectAccount(id: accountID, at: now())
            } catch {
                return failure(.forget, .domainWriteFailed, accountID: accountID,
                               recovery: .reconcileAccount(accountID))
            }
        }

        do {
            _ = try domain.forgetAccount(id: accountID, at: now())
        } catch let error as YouziCapabilityRepositoryError {
            if case .accountStillReferenced = error {
                return failure(.forget, .accountStillReferenced, accountID: accountID,
                               recovery: .removeAccountReferences(accountID))
            }
            return failure(.forget, .domainWriteFailed, accountID: accountID,
                           recovery: .reconcileAccount(accountID))
        } catch {
            return failure(.forget, .domainWriteFailed, accountID: accountID,
                           recovery: .reconcileAccount(accountID))
        }
        _ = await runtime.reloadAfterWrite()
        return success(.forget, accountID: accountID)
    }

    private func reconcile(
        action: YouziMCPConnectedApplicationAction,
        snapshot: YouziMCPRuntimeSnapshot,
        activating accountIDs: Set<UUID> = [],
        preferredAccountID: UUID? = nil
    ) -> YouziMCPConnectedApplicationActionResult {
        let document: YouziDomainDocument
        do {
            document = try domain.load()
        } catch {
            return failure(action, .domainWriteFailed, accountID: preferredAccountID,
                           recovery: .retryInspection)
        }
        let date = now()
        let plan = reconciler.plan(
            document: document,
            runtime: snapshot,
            activatingAccountIDs: accountIDs,
            at: date
        )
        var firstCreatedAccountID: UUID?
        do {
            for operation in plan.operations {
                switch operation {
                case let .create(connector, account, binding):
                    _ = try domain.createConnectorAccount(
                        connector: connector, account: account, runtime: binding, at: date
                    )
                    if firstCreatedAccountID == nil { firstCreatedAccountID = account.id }
                case let .refresh(accountID, tools, state, accountRecovery, bindingRecovery):
                    _ = try domain.reconcileMCPAccount(
                        id: accountID,
                        toolNames: tools,
                        state: state,
                        accountRecoveryCode: accountRecovery,
                        bindingRecoveryCode: bindingRecovery,
                        at: date
                    )
                case let .refreshAccountHealth(accountID, state, recoveryCode):
                    _ = try domain.reconcileAccountHealth(
                        id: accountID, state: state, recoveryCode: recoveryCode, at: date
                    )
                }
            }
        } catch {
            return .init(
                action: action,
                outcome: .needsAttention,
                accountID: preferredAccountID ?? firstCreatedAccountID,
                failure: .domainWriteFailed,
                issues: plan.issues,
                recovery: .retryInspection
            )
        }

        return .init(
            action: action,
            outcome: plan.issues.isEmpty ? .completed : .needsAttention,
            accountID: preferredAccountID ?? firstCreatedAccountID,
            failure: nil,
            issues: plan.issues,
            recovery: plan.issues.isEmpty ? nil : .retryInspection
        )
    }

    /// The operational rename has already committed before this domain write.
    /// A concurrent domain writer may therefore make the captured binding
    /// revision stale. Retry only that typed CAS conflict: fresh-load the exact
    /// account/binding and reconcile the same account to the already-committed
    /// server identity. Never route this recovery through generic discovery,
    /// which would treat the new server key as unbound and allocate a duplicate
    /// account.
    private func reconcileRenamedBinding(
        accountID: UUID,
        serverName: String,
        expectedRevision: Int,
        at date: Date
    ) throws {
        let runtime = YouziConnectorRuntimeBinding.mcp(serverName: serverName)
        do {
            _ = try domain.reconcileBinding(
                accountID: accountID,
                runtime: runtime,
                expectedRevision: expectedRevision,
                at: date
            )
            return
        } catch let error as YouziCapabilityRepositoryError {
            guard case .bindingRevisionConflict = error else { throw error }
        }

        let fresh = try domain.load()
        guard let account = fresh.connectionAccounts.first(where: { $0.id == accountID }) else {
            throw YouziCapabilityRepositoryError.accountNotFound(accountID)
        }
        guard let connector = fresh.connectors.first(where: { $0.id == account.connectorID }) else {
            throw YouziCapabilityRepositoryError.connectorNotFound(account.connectorID)
        }
        guard connector.adapter == .mcp else {
            throw YouziCapabilityRepositoryError.invalidRuntimeBinding(accountID)
        }
        guard let binding = fresh.connectorBindings.first(where: { $0.id == accountID }) else {
            throw YouziCapabilityRepositoryError.bindingNotFound(accountID)
        }
        guard case .mcp = binding.runtime else {
            throw YouziCapabilityRepositoryError.invalidRuntimeBinding(accountID)
        }
        _ = try domain.reconcileBinding(
            accountID: accountID,
            runtime: runtime,
            expectedRevision: binding.configurationRevision,
            at: date
        )
    }

    private func accountContext(_ accountID: UUID) -> (
        serverName: String?,
        bindingRevision: Int?,
        credentialReference: String?,
        isReferenced: Bool
    )? {
        guard let document = try? domain.load(),
              let account = document.connectionAccounts.first(where: { $0.id == accountID }) else {
            return nil
        }
        let binding = document.connectorBindings.first(where: { $0.id == accountID })
        let serverName: String?
        if let binding, case .mcp(let name) = binding.runtime {
            serverName = name
        } else {
            serverName = nil
        }
        let target = accountID.uuidString.lowercased()
        let isReferenced = document.tasks.contains { $0.connectionAccountIDs.contains(accountID) }
            || document.projects.contains { $0.defaultConnectionAccountIDs.contains(accountID) }
            || document.automations.contains { $0.action.connectionAccountIDs.contains(accountID) }
            || document.permissions.contains {
                $0.targetIdentifier == target
                    && ($0.kind == .connectorRead || $0.kind == .connectorWrite
                        || $0.kind == .externalPublish)
            }
            || document.permissionGrants.contains { $0.targetIdentifier == target }
            || document.executionAuditEvents.contains { $0.connectionAccountID == accountID }
        return (
            serverName,
            binding?.configurationRevision,
            account.credentialReference,
            isReferenced
        )
    }

    private func success(
        _ action: YouziMCPConnectedApplicationAction,
        accountID: UUID? = nil
    ) -> YouziMCPConnectedApplicationActionResult {
        .init(action: action, outcome: .completed, accountID: accountID,
              failure: nil, issues: [], recovery: nil)
    }

    private func failure(
        _ action: YouziMCPConnectedApplicationAction,
        _ failure: YouziMCPConnectedApplicationFailure,
        accountID: UUID? = nil,
        recovery: YouziMCPReconciliationRecovery? = nil
    ) -> YouziMCPConnectedApplicationActionResult {
        .init(action: action, outcome: .failed, accountID: accountID,
              failure: failure, issues: [], recovery: recovery)
    }
}
