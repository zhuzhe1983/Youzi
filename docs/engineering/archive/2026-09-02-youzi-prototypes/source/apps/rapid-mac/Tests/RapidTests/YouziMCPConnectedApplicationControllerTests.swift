import Foundation
import Testing
@testable import Rapid

@MainActor
@Suite("Youzi MCP connected-application reconciliation and actions")
struct YouziMCPConnectedApplicationControllerTests {
    private let date = Date(timeIntervalSinceReferenceDate: 12_345)

    @Test("New live server creates one stable application and repeated inspection is idempotent")
    func newLiveAndIdempotent() async throws {
        let fixture = makeFixture(runtime: liveRuntime("calendar", tools: ["calendar__read"]))

        let first = await fixture.controller.inspect()
        let firstDocument = fixture.domain.document
        let account = try #require(firstDocument.connectionAccounts.first)

        #expect(first.outcome == .completed)
        #expect(firstDocument.connectors.count == 1)
        #expect(firstDocument.connectorBindings.count == 1)
        #expect(firstDocument.connectors[0].toolNames == ["calendar__read"])
        #expect(account.state == .connected)
        #expect(account.lastErrorSummary == nil)
        #expect(firstDocument.connectorBindings[0].configurationRevision == 1)

        let second = await fixture.controller.inspect()
        #expect(second.outcome == .completed)
        #expect(fixture.domain.document.connectors.map(\.id) == firstDocument.connectors.map(\.id))
        #expect(fixture.domain.document.connectionAccounts.map(\.id) == [account.id])
        #expect(fixture.domain.createCount == 1)
    }

    @Test("Disabled operational state creates an honestly disabled account")
    func disabled() async throws {
        let runtime = YouziMCPRuntimeSnapshot(
            connectorsEnabled: false,
            configuredServers: [.init(name: "notes", isEnabled: true)]
        )
        let fixture = makeFixture(runtime: runtime)

        _ = await fixture.controller.inspect()
        let account = try #require(fixture.domain.document.connectionAccounts.first)

        #expect(account.state == .disabled)
        #expect(account.recoveryCode == nil)
    }

    @Test("Missing stale binding remains needs-attention and never guesses a similar rename")
    func staleMissingNoGuess() async throws {
        let existing = boundDocument(serverName: "old_notes", displayName: "renamed_notes")
        let oldAccountID = try #require(existing.connectionAccounts.first?.id)
        let fixture = makeFixture(
            document: existing,
            runtime: liveRuntime("renamed_notes", tools: ["renamed_notes__read"])
        )

        let result = await fixture.controller.inspect()
        let stale = try #require(
            fixture.domain.document.connectionAccounts.first(where: { $0.id == oldAccountID })
        )

