import Foundation
import Testing
@testable import Rapid

@Suite("Youzi live connector capability facade")
struct YouziConnectorCapabilityFacadeTests {
    private let facade = YouziConnectorCapabilityFacade()

    @Test("A connector without an account remains an honest definition")
    func definitionOnly() throws {
        let connector = makeConnector(id: id(1), toolNames: ["calendar__read"])

        let result = facade.project(
            document: YouziDomainDocument(connectors: [connector]),
            runtime: .init(connectorsEnabled: true)
        )
        let application = try #require(result.applications.first)

        #expect(application.id == connector.id)
        #expect(application.connectorID == connector.id)
        #expect(application.connectionAccountID == nil)
        #expect(application.status == .definition)
        #expect(application.candidateToolNames.isEmpty)
        #expect(result.issues.isEmpty)
    }

    @Test("Configured and authorized are distinct from a live connection")
    func configuredAndAuthorizedStages() throws {
        let connector = makeConnector(id: id(10), toolNames: ["calendar__read"])
        let account = makeAccount(
            id: id(11), connectorID: connector.id, state: .notConnected
        )
        let binding = makeBinding(accountID: account.id, serverName: "calendar")
        let runtime = YouziMCPRuntimeSnapshot(
            connectorsEnabled: true,
            configuredServers: [.init(name: "calendar")],
            catalogState: .notConfigured
        )

        let configured = facade.project(
            document: makeDocument(connector, account, binding),
            runtime: runtime
        )
        let configuredApplication = try #require(configured.applications.first)
        #expect(configuredApplication.status == .configured)
        #expect(configuredApplication.issues.contains(
            .accountNotConnected(accountID: account.id, state: .notConnected)
        ))

        var connectedAccount = account
        connectedAccount.state = .connected
        let authorized = facade.project(
            document: makeDocument(connector, connectedAccount, binding),
            runtime: runtime
        )
        let authorizedApplication = try #require(authorized.applications.first)
        #expect(authorizedApplication.status == .authorized)
        #expect(authorizedApplication.candidateToolNames.isEmpty)
        #expect(authorizedApplication.issues.contains(.runtimeNotConfigured))
    }

    @Test("A connected server projects only exact declared and enabled tool candidates")
    func liveExactCandidates() throws {
        let connector = makeConnector(
            id: id(20),
            toolNames: [
                "calendar__read",
                "calendar__write",
                "calendar__missing",
            ]
        )
        let account = makeAccount(id: id(21), connectorID: connector.id)
        let binding = makeBinding(accountID: account.id, serverName: "calendar")
        let runtime = liveRuntime(
            serverName: "calendar",
            tools: [
                .init(name: "calendar__extra", serverName: "calendar"),
                .init(name: "calendar__write", serverName: "calendar", isEnabled: false),
                .init(name: "calendar__read", serverName: "calendar"),
                .init(name: "other__read", serverName: "other"),
            ]
        )

        let result = facade.project(
            document: makeDocument(connector, account, binding),
            runtime: runtime
        )
        let application = try #require(result.applications.first)

        #expect(application.status == .live)
        #expect(application.candidateToolNames == ["calendar__read"])
        #expect(application.tools == [
            .init(name: "calendar__extra", status: .undeclared),
            .init(name: "calendar__missing", status: .unavailable),
            .init(name: "calendar__read", status: .candidate),
            .init(name: "calendar__write", status: .disabled),
        ])
        #expect(result.candidateToolNamesByAccountID == [
            account.id: ["calendar__read"]
        ])
        #expect(application.issues.contains(
            .undeclaredRuntimeTool(
                connectorID: connector.id,
                toolName: "calendar__extra"
            )
        ))
        #expect(application.issues.contains(
            .declaredToolUnavailable(
                connectorID: connector.id,
                toolName: "calendar__missing"
            )
        ))
        #expect(application.issues.contains(.toolDisabled(toolName: "calendar__write")))
    }

    @Test("An unavailable live server fails closed")
    func unavailableServer() throws {
        let connector = makeConnector(id: id(30), toolNames: ["notes__read"])
        let account = makeAccount(id: id(31), connectorID: connector.id)
        let binding = makeBinding(accountID: account.id, serverName: "notes")
        let runtime = YouziMCPRuntimeSnapshot(
            connectorsEnabled: true,
            configuredServers: [.init(name: "notes")],
            catalogState: .ready,
            liveServers: [.init(name: "notes", state: .disconnected)],
            tools: [.init(name: "notes__read", serverName: "notes")]
        )

        let result = facade.project(
            document: makeDocument(connector, account, binding),
            runtime: runtime
        )
        let application = try #require(result.applications.first)

        #expect(application.status == .unavailable)
        #expect(application.candidateToolNames.isEmpty)
        #expect(application.issues.contains(.liveServerUnavailable(name: "notes")))
    }

    @Test("Domain and existing MCP disable switches both fail closed")
    func disabledAccountAndRuntime() throws {
        let connector = makeConnector(id: id(40), toolNames: ["files__read"])
        let disabledAccount = makeAccount(
            id: id(41), connectorID: connector.id, state: .disabled
        )
        let binding = makeBinding(accountID: disabledAccount.id, serverName: "files")
        let live = liveRuntime(
            serverName: "files",
            tools: [.init(name: "files__read", serverName: "files")]
        )

        let domainDisabled = facade.project(
            document: makeDocument(connector, disabledAccount, binding),
            runtime: live
        )
        let domainApplication = try #require(domainDisabled.applications.first)
        #expect(domainApplication.status == .disabled)
        #expect(domainApplication.candidateToolNames.isEmpty)

        var connectedAccount = disabledAccount
        connectedAccount.state = .connected
        let runtimeDisabled = facade.project(
            document: makeDocument(connector, connectedAccount, binding),
            runtime: .init(
                connectorsEnabled: false,
                configuredServers: [.init(name: "files")],
                catalogState: .ready,
                liveServers: [.init(name: "files", state: .connected)],
                tools: [.init(name: "files__read", serverName: "files")]
            )
        )
        let runtimeApplication = try #require(runtimeDisabled.applications.first)
        #expect(runtimeApplication.status == .disabled)
        #expect(runtimeApplication.candidateToolNames.isEmpty)
        #expect(runtimeApplication.issues.contains(.connectorsDisabled))
    }

    @Test("A stale server binding never falls back to a display-name match")
    func staleBinding() throws {
        let connector = makeConnector(
            id: id(50), name: "Renamed Server", toolNames: ["renamed__read"]
        )
        let account = makeAccount(
            id: id(51), connectorID: connector.id, displayName: "renamed"
        )
        let binding = makeBinding(accountID: account.id, serverName: "old_server")
        let runtime = liveRuntime(
            serverName: "renamed",
            tools: [.init(name: "renamed__read", serverName: "renamed")]
        )

        let result = facade.project(
            document: makeDocument(connector, account, binding),
            runtime: runtime
        )
        let application = try #require(result.applications.first)

        #expect(application.status == .unavailable)
        #expect(application.candidateToolNames.isEmpty)
        #expect(application.issues.contains(
            .staleMCPBinding(accountID: account.id, serverName: "old_server")
        ))
    }

    @Test("A connected account without a stable binding fails closed")
    func missingBinding() throws {
        let connector = makeConnector(id: id(55), toolNames: ["files__read"])
        let account = makeAccount(id: id(56), connectorID: connector.id)
        let document = YouziDomainDocument(
            connectors: [connector],
            connectionAccounts: [account]
        )

        let result = facade.project(
            document: document,
            runtime: liveRuntime(
                serverName: "files",
                tools: [.init(name: "files__read", serverName: "files")]
            )
        )
        let application = try #require(result.applications.first)
        let issue = YouziConnectorCapabilityIssue.missingBinding(accountID: account.id)

        #expect(application.status == .unavailable)
        #expect(application.candidateToolNames.isEmpty)
        #expect(application.issues.contains(issue))
        #expect(issue.recovery == .reconcileBinding(accountID: account.id))
    }

    @Test("An MCP binding on a non-MCP connector is a typed mismatch")
    func mismatchedConnector() throws {
        let connector = makeConnector(
            id: id(60), adapter: .native, toolNames: ["native__read"]
        )
        let account = makeAccount(id: id(61), connectorID: connector.id)
        let binding = makeBinding(accountID: account.id, serverName: "native")

        let result = facade.project(
            document: makeDocument(connector, account, binding),
            runtime: liveRuntime(serverName: "native", tools: [])
        )
        let application = try #require(result.applications.first)
        let issue = YouziConnectorCapabilityIssue.mismatchedRuntimeBinding(
            accountID: account.id,
            connectorID: connector.id
        )

        #expect(application.status == .error)
        #expect(application.candidateToolNames.isEmpty)
        #expect(application.issues.contains(issue))
        #expect(issue.recovery == .openAdvancedConnectorSettings)
    }

    @Test("Duplicate runtime tool identities are reported and excluded")
    func duplicateRuntimeTools() throws {
        let connector = makeConnector(id: id(70), toolNames: ["mail__read"])
        let account = makeAccount(id: id(71), connectorID: connector.id)
        let binding = makeBinding(accountID: account.id, serverName: "mail")
        let runtime = liveRuntime(
            serverName: "mail",
            tools: [
                .init(name: "mail__read", serverName: "mail"),
                .init(name: "mail__read", serverName: "mail"),
            ]
        )

        let result = facade.project(
            document: makeDocument(connector, account, binding),
            runtime: runtime
        )
        let application = try #require(result.applications.first)

        #expect(application.status == .live)
        #expect(application.candidateToolNames.isEmpty)
        #expect(application.tools == [
            .init(name: "mail__read", status: .unavailable)
        ])
        #expect(application.issues.contains(
            .duplicateRuntimeTool(serverName: "mail", toolName: "mail__read")
        ))
    }

    @Test("Duplicate domain identities and orphan bindings are deterministic issues")
    func duplicateDomainRecords() {
        let connector = makeConnector(id: id(80), toolNames: [])
        let duplicateConnector = makeConnector(
            id: connector.id, name: "Duplicate", toolNames: []
        )
        let account = makeAccount(id: id(81), connectorID: connector.id)
        let binding = makeBinding(accountID: account.id, serverName: "duplicate")
        let duplicateBinding = makeBinding(
            accountID: account.id, serverName: "different", revision: 2
        )
        let orphanID = id(82)
        let orphan = makeBinding(accountID: orphanID, serverName: "orphan")
        let document = YouziDomainDocument(
            connectors: [duplicateConnector, connector],
            connectionAccounts: [account],
            connectorBindings: [duplicateBinding, binding, orphan]
        )

        let result = facade.project(
            document: document,
            runtime: .init(connectorsEnabled: true)
        )

        #expect(result.applications.count == 1)
        #expect(result.applications[0].status == .error)
        #expect(result.issues.contains(
            .duplicateRecord(kind: .connector, id: connector.id)
        ))
        #expect(result.issues.contains(
            .duplicateRecord(kind: .connectorBinding, id: account.id)
        ))
        #expect(result.issues.contains(.orphanBinding(accountID: orphanID)))
    }

    @Test("Credentials and raw domain errors never enter the projection")
    func redaction() throws {
        let secret = "WS15_DO_NOT_EXPOSE_SECRET"
        let connector = makeConnector(id: id(90), toolNames: ["safe__read"])
        var account = makeAccount(
            id: id(91),
            connectorID: connector.id,
            credentialReference: secret
        )
        account.lastErrorSummary = "raw-error-\(secret)"
        let binding = makeBinding(accountID: account.id, serverName: "safe")

        let result = facade.project(
            document: makeDocument(connector, account, binding),
            runtime: liveRuntime(
                serverName: "safe",
                tools: [.init(name: "safe__read", serverName: "safe")]
            )
        )
        let reflected = String(reflecting: result)
        let application = try #require(result.applications.first)

        #expect(application.candidateToolNames == ["safe__read"])
        #expect(!reflected.contains(secret))
        #expect(!reflected.contains("raw-error"))
    }

    @Test("Shuffled domain and runtime arrays produce byte-stable output")
    func deterministicUnderShuffledInput() {
        let connectorA = makeConnector(id: id(100), toolNames: ["a__two", "a__one"])
        let connectorB = makeConnector(id: id(101), toolNames: ["b__one"])
        let accountA = makeAccount(id: id(102), connectorID: connectorA.id)
        let accountB = makeAccount(id: id(103), connectorID: connectorB.id)
        let bindingA = makeBinding(accountID: accountA.id, serverName: "a")
        let bindingB = makeBinding(accountID: accountB.id, serverName: "b")
        let firstDocument = YouziDomainDocument(
            connectors: [connectorB, connectorA],
            connectionAccounts: [accountB, accountA],
            connectorBindings: [bindingB, bindingA]
        )
        let secondDocument = YouziDomainDocument(
            connectors: [connectorA, connectorB],
            connectionAccounts: [accountA, accountB],
            connectorBindings: [bindingA, bindingB]
        )
        let firstRuntime = YouziMCPRuntimeSnapshot(
            connectorsEnabled: true,
            configuredServers: [.init(name: "b"), .init(name: "a")],
            catalogState: .ready,
            liveServers: [
                .init(name: "b", state: .connected),
                .init(name: "a", state: .connected),
            ],
            tools: [
                .init(name: "b__one", serverName: "b"),
                .init(name: "a__two", serverName: "a"),
                .init(name: "a__one", serverName: "a"),
            ]
        )
        let secondRuntime = YouziMCPRuntimeSnapshot(
            connectorsEnabled: true,
            configuredServers: [.init(name: "a"), .init(name: "b")],
            catalogState: .ready,
            liveServers: [
                .init(name: "a", state: .connected),
                .init(name: "b", state: .connected),
            ],
            tools: [
                .init(name: "a__one", serverName: "a"),
                .init(name: "a__two", serverName: "a"),
                .init(name: "b__one", serverName: "b"),
            ]
        )

        #expect(
            facade.project(document: firstDocument, runtime: firstRuntime)
                == facade.project(document: secondDocument, runtime: secondRuntime)
        )
    }

    @Test("Sanitized failures never carry raw MCP error details")
    func sanitizedRuntimeFailure() throws {
        let secret = "RAW_RUNTIME_BODY_MUST_NOT_ESCAPE"
        let connector = makeConnector(id: id(110), toolNames: ["safe__read"])
        var account = makeAccount(id: id(111), connectorID: connector.id)
        account.lastErrorSummary = secret
        let binding = makeBinding(accountID: account.id, serverName: "safe")
        let result = facade.project(
            document: makeDocument(connector, account, binding),
            runtime: .init(
                connectorsEnabled: true,
                configurationState: .unreadable,
                configuredServers: [.init(name: "safe")],
                catalogState: .failed
            )
        )
        let application = try #require(result.applications.first)

        #expect(application.status == .error)
        #expect(application.issues == [.configurationUnreadable])
        #expect(!String(reflecting: result).contains(secret))
    }

    @Test("Capturing real MCP owners strips command arguments and environment values")
    @MainActor
    func productionSnapshotRedaction() throws {
        let secret = "MCP_CONFIG_SECRET_MUST_NOT_ESCAPE"
        let suiteName = "YouziConnectorCapabilityFacadeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: MCPConfigStore.enabledKey)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "youzi-ws15-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let configURL = directory.appendingPathComponent("mcp.json")
        let data = try MCPConfigStore.encode([
            MCPServerConfig(
                name: "safe",
                command: "npx",
                args: ["--token", secret],
                env: ["TOKEN": secret]
            )
        ])
        try data.write(to: configURL)

        let configStore = MCPConfigStore(defaults: defaults, fileURL: configURL)
        let catalog = MCPCatalog(endpoint: { nil })
        let approval = MCPToolApprovalStore(defaults: defaults)
        let registry = MCPToolRegistry(
            catalog: catalog,
            approval: approval,
            defaults: defaults
        )
        let snapshot = YouziMCPRuntimeSnapshot.capture(
            configStore: configStore,
            catalog: catalog,
            registry: registry
        )
        let reflected = String(reflecting: snapshot)

        #expect(snapshot.connectorsEnabled)
        #expect(snapshot.configuredServers == [.init(name: "safe")])
        #expect(!reflected.contains(secret))
        #expect(!reflected.contains("--token"))
        #expect(!reflected.contains("TOKEN"))
    }

    // MARK: - Fixtures

    private func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }

    private func source(identifier: String) -> YouziManifestSource {
        YouziManifestSource(
            kind: .userCreated,
            identifier: identifier,
            version: "1.0.0"
        )
    }

    private func makeConnector(
        id connectorID: UUID,
        name: String = "Connector",
        adapter: YouziConnectorAdapter = .mcp,
        toolNames: [String],
        state: YouziRecordState = .active
    ) -> YouziConnector {
        YouziConnector(
            id: connectorID,
            name: name,
            summary: "A connector",
            adapter: adapter,
            authentication: .custom,
            toolNames: toolNames,
            source: source(identifier: "youzi.test.\(connectorID.uuidString)"),
            state: state
        )
    }

    private func makeAccount(
        id accountID: UUID,
        connectorID: UUID,
        displayName: String = "Account",
        credentialReference: String? = nil,
        state: YouziConnectionState = .connected
    ) -> YouziConnectionAccount {
        YouziConnectionAccount(
            id: accountID,
            connectorID: connectorID,
            displayName: displayName,
            credentialReference: credentialReference,
            state: state
        )
    }

    private func makeBinding(
        accountID: UUID,
        serverName: String,
        revision: Int = 1
    ) -> YouziConnectorBinding {
        YouziConnectorBinding(
            id: accountID,
            runtime: .mcp(serverName: serverName),
            configurationRevision: revision
        )
    }

    private func makeDocument(
        _ connector: YouziConnector,
        _ account: YouziConnectionAccount,
        _ binding: YouziConnectorBinding
    ) -> YouziDomainDocument {
        YouziDomainDocument(
            connectors: [connector],
            connectionAccounts: [account],
            connectorBindings: [binding]
        )
    }

    private func liveRuntime(
        serverName: String,
        tools: [YouziMCPRuntimeSnapshot.Tool]
    ) -> YouziMCPRuntimeSnapshot {
        YouziMCPRuntimeSnapshot(
            connectorsEnabled: true,
            configuredServers: [.init(name: serverName)],
            catalogState: .ready,
            liveServers: [.init(name: serverName, state: .connected)],
            tools: tools
        )
    }
}
