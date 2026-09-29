import Foundation
import Testing
@testable import Rapid

@Suite("Youzi capability repository — atomic lifecycle")
struct YouziCapabilityRepositoryTests {
    @Test("Catalog seeds skills and packages atomically with exact parity")
    func seedIncludesPackages() throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let date = Date(timeIntervalSinceReferenceDate: 100)
        let skillID = UUID()
        let helperID = UUID()
        let skill = YouziSkill(
            id: skillID,
            name: "Planning",
            summary: "fixture",
            packageVersion: "1",
            source: .init(kind: .builtIn, identifier: "builtin.planning", version: "1"),
            lastUsedAt: date.addingTimeInterval(-1),
            createdAt: date,
            updatedAt: date
        )
        let helper = YouziHelper(
            id: helperID,
            name: "Planner",
            summary: "fixture",
            systemInstructions: "Plan",
            recommendedSkillIDs: [skillID],
            source: .init(kind: .builtIn, identifier: "builtin.planner", version: "1"),
            createdAt: date,
            updatedAt: date
        )
        let package = YouziSkillPackageRecord(
            id: skillID,
            location: .bundled(resourcePath: "YouziSkills/planning"),
            packageVersion: "1",
            contentSHA256: String(repeating: "a", count: 64),
            installedAt: date,
            verifiedAt: date,
            updatedAt: date
        )

        let seeded = try fixture.repository.seedCatalog(
            YouziCapabilitySeed(helpers: [helper], skills: [skill], skillPackages: [package]),
            at: date
        )
        #expect(seeded.skills.map(\.id) == [skillID])
        #expect(seeded.skillPackages.map(\.id) == [skillID])

        let stableBytes = try Data(contentsOf: fixture.fileURL)
        let idempotent = try fixture.repository.seedCatalog(
            YouziCapabilitySeed(helpers: [helper], skills: [skill], skillPackages: [package]),
            at: date.addingTimeInterval(10)
        )
        #expect(idempotent.skillPackages[0].updatedAt == date)
        #expect(try Data(contentsOf: fixture.fileURL) == stableBytes)

        _ = try fixture.repository.setHelperFavorite(
            id: helperID, favorite: true, at: date.addingTimeInterval(11)
        )
        _ = try fixture.repository.setHelperState(
            id: helperID, state: .disabled, at: date.addingTimeInterval(12)
        )
        _ = try fixture.repository.setSkillState(
            id: skillID, state: .disabled, at: date.addingTimeInterval(13)
        )
        var upgradedHelper = helper
        upgradedHelper.name = "Planner v2"
        upgradedHelper.source.version = "2"
        var upgradedSkill = skill
        upgradedSkill.name = "Planning v2"
        upgradedSkill.packageVersion = "2"
        upgradedSkill.source.version = "2"
        var upgradedPackage = package
        upgradedPackage.packageVersion = "2"
        upgradedPackage.contentSHA256 = String(repeating: "b", count: 64)
        upgradedPackage.verifiedAt = date.addingTimeInterval(20)
        let upgraded = try fixture.repository.seedCatalog(
            YouziCapabilitySeed(
                helpers: [upgradedHelper],
                skills: [upgradedSkill],
                skillPackages: [upgradedPackage]
            ),
            at: date.addingTimeInterval(20)
        )
        #expect(upgraded.helpers[0].name == "Planner v2")
        #expect(upgraded.helpers[0].isFavorite)
        #expect(upgraded.helpers[0].state == .disabled)
        #expect(upgraded.skills[0].name == "Planning v2")
        #expect(upgraded.skills[0].state == .disabled)
        #expect(upgraded.skills[0].lastUsedAt == date.addingTimeInterval(-1))
        #expect(upgraded.skillPackages[0].installedAt == date)