        #expect(result.outcome == .needsAttention)
        #expect(result.issues.contains(
            .missingBoundServer(accountID: oldAccountID, serverName: "old_notes")
        ))
        #expect(stale.state == .needsAttention)
        #expect(stale.recoveryCode == .connectorUnconfigured)
        #expect(fixture.domain.document.connectionAccounts.count == 2)
        #expect(fixture.domain.document.connectorBindings.contains {
            if case .mcp(serverName: "old_notes") = $0.runtime { return true }
            return false
        })
        #expect(fixture.domain.document.connectorBindings.contains {
            if case .mcp(serverName: "renamed_notes") = $0.runtime { return true }
            return false
        })
    }

    @Test("Duplicate runtime identities fail closed without creating records")
    func duplicates() {
        let reconciler = fixedReconciler()
        let duplicateConfig = YouziMCPRuntimeSnapshot(
            connectorsEnabled: true,
            configuredServers: [.init(name: "files"), .init(name: "files")]
        )
        let duplicateConfigPlan = reconciler.plan(
            document: .empty, runtime: duplicateConfig, at: date
        )
        #expect(duplicateConfigPlan.operations.isEmpty)
        #expect(duplicateConfigPlan.issues == [.duplicateConfiguredServer(name: "files")])

        let document = boundDocument(serverName: "files")
        let originalAccount = document.connectionAccounts[0]
        var duplicated = document
        let secondConnector = makeConnector(id: id(91), name: "Second")
        let secondAccount = YouziConnectionAccount(
            id: id(92), connectorID: secondConnector.id, displayName: "Second",
            state: .connected, createdAt: date, updatedAt: date
        )
        duplicated.connectors.append(secondConnector)
        duplicated.connectionAccounts.append(secondAccount)
        duplicated.connectorBindings.append(
            .init(id: secondAccount.id, runtime: .mcp(serverName: "files"),
                  createdAt: date, updatedAt: date)
        )
        let duplicateBindingPlan = reconciler.plan(
            document: duplicated,
            runtime: liveRuntime("files"),
            at: date
        )
        #expect(duplicateBindingPlan.issues.contains(.duplicateBoundServer(serverName: "files")))
        #expect(!duplicateBindingPlan.operations.contains {
            if case .create = $0 { return true }
            return false
        })
        #expect(duplicated.connectionAccounts.contains { $0.id == originalAccount.id })
    }

    @Test("Account missing an exact binding is not rebound by its display name")
    func missingBinding() async throws {
        let connector = makeConnector(id: id(1), name: "notes")
        let account = YouziConnectionAccount(
            id: id(2), connectorID: connector.id, displayName: "notes",
            state: .connected, createdAt: date, updatedAt: date
        )
        let fixture = makeFixture(
            document: .init(connectors: [connector], connectionAccounts: [account]),
            runtime: liveRuntime("notes")
        )

        let result = await fixture.controller.inspect()
        let oldAccount = try #require(
            fixture.domain.document.connectionAccounts.first(where: { $0.id == account.id })
        )

        #expect(result.issues.contains(.missingBinding(accountID: account.id)))
        #expect(oldAccount.state == .needsAttention)
        #expect(oldAccount.recoveryCode == .connectorUnconfigured)
        #expect(fixture.domain.document.connectionAccounts.count == 2)
    }

    @Test("Existing configured server imports without rewriting operational configuration")
    func importExisting() async {
        let fixture = makeFixture(runtime: liveRuntime("tasks"))

        let result = await fixture.controller.importConfiguredServer(named: "tasks")

        #expect(result.outcome == .completed)
        #expect(fixture.runtime.mutations.isEmpty)
        #expect(fixture.domain.document.connectionAccounts.count == 1)
    }

    @Test("Create writes MCP first and a failed MCP write leaves domain untouched")
    func createOrderingAndMCPFailure() async {
        let trace = ActionTrace()
        let fixture = makeFixture(runtime: .init(connectorsEnabled: true), trace: trace)
        let config = MCPServerConfig(name: "create", command: "fixture")

        _ = await fixture.controller.createOrImport(config)
        #expect(trace.events.first == "mcp.upsert")
        #expect(trace.events.contains("domain.create"))

        let failing = makeFixture(runtime: .init(connectorsEnabled: true))
        failing.runtime.failWrites = true
        let failed = await failing.controller.createOrImport(config)
        #expect(failed.failure == .operationalWriteFailed)
        #expect(failing.domain.document == .empty)
    }

    @Test("A post-MCP domain failure keeps operational truth and requests reconciliation")
    func domainFailureAfterMCPWrite() async {
        let fixture = makeFixture(runtime: .init(connectorsEnabled: true))
        fixture.domain.failCreates = true

        let result = await fixture.controller.createOrImport(
            MCPServerConfig(name: "durable", command: "fixture")
        )

        #expect(result.outcome == .needsAttention)
        #expect(result.failure == .domainWriteFailed)
        #expect(result.recovery == .retryInspection)
        #expect(fixture.runtime.snapshotValue.configuredServers.contains { $0.name == "durable" })
        #expect(fixture.domain.document.connectionAccounts.isEmpty)
    }

    @Test("Pause and forget MCP write failures do not mutate domain or Keychain")
    func lifecycleMCPWriteFailures() async throws {
        let document = boundDocument(serverName: "safe")
        let accountID = try #require(document.connectionAccounts.first?.id)
        let pauseFixture = makeFixture(document: document, runtime: liveRuntime("safe"))
        pauseFixture.runtime.failWrites = true

        let pause = await pauseFixture.controller.pause(accountID: accountID)
        #expect(pause.failure == .operationalWriteFailed)
        #expect(pauseFixture.domain.document.connectionAccounts[0].state == .connected)

        let reference = YouziKeychainConnectorCredentialVault.reference(for: accountID)
        let credentialDocument = boundDocument(
            serverName: "safe", credentialReference: reference
        )
        let vault = ConnectorVaultSpy(reference: reference)
        let forgetFixture = makeFixture(
            document: credentialDocument, runtime: liveRuntime("safe"), vault: vault
        )
        forgetFixture.runtime.failWrites = true

        let forget = await forgetFixture.controller.forget(accountID: accountID)
        #expect(forget.failure == .operationalWriteFailed)
        #expect(forgetFixture.domain.document.connectionAccounts[0].credentialReference == reference)
        #expect(vault.reference == reference)
    }

    @Test("Exact rename updates the binding once and never joins by display name")
    func exactRename() async throws {
        let document = boundDocument(serverName: "before")
        let accountID = try #require(document.connectionAccounts.first?.id)
        let fixture = makeFixture(document: document, runtime: liveRuntime("before"))
        let original = MCPServerConfig(name: "before", command: "fixture")
        var updated = original
        updated.name = "after"

        let result = await fixture.controller.update(
            accountID: accountID, original: original, updated: updated
        )
        let binding = try #require(fixture.domain.document.connectorBindings.first)

        #expect(result.failure == nil)
        #expect(binding.runtime == .mcp(serverName: "after"))
        #expect(binding.configurationRevision == 2)
        #expect(fixture.runtime.mutations.contains(.upsert(name: "after", replacing: "before")))
    }

    @Test("Rename CAS conflict retries the exact account and never creates a duplicate")
    func exactRenameRetriesFreshBindingRevision() async throws {
        let document = boundDocument(serverName: "before")
        let accountID = try #require(document.connectionAccounts.first?.id)
        let fixture = makeFixture(document: document, runtime: liveRuntime("before"))
        fixture.domain.bindingConflictsRemaining = 1
        let original = MCPServerConfig(name: "before", command: "private-command-a")
        var updated = original
        updated.name = "after"
        updated.command = "private-command-b"

        let result = await fixture.controller.update(
            accountID: accountID,
            original: original,
            updated: updated
        )
        let binding = try #require(fixture.domain.document.connectorBindings.first)
        let resultText = String(reflecting: result)

        #expect(result.outcome == .completed)
        #expect(result.failure == nil)
        #expect(fixture.domain.bindingExpectedRevisions == [1, 2])
        #expect(binding.runtime == .mcp(serverName: "after"))
        #expect(binding.configurationRevision == 3)
        #expect(fixture.domain.document.connectionAccounts.map(\.id) == [accountID])
        #expect(fixture.domain.document.connectorBindings.map(\.id) == [accountID])
        #expect(fixture.domain.createCount == 0)
        #expect(!resultText.contains("private-command-a"))
        #expect(!resultText.contains("private-command-b"))
    }

    @Test("Rename retry conflict stays typed and never falls into discovery")
    func exactRenameRetryFailureStaysTyped() async throws {
        let document = boundDocument(serverName: "before")
        let accountID = try #require(document.connectionAccounts.first?.id)
        let fixture = makeFixture(document: document, runtime: liveRuntime("before"))
        fixture.domain.bindingConflictsRemaining = 2
        let original = MCPServerConfig(name: "before", command: "private-command-a")
        var updated = original
        updated.name = "after"

        let result = await fixture.controller.update(
            accountID: accountID,
            original: original,
            updated: updated
        )

        #expect(result.outcome == .failed)
        #expect(result.failure == .domainWriteFailed)
        #expect(result.recovery == .reconcileAccount(accountID))
        #expect(fixture.domain.bindingExpectedRevisions == [1, 2])
        #expect(fixture.domain.document.connectionAccounts.map(\.id) == [accountID])
        #expect(fixture.domain.document.connectorBindings.map(\.id) == [accountID])
        #expect(fixture.domain.createCount == 0)
        #expect(fixture.runtime.snapshotValue.configuredServers.map(\.name) == ["after"])
        #expect(!String(reflecting: result).contains("private-command-a"))
    }

    @Test("Same-name execution identity edit bumps the secret-free domain revision")
    func executionIdentityEdit() async throws {
        let document = boundDocument(serverName: "local")
        let accountID = try #require(document.connectionAccounts.first?.id)
        let fixture = makeFixture(document: document, runtime: liveRuntime("local"))
        let original = MCPServerConfig(name: "local", command: "fixture-a")
        let updated = MCPServerConfig(name: "local", command: "fixture-b")

        _ = await fixture.controller.update(
            accountID: accountID, original: original, updated: updated
        )

        #expect(fixture.domain.document.connectorBindings[0].configurationRevision == 2)
        #expect(fixture.domain.executionIdentityInvalidations == 1)
    }

    @Test("Pause and resume preserve operational-first fail-closed ordering")
    func pauseResume() async throws {
        let trace = ActionTrace()
        let document = boundDocument(serverName: "calendar")
        let accountID = try #require(document.connectionAccounts.first?.id)
        let fixture = makeFixture(
            document: document, runtime: liveRuntime("calendar"), trace: trace
        )

        _ = await fixture.controller.pause(accountID: accountID)
        #expect(Array(trace.events.prefix(2)) == ["mcp.disable", "domain.disable"])
        #expect(fixture.domain.document.connectionAccounts[0].state == .disabled)

        trace.events = []
        _ = await fixture.controller.resume(accountID: accountID)
        #expect(Array(trace.events.prefix(2)) == ["mcp.enable", "domain.enable"])
        #expect(fixture.domain.document.connectionAccounts[0].state == .connected)
    }

    @Test("Disconnect preserves config, account, and exact binding across later inspection")
    func disconnect() async throws {
        let document = boundDocument(serverName: "notes")
        let accountID = try #require(document.connectionAccounts.first?.id)
        let fixture = makeFixture(document: document, runtime: liveRuntime("notes"))

        let result = fixture.controller.disconnect(accountID: accountID)
        _ = await fixture.controller.inspect()

        #expect(result.outcome == .completed)
        #expect(fixture.runtime.mutations.isEmpty)
        #expect(fixture.domain.document.connectionAccounts[0].state == .notConnected)
        #expect(fixture.domain.document.connectorBindings.count == 1)
    }

    @Test("Forget removes MCP first then performs credential cleanup and explicit domain deletion")
    func forget() async throws {
        let trace = ActionTrace()
        let reference = YouziKeychainConnectorCredentialVault.reference(for: id(2))
        let document = boundDocument(serverName: "files", credentialReference: reference)
        let accountID = try #require(document.connectionAccounts.first?.id)
        let vault = ConnectorVaultSpy(reference: reference)
        let fixture = makeFixture(
            document: document, runtime: liveRuntime("files"), vault: vault, trace: trace
        )

        let result = await fixture.controller.forget(accountID: accountID)

        #expect(result.outcome == .completed)
        #expect(trace.events == [
            "mcp.remove", "domain.cleanup.begin", "vault.delete",
            "domain.cleanup.finish", "domain.forget", "mcp.reload",
        ])
        #expect(fixture.domain.document.connectionAccounts.isEmpty)
        #expect(fixture.domain.document.connectorBindings.isEmpty)
    }

    @Test("Keychain failure leaves a cleanup-pending account and never claims forget succeeded")
    func keychainFailure() async throws {
        let reference = YouziKeychainConnectorCredentialVault.reference(for: id(2))
        let document = boundDocument(serverName: "files", credentialReference: reference)
        let accountID = try #require(document.connectionAccounts.first?.id)
        let vault = ConnectorVaultSpy(reference: reference)
        vault.failDelete = true
        let fixture = makeFixture(document: document, runtime: liveRuntime("files"), vault: vault)

        let result = await fixture.controller.forget(accountID: accountID)
        let account = try #require(fixture.domain.document.connectionAccounts.first)

        #expect(result.failure == .credentialCleanupFailed)
        #expect(result.recovery == .retryCredentialCleanup(accountID))
        #expect(account.recoveryCode == .credentialCleanupPending)
        #expect(account.credentialReference == reference)
    }

    @Test("Referenced account is rejected before destructive operational cleanup")
    func referencedForget() async throws {
        var document = boundDocument(serverName: "files")
        let accountID = try #require(document.connectionAccounts.first?.id)
        document.tasks = [
            YouziTask(
                id: id(80),
                title: "History",
                request: "Keep the exact connection history",
                connectionAccountIDs: [accountID],
                connectionAccountSelectionIntent: .explicit,
                createdAt: date,
                updatedAt: date
            )
        ]
        let fixture = makeFixture(document: document, runtime: liveRuntime("files"))

        let result = await fixture.controller.forget(accountID: accountID)

        #expect(result.failure == .accountStillReferenced)
        #expect(result.recovery == .removeAccountReferences(accountID))
        #expect(fixture.domain.document.connectionAccounts.contains { $0.id == accountID })
        #expect(fixture.domain.document.connectionAccounts.first?.state == .connected)
        #expect(fixture.runtime.mutations.isEmpty)
    }

    @Test("Raw operational failures and execution configuration never enter results or domain JSON")
    func redaction() async throws {
        let fixture = makeFixture(runtime: .init(connectorsEnabled: true))
        fixture.runtime.failWrites = true
        fixture.runtime.failurePayload = "private-runtime-detail"

        let result = await fixture.controller.createOrImport(
            MCPServerConfig(name: "safe", command: "private-command-detail")
        )
        let resultText = String(reflecting: result)
        let domainData = try JSONEncoder().encode(fixture.domain.document)
        let domainText = String(decoding: domainData, as: UTF8.self)

        #expect(!resultText.contains("private-runtime-detail"))
        #expect(!resultText.contains("private-command-detail"))
        #expect(!domainText.contains("private-runtime-detail"))
        #expect(!domainText.contains("private-command-detail"))
        #expect(!domainText.contains("execution" + "Fingerprint"))
    }

    // MARK: - Fixtures

    private func makeFixture(
        document: YouziDomainDocument = .empty,
        runtime snapshot: YouziMCPRuntimeSnapshot,
        vault: ConnectorVaultSpy = ConnectorVaultSpy(),
        trace: ActionTrace = ActionTrace()
    ) -> Fixture {
        let runtime = RuntimeSpy(snapshot: snapshot, trace: trace)
        let domain = DomainSpy(document: document, trace: trace)
        let controller = YouziMCPConnectedApplicationController(
            runtime: runtime,
            domain: domain,
            vault: vault,
            reconciler: fixedReconciler(),
            now: { date }
        )
        vault.trace = trace
        return Fixture(controller: controller, runtime: runtime, domain: domain, vault: vault)
    }

    private func fixedReconciler() -> YouziMCPConnectedApplicationReconciler {
        let source = LockedIDSource(ids: [id(101), id(102), id(103), id(104)])
        return .init(makeUUID: { source.next() })
    }

    private func liveRuntime(
        _ serverName: String,
        tools: [String] = []
    ) -> YouziMCPRuntimeSnapshot {
        .init(
            connectorsEnabled: true,
            configuredServers: [.init(name: serverName)],
            catalogState: .ready,
            liveServers: [.init(name: serverName, state: .connected)],
            tools: tools.map { .init(name: $0, serverName: serverName) }
        )
    }

    private func boundDocument(
        serverName: String,
        displayName: String? = nil,
        credentialReference: String? = nil
    ) -> YouziDomainDocument {
        let connector = makeConnector(id: id(1), name: displayName ?? serverName)
        let account = YouziConnectionAccount(
            id: id(2),
            connectorID: connector.id,
            displayName: displayName ?? serverName,
            credentialReference: credentialReference,
            state: .connected,
            createdAt: date,
            updatedAt: date
        )
        return .init(
            connectors: [connector],
            connectionAccounts: [account],
            connectorBindings: [
                .init(id: account.id, runtime: .mcp(serverName: serverName),
                      createdAt: date, updatedAt: date)
            ]
        )
    }

    private func makeConnector(id: UUID, name: String) -> YouziConnector {
        .init(
            id: id,
            name: name,
            summary: "fixture",
            adapter: .mcp,
            authentication: .custom,
            source: .init(kind: .userCreated, identifier: "fixture.\(id)", version: "1"),
            createdAt: date,
            updatedAt: date
        )
    }

    private func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }

    private struct Fixture {
        let controller: YouziMCPConnectedApplicationController
        let runtime: RuntimeSpy
        let domain: DomainSpy
        let vault: ConnectorVaultSpy
    }
}

private enum RuntimeMutation: Equatable {
    case upsert(name: String, replacing: String?)
    case enabled(name: String, value: Bool)
    case remove(name: String)
}

private enum FixtureFailure: Error {
    case operation(String)
}

private final class ActionTrace: @unchecked Sendable {
    var events: [String] = []
}

@MainActor
private final class RuntimeSpy: YouziMCPRuntimeControlling {
    var snapshotValue: YouziMCPRuntimeSnapshot
    var mutations: [RuntimeMutation] = []
    var failWrites = false
    var failurePayload = "fixture failure"
    let trace: ActionTrace

    init(snapshot: YouziMCPRuntimeSnapshot, trace: ActionTrace) {
        self.snapshotValue = snapshot
        self.trace = trace
    }

    func snapshot() -> YouziMCPRuntimeSnapshot { snapshotValue }

    func upsert(_ server: MCPServerConfig, replacing originalName: String?) throws {
        trace.events.append("mcp.upsert")
        guard !failWrites else { throw FixtureFailure.operation(failurePayload) }
        mutations.append(.upsert(name: server.name, replacing: originalName))
        var configured = snapshotValue.configuredServers
        if let originalName {
            configured.removeAll { $0.name == originalName }
        }
        configured.removeAll { $0.name == server.name }
        configured.append(.init(name: server.name, isEnabled: server.enabled))
        let renamedFrom = originalName
        snapshotValue = .init(
            connectorsEnabled: snapshotValue.connectorsEnabled,
            configurationState: snapshotValue.configurationState,
            configuredServers: configured,
            catalogState: snapshotValue.catalogState,
            liveServers: snapshotValue.liveServers.map {
                guard $0.name == renamedFrom else { return $0 }
                return .init(name: server.name, state: $0.state)
            },
            tools: snapshotValue.tools.map {
                guard $0.serverName == renamedFrom else { return $0 }
                return .init(name: $0.name, serverName: server.name, isEnabled: $0.isEnabled)
            }
        )
    }