        let baseline = try Data(contentsOf: fixture.fileURL)
        do {
            _ = try fixture.repository.seedCatalog(
                YouziCapabilitySeed(skills: [upgradedSkill], skillPackages: []),
                at: date
            )
            Issue.record("Expected seed parity failure")
        } catch let error as YouziCapabilityRepositoryError {
            guard case .invalidPackage = error else {
                Issue.record("Expected invalidPackage, got \(error)")
                return
            }
        }
        #expect(try Data(contentsOf: fixture.fileURL) == baseline)
    }

    @Test("Binding CAS and credential cleanup are fail-closed and atomic")
    func bindingAndCredentialLifecycle() throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let date = Date(timeIntervalSinceReferenceDate: 200)
        let connectorID = UUID()
        let accountID = UUID()
        let connector = makeConnector(id: connectorID, date: date)
        let account = YouziConnectionAccount(
            id: accountID,
            connectorID: connectorID,
            displayName: "Primary",
            credentialReference: "youzi.connector.\(accountID.uuidString.lowercased())",
            state: .connected,
            createdAt: date,
            updatedAt: date
        )
        _ = try fixture.repository.upsertConnector(connector, at: date)
        _ = try fixture.repository.upsertAccount(account, at: date)
        let bound = try fixture.repository.reconcileBinding(
            accountID: accountID,
            runtime: .builtIn(capabilityIdentifier: "native.lookup"),
            expectedRevision: nil,
            at: date
        )
        #expect(bound.connectorBindings[0].configurationRevision == 1)

        let baseline = try Data(contentsOf: fixture.fileURL)
        do {
            _ = try fixture.repository.reconcileBinding(
                accountID: accountID,
                runtime: .builtIn(capabilityIdentifier: "native.changed"),
                expectedRevision: nil,
                at: date
            )
            Issue.record("Expected binding CAS conflict")
        } catch let error as YouziCapabilityRepositoryError {
            guard case let .bindingRevisionConflict(expected, actual) = error else {
                Issue.record("Expected revision conflict, got \(error)")
                return
            }
            #expect(expected == nil)
            #expect(actual == 1)
        }
        #expect(try Data(contentsOf: fixture.fileURL) == baseline)

        _ = try fixture.repository.beginCredentialCleanup(id: accountID, at: date.addingTimeInterval(1))
        let cleaned = try fixture.repository.finishCredentialCleanup(
            id: accountID,
            at: date.addingTimeInterval(2)
        )
        #expect(cleaned.connectionAccounts[0].credentialReference == nil)
        #expect(cleaned.connectionAccounts[0].state == .notConnected)
        #expect(cleaned.connectorBindings.count == 1)
    }

    @Test("Connector binding revision invalidates grants and automation authority")
    func bindingRevisionInvalidatesAuthority() throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let date = Date(timeIntervalSinceReferenceDate: 300)
        let connectorID = UUID()
        let accountID = UUID()
        let requestID = UUID()
        let grantID = UUID()
        let automationID = UUID()
        let target = accountID.uuidString.lowercased()
        let permission = YouziPermissionRecord(
            id: requestID,
            automationID: automationID,
            automationRevision: 1,
            kind: .connectorRead,
            targetIdentifier: target,
            purpose: "Scheduled lookup",
            duration: .persistent,
            decision: .allowed,
            requestedAt: date,
            decidedAt: date
        )
        let grant = YouziPermissionGrant(
            id: grantID,
            permissionRecordID: requestID,
            automationID: automationID,
            automationRevision: 1,
            kind: .connectorRead,
            targetIdentifier: target,
            targetRevision: 1,
            duration: .persistent,
            grantedAt: date
        )
        let automation = YouziAutomation(
            id: automationID,
            name: "Lookup",
            trigger: .manual,
            action: .init(request: "lookup", skillIDs: [], connectionAccountIDs: [accountID]),
            permissionRecordIDs: [requestID],
            permissionGrantIDs: [grantID],
            state: .active,
            confirmedAt: date,
            createdAt: date,
            updatedAt: date
        )
        try fixture.store.save(
            YouziDomainDocument(
                permissions: [permission],
                connectors: [makeConnector(id: connectorID, date: date)],
                connectionAccounts: [
                    YouziConnectionAccount(
                        id: accountID,
                        connectorID: connectorID,
                        displayName: "Primary",
                        createdAt: date,
                        updatedAt: date
                    )
                ],
                connectorBindings: [
                    YouziConnectorBinding(
                        id: accountID,
                        runtime: .builtIn(capabilityIdentifier: "native.lookup"),
                        configurationRevision: 1,
                        createdAt: date,
                        updatedAt: date
                    )
                ],
                permissionGrants: [grant],
                automations: [automation]
            )
        )

        let revised = try fixture.repository.reconcileBinding(
            accountID: accountID,
            runtime: .builtIn(capabilityIdentifier: "native.lookup.v2"),
            expectedRevision: 1,
            at: date.addingTimeInterval(1)
        )

        #expect(revised.connectorBindings[0].configurationRevision == 2)
        #expect(revised.permissionGrants[0].revokedAt != nil)
        #expect(revised.automations[0].revision == 2)
        #expect(revised.automations[0].permissionGrantIDs.isEmpty)
        #expect(revised.automations[0].state == .needsAttention)
        #expect(revised.automations[0].confirmedAt == nil)
    }

    @Test("MCP creation and health refresh are atomic; disconnect retains exact identity")
    func atomicMCPProjectionLifecycle() throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let date = Date(timeIntervalSinceReferenceDate: 400)
        let connectorID = UUID()
        let accountID = UUID()
        let connector = YouziConnector(
            id: connectorID,
            name: "MCP server",
            summary: "fixture",
            adapter: .mcp,
            authentication: .none,
            source: .init(kind: .userCreated, identifier: "mcp.exact", version: "1"),
            createdAt: date,
            updatedAt: date
        )
        let account = YouziConnectionAccount(
            id: accountID,
            connectorID: connectorID,
            displayName: "Display name is not identity",
            createdAt: date,
            updatedAt: date
        )
        let created = try fixture.repository.createConnectorAccount(
            connector: connector,
            account: account,
            runtime: .mcp(serverName: "exact-server-key"),
            at: date
        )
        #expect(created.connectors.count == 1)
        #expect(created.connectionAccounts.count == 1)
        #expect(created.connectorBindings[0].configurationRevision == 1)
        #expect(created.connectorBindings[0].runtime == .mcp(serverName: "exact-server-key"))

        let refreshed = try fixture.repository.reconcileMCPAccount(
            id: accountID,
            toolNames: ["z.tool", "a.tool", "z.tool"],
            state: .needsAttention,
            accountRecoveryCode: .connectorUnavailable,
            bindingRecoveryCode: .connectorUnavailable,
            at: date.addingTimeInterval(1)
        )
        #expect(refreshed.connectors[0].toolNames == ["a.tool", "z.tool"])
        #expect(refreshed.connectionAccounts[0].recoveryCode == .connectorUnavailable)
        #expect(refreshed.connectorBindings[0].recoveryCode == .connectorUnavailable)

        let disconnected = try fixture.repository.disconnectAccount(
            id: accountID, at: date.addingTimeInterval(2)
        )
        #expect(disconnected.connectionAccounts[0].state == .notConnected)
        #expect(disconnected.connectionAccounts[0].recoveryCode == nil)
        #expect(disconnected.connectorBindings[0].runtime == .mcp(serverName: "exact-server-key"))
        #expect(disconnected.connectorBindings[0].configurationRevision == 1)

        let forgotten = try fixture.repository.forgetAccount(
            id: accountID, at: date.addingTimeInterval(3)
        )
        #expect(forgotten.connectionAccounts.isEmpty)
        #expect(forgotten.connectorBindings.isEmpty)
        #expect(forgotten.connectors.map(\.id) == [connectorID])
    }

    @Test("Forget refuses referenced history and execution identity invalidation uses CAS")
    func forgetAndExecutionIdentityCAS() throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        let date = Date(timeIntervalSinceReferenceDate: 500)
        let connectorID = UUID()
        let accountID = UUID()
        _ = try fixture.repository.createConnectorAccount(
            connector: YouziConnector(
                id: connectorID,
                name: "MCP server",
                summary: "fixture",
                adapter: .mcp,
                authentication: .none,
                source: .init(kind: .userCreated, identifier: "mcp.exact", version: "1")
            ),
            account: YouziConnectionAccount(
                id: accountID,
                connectorID: connectorID,
                displayName: "Account"
            ),
            runtime: .mcp(serverName: "same-server-key"),
            at: date
        )
        let automationID = UUID()
        let requestID = UUID()
        let grantID = UUID()
        let target = accountID.uuidString.lowercased()
        _ = try fixture.store.update { document in
            document.upsert(
                YouziPermissionRecord(
                    id: requestID,
                    automationID: automationID,
                    automationRevision: 1,
                    kind: .connectorRead,
                    targetIdentifier: target,
                    purpose: "Scheduled MCP lookup",
                    duration: .persistent,
                    decision: .allowed,
                    requestedAt: date,
                    decidedAt: date
                )
            )
            document.upsert(
                YouziPermissionGrant(
                    id: grantID,
                    permissionRecordID: requestID,
                    automationID: automationID,
                    automationRevision: 1,
                    kind: .connectorRead,
                    targetIdentifier: target,
                    targetRevision: 1,
                    duration: .persistent,
                    grantedAt: date
                )
            )
            document.upsert(
                YouziAutomation(
                    id: automationID,
                    name: "MCP automation",
                    trigger: .manual,
                    action: .init(request: "lookup", skillIDs: [], connectionAccountIDs: [accountID]),
                    permissionRecordIDs: [requestID],
                    permissionGrantIDs: [grantID],
                    confirmedAt: date,
                    createdAt: date,
                    updatedAt: date
                )
            )
        }
        let invalidated = try fixture.repository.invalidateBindingExecutionIdentity(
            accountID: accountID,
            expectedRevision: 1,
            at: date.addingTimeInterval(1)
        )
        #expect(invalidated.connectorBindings[0].configurationRevision == 2)
        #expect(invalidated.connectorBindings[0].runtime == .mcp(serverName: "same-server-key"))
        #expect(invalidated.permissionGrants[0].revokedAt != nil)
        #expect(invalidated.automations[0].revision == 2)
        #expect(invalidated.automations[0].state == .needsAttention)

        let staleBytes = try Data(contentsOf: fixture.fileURL)
        do {
            _ = try fixture.repository.invalidateBindingExecutionIdentity(
                accountID: accountID,
                expectedRevision: 1,
                at: date.addingTimeInterval(2)
            )
            Issue.record("Expected stale execution-identity CAS failure")
        } catch let error as YouziCapabilityRepositoryError {
            guard case let .bindingRevisionConflict(expected, actual) = error else {
                Issue.record("Expected bindingRevisionConflict, got \(error)")
                return
            }
            #expect(expected == 1)
            #expect(actual == 2)
        }
        #expect(try Data(contentsOf: fixture.fileURL) == staleBytes)

        _ = try fixture.store.update { document in
            // Remove mutable execution selection. The immutable permission and
            // grant rows must still retain the disconnected account identity;
            // account forget is not an authority-history purge operation.
            document.automations[0].action.connectionAccountIDs = []
        }
        let referencedBytes = try Data(contentsOf: fixture.fileURL)
        do {
            _ = try fixture.repository.forgetAccount(
                id: accountID, at: date.addingTimeInterval(3)
            )
            Issue.record("Expected referenced account forget refusal")
        } catch let error as YouziCapabilityRepositoryError {
            guard case .accountStillReferenced = error else {
                Issue.record("Expected accountStillReferenced, got \(error)")
                return
            }
        }
        #expect(try Data(contentsOf: fixture.fileURL) == referencedBytes)
    }

    private func makeConnector(id: UUID, date: Date) -> YouziConnector {
        YouziConnector(
            id: id,
            name: "Native connector",
            summary: "fixture",
            adapter: .native,
            authentication: .apiKey,
            source: .init(kind: .builtIn, identifier: "fixture.connector", version: "1"),
            createdAt: date,
            updatedAt: date
        )
    }

    private final class StoreFixture {
        let root: URL
        let fileURL: URL
        let store: YouziDomainStore
        let repository: YouziCapabilityRepository

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("youzi-capability-repo-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            fileURL = root.appendingPathComponent("domain.json")
            store = YouziDomainStore(fileURL: fileURL)
            repository = YouziCapabilityRepository(store: store)
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
}