    func setServerEnabled(_ serverName: String, _ enabled: Bool) throws {
        trace.events.append(enabled ? "mcp.enable" : "mcp.disable")
        guard !failWrites else { throw FixtureFailure.operation(failurePayload) }
        mutations.append(.enabled(name: serverName, value: enabled))
        snapshotValue = .init(
            connectorsEnabled: snapshotValue.connectorsEnabled,
            configurationState: snapshotValue.configurationState,
            configuredServers: snapshotValue.configuredServers.map {
                $0.name == serverName ? .init(name: $0.name, isEnabled: enabled) : $0
            },
            catalogState: snapshotValue.catalogState,
            liveServers: snapshotValue.liveServers,
            tools: snapshotValue.tools
        )
    }

    func removeServer(named serverName: String) throws {
        trace.events.append("mcp.remove")
        guard !failWrites else { throw FixtureFailure.operation(failurePayload) }
        mutations.append(.remove(name: serverName))
        snapshotValue = .init(
            connectorsEnabled: snapshotValue.connectorsEnabled,
            configurationState: snapshotValue.configurationState,
            configuredServers: snapshotValue.configuredServers.filter { $0.name != serverName },
            catalogState: snapshotValue.catalogState,
            liveServers: snapshotValue.liveServers.filter { $0.name != serverName },
            tools: snapshotValue.tools.filter { $0.serverName != serverName }
        )
    }

    func inspect() async -> YouziMCPRuntimeSnapshot {
        trace.events.append("mcp.inspect")
        return snapshotValue
    }

    func reloadAfterWrite() async -> YouziMCPRuntimeSnapshot {
        trace.events.append("mcp.reload")
        return snapshotValue
    }
}

private final class DomainSpy: YouziMCPConnectedApplicationDomainManaging, @unchecked Sendable {
    var document: YouziDomainDocument
    var createCount = 0
    var executionIdentityInvalidations = 0
    var bindingConflictsRemaining = 0
    var bindingExpectedRevisions: [Int?] = []
    var refuseForgetAsReferenced = false
    var failCreates = false
    let trace: ActionTrace

    init(document: YouziDomainDocument, trace: ActionTrace) {
        self.document = document
        self.trace = trace
    }

    func load() throws -> YouziDomainDocument { document }

    func createConnectorAccount(
        connector: YouziConnector,
        account: YouziConnectionAccount,
        runtime: YouziConnectorRuntimeBinding,
        at date: Date
    ) throws -> YouziDomainDocument {
        trace.events.append("domain.create")
        if failCreates { throw FixtureFailure.operation("domain write failure") }
        createCount += 1
        document.upsert(connector)
        document.upsert(account)
        document.upsert(.init(id: account.id, runtime: runtime, createdAt: date, updatedAt: date))
        return document
    }

    func reconcileMCPAccount(
        id: UUID,
        toolNames: [String],
        state: YouziConnectionState,
        accountRecoveryCode: YouziRecoveryCode?,
        bindingRecoveryCode: YouziRecoveryCode?,
        at date: Date
    ) throws -> YouziDomainDocument {
        guard let accountIndex = document.connectionAccounts.firstIndex(where: { $0.id == id }),
              let bindingIndex = document.connectorBindings.firstIndex(where: { $0.id == id }),
              let connectorIndex = document.connectors.firstIndex(
                where: { $0.id == document.connectionAccounts[accountIndex].connectorID }
              ) else { throw FixtureFailure.operation("missing domain fixture") }
        document.connectors[connectorIndex].toolNames = Array(Set(toolNames)).sorted()
        document.connectionAccounts[accountIndex].state = state
        document.connectionAccounts[accountIndex].recoveryCode = accountRecoveryCode
        document.connectionAccounts[accountIndex].lastCheckedAt = date
        document.connectorBindings[bindingIndex].recoveryCode = bindingRecoveryCode
        return document
    }

    func reconcileAccountHealth(
        id: UUID,
        state: YouziConnectionState,
        recoveryCode: YouziRecoveryCode?,
        at date: Date
    ) throws -> YouziDomainDocument {
        guard let index = document.connectionAccounts.firstIndex(where: { $0.id == id }) else {
            throw FixtureFailure.operation("missing domain fixture")
        }
        document.connectionAccounts[index].state = state
        document.connectionAccounts[index].recoveryCode = recoveryCode
        document.connectionAccounts[index].lastCheckedAt = date
        return document
    }

    func setAccountEnabled(id: UUID, enabled: Bool, at date: Date) throws -> YouziDomainDocument {
        trace.events.append(enabled ? "domain.enable" : "domain.disable")
        guard let index = document.connectionAccounts.firstIndex(where: { $0.id == id }) else {
            throw FixtureFailure.operation("missing domain fixture")
        }
        document.connectionAccounts[index].state = enabled ? .notConnected : .disabled
        return document
    }

    func reconcileBinding(
        accountID: UUID,
        runtime: YouziConnectorRuntimeBinding,
        expectedRevision: Int?,
        at date: Date
    ) throws -> YouziDomainDocument {
        bindingExpectedRevisions.append(expectedRevision)
        guard let index = document.connectorBindings.firstIndex(where: { $0.id == accountID }) else {
            throw YouziCapabilityRepositoryError.bindingNotFound(accountID)
        }
        if bindingConflictsRemaining > 0 {
            bindingConflictsRemaining -= 1
            document.connectorBindings[index].configurationRevision += 1
            throw YouziCapabilityRepositoryError.bindingRevisionConflict(
                expected: expectedRevision,
                actual: document.connectorBindings[index].configurationRevision
            )
        }
        guard document.connectorBindings[index].configurationRevision == expectedRevision else {
            throw YouziCapabilityRepositoryError.bindingRevisionConflict(
                expected: expectedRevision,
                actual: document.connectorBindings[index].configurationRevision
            )
        }
        if document.connectorBindings[index].runtime != runtime {
            document.connectorBindings[index].runtime = runtime
            document.connectorBindings[index].configurationRevision += 1
        }
        return document
    }

    func invalidateBindingExecutionIdentity(
        accountID: UUID,
        expectedRevision: Int,
        at date: Date
    ) throws -> YouziDomainDocument {
        guard let index = document.connectorBindings.firstIndex(where: { $0.id == accountID }),
              document.connectorBindings[index].configurationRevision == expectedRevision else {
            throw FixtureFailure.operation("binding conflict")
        }
        document.connectorBindings[index].configurationRevision += 1
        executionIdentityInvalidations += 1
        return document
    }

    func disconnectAccount(id: UUID, at date: Date) throws -> YouziDomainDocument {
        trace.events.append("domain.disconnect")
        guard let index = document.connectionAccounts.firstIndex(where: { $0.id == id }) else {
            throw FixtureFailure.operation("missing domain fixture")
        }
        document.connectionAccounts[index].state = .notConnected
        document.connectionAccounts[index].recoveryCode = nil
        return document
    }

    func beginCredentialCleanup(id: UUID, at date: Date) throws -> YouziDomainDocument {
        trace.events.append("domain.cleanup.begin")
        guard let index = document.connectionAccounts.firstIndex(where: { $0.id == id }) else {
            throw FixtureFailure.operation("missing domain fixture")
        }
        document.connectionAccounts[index].state = .needsAttention
        document.connectionAccounts[index].recoveryCode = .credentialCleanupPending
        return document
    }

    func finishCredentialCleanup(id: UUID, at date: Date) throws -> YouziDomainDocument {
        trace.events.append("domain.cleanup.finish")
        guard let index = document.connectionAccounts.firstIndex(where: { $0.id == id }) else {
            throw FixtureFailure.operation("missing domain fixture")
        }
        document.connectionAccounts[index].credentialReference = nil
        document.connectionAccounts[index].state = .notConnected
        document.connectionAccounts[index].recoveryCode = nil
        return document
    }

    func forgetAccount(id: UUID, at date: Date) throws -> YouziDomainDocument {
        trace.events.append("domain.forget")
        if refuseForgetAsReferenced {
            throw YouziCapabilityRepositoryError.accountStillReferenced(id)
        }
        document.connectionAccounts.removeAll { $0.id == id }
        document.connectorBindings.removeAll { $0.id == id }
        return document
    }
}

private final class ConnectorVaultSpy: YouziConnectorCredentialVault, @unchecked Sendable {
    var reference: String?
    var failDelete = false
    var trace: ActionTrace?

    init(reference: String? = nil) {
        self.reference = reference
    }

    func store(_ secret: String, for accountID: UUID) throws -> String {
        let reference = YouziKeychainConnectorCredentialVault.reference(for: accountID)
        self.reference = reference
        return reference
    }

    func read(reference: String, for accountID: UUID) -> KeychainReadResult {
        self.reference == reference ? .found("fixture") : .missing
    }

    func delete(reference: String, for accountID: UUID) throws {
        trace?.events.append("vault.delete")
        guard !failDelete else { throw FixtureFailure.operation("vault failure") }
        self.reference = nil
    }
}

private final class LockedIDSource: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [UUID]

    init(ids: [UUID]) { self.ids = ids }

    func next() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        return ids.isEmpty
            ? UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!
            : ids.removeFirst()
    }
}
