import Foundation
import Testing
@testable import Rapid

@Suite("Youzi task execution coordinator")
struct YouziTaskExecutionCoordinatorTests {
    private let coordinator = YouziTaskExecutionCoordinator()

    @Test("Built-ins receive exact immutable network requirements")
    func builtInRequirements() throws {
        let task = YouziTask(
            id: id(1),
            title: "Research",
            request: "Check it",
            helperSelectionIntent: .explicit,
            skillSelectionIntent: .explicit,
            connectionAccountSelectionIntent: .explicit
        )
        let plan = coordinator.prepare(
            taskID: task.id,
            document: YouziDomainDocument(tasks: [task]),
            builtInToolNames: ["weather", "web_search", "weather"],
            runtime: .init(connectorsEnabled: false),
            skillInstructionComponents: [:]
        )

        #expect(plan.advertisedToolNames == ["weather", "web_search"])
        #expect(plan.scopedTurn.subject == .interactiveTask(task.id))
        let weather = try #require(plan.authorizationsByToolName["weather"])
        #expect(weather.requirement.kind == .networkAccess)
        #expect(weather.requirement.targetIdentifier == "builtin.network")
        #expect(weather.requirement.capabilityIdentifier == "builtin.network")
        #expect(weather.requirement.toolName == "weather")
        #expect(weather.runtime.connectionAccountID == nil)
        let needs = plan.permissionNeeds(in: YouziDomainDocument(tasks: [task]))
        #expect(needs.count == 1)
        #expect(needs[0].requirement.targetIdentifier == "builtin.network")
    }

    @Test("Selected skill workspace permissions are included in one preflight plan")
    func workspacePermissionPreflight() {
        let workspace = YouziWorkspace(
            id: id(30),
            name: "Home",
            location: .managed(relativePath: "home")
        )
        let skill = YouziSkill(
            id: id(31),
            name: "Project pilot",
            summary: "Manage a project",
            packageVersion: "1.0.0",
            entrypoint: "SKILL.md",
            executionLocation: .local,
            requestedPermissions: [.workspaceRead, .workspaceWrite],
            source: .init(kind: .builtIn, identifier: "project-pilot", version: "1.0.0")
        )
        let task = YouziTask(
            id: id(32),
            title: "Plan",
            request: "Plan it",
            workspaceID: workspace.id,
            helperSelectionIntent: .explicit,
            skillIDs: [skill.id],
            skillSelectionIntent: .explicit,
            connectionAccountSelectionIntent: .explicit
        )
        let document = YouziDomainDocument(
            tasks: [task],
            workspaces: [workspace],
            skills: [skill]
        )
        let plan = coordinator.prepare(
            taskID: task.id,
            document: document,
            builtInToolNames: [],
            runtime: .init(connectorsEnabled: false),
            skillInstructionComponents: [skill.id: "Keep the workspace organized."]
        )

        #expect(plan.supplementalAuthorizations.map(\.requirement.kind) == [
            .workspaceRead, .workspaceWrite,
        ])
        #expect(plan.permissionNeeds(in: document).map(\.requirement.kind) == [
            .workspaceRead, .workspaceWrite,
        ])
    }

    @Test("One live selected MCP account produces an exact revision-bound read requirement")
    func exactConnectedApplicationRequirement() throws {
        let connector = makeConnector(id: id(10), tools: ["calendar__list_events"])
        let account = makeAccount(id: id(11), connectorID: connector.id)
        let task = YouziTask(
            id: id(12),
            title: "Calendar",
            request: "What is next?",
            helperSelectionIntent: .explicit,
            skillSelectionIntent: .explicit,
            connectionAccountIDs: [account.id],
            connectionAccountSelectionIntent: .explicit
        )
        let document = YouziDomainDocument(
            tasks: [task],
            connectors: [connector],
            connectionAccounts: [account],
            connectorBindings: [makeBinding(accountID: account.id, revision: 4)]
        )
        let plan = coordinator.prepare(
            taskID: task.id,
            document: document,
            builtInToolNames: [],
            runtime: runtime(toolName: "calendar__list_events"),
            skillInstructionComponents: [:]
        )

        #expect(plan.advertisedToolNames == ["calendar__list_events"])
        let authorization = try #require(
            plan.authorizationsByToolName["calendar__list_events"]
        )
        #expect(authorization.requirement.kind == .connectorRead)
        #expect(authorization.requirement.connectionAccountID == account.id)
        #expect(authorization.requirement.targetIdentifier == account.id.uuidString.lowercased())
        #expect(authorization.requirement.targetRevision == 4)
        #expect(authorization.runtime.bindingRevision == 4)
        #expect(authorization.runtime.runtimeAvailable)
    }

    @Test("An ambiguous runtime tool owner is never advertised")
    func ambiguousOwnerFailsClosed() {
        let connector = makeConnector(id: id(20), tools: ["calendar__list_events"])
        let accountA = makeAccount(id: id(21), connectorID: connector.id)
        let accountB = makeAccount(id: id(22), connectorID: connector.id)
        let task = YouziTask(
            id: id(23),
            title: "Calendar",
            request: "What is next?",
            helperSelectionIntent: .explicit,
            skillSelectionIntent: .explicit,
            connectionAccountIDs: [accountA.id, accountB.id],
            connectionAccountSelectionIntent: .explicit
        )
        let document = YouziDomainDocument(
            tasks: [task],
            connectors: [connector],
            connectionAccounts: [accountA, accountB],
            connectorBindings: [
                makeBinding(accountID: accountA.id, revision: 1),
                makeBinding(accountID: accountB.id, revision: 1),
            ]
        )

        let plan = coordinator.prepare(
            taskID: task.id,
            document: document,
            builtInToolNames: [],
            runtime: runtime(toolName: "calendar__list_events"),
            skillInstructionComponents: [:]
        )

        #expect(plan.advertisedToolNames.isEmpty)
        #expect(plan.issues.contains(
            .ambiguousConnectedApplicationTool(name: "calendar__list_events")
        ))
    }

    @Test("Automation plans use the exact run grant snapshot and automation subject")
    func automationRunGrantSnapshot() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let task = YouziTask(
            id: id(40),
            title: "Scheduled research",
            request: "Check the market",
            helperSelectionIntent: .explicit,
            skillSelectionIntent: .explicit,
            connectionAccountSelectionIntent: .explicit
        )
        let automationID = id(41)
        let record = YouziPermissionRecord(
            id: id(42),
            automationID: automationID,
            automationRevision: 3,
            kind: .networkAccess,
            targetIdentifier: "builtin.network",
            purpose: "Scheduled research",
            duration: .persistent,
            decision: .allowed,
            requestedAt: now.addingTimeInterval(-20),
            decidedAt: now.addingTimeInterval(-15)
        )
        let allowedGrant = YouziPermissionGrant(
            id: id(43),
            permissionRecordID: record.id,
            automationID: automationID,
            automationRevision: 3,
            kind: .networkAccess,
            targetIdentifier: "builtin.network",
            duration: .persistent,
            grantedAt: now.addingTimeInterval(-10)
        )
        let document = YouziDomainDocument(
            permissions: [record],
            tasks: [task],
            permissionGrants: [allowedGrant]
        )
        let subject = YouziExecutionPermissionSubject.automation(
            id: automationID,
            revision: 3
        )

        let allowed = coordinator.prepare(
            taskID: task.id,
            document: document,
            builtInToolNames: ["web_search"],
            runtime: .init(connectorsEnabled: false),
            skillInstructionComponents: [:],
            subject: subject,
            allowedPermissionGrantIDs: [allowedGrant.id]
        )
        #expect(allowed.scopedTurn.subject == subject)
        #expect(allowed.allowedPermissionGrantIDs == [allowedGrant.id])
        #expect(allowed.permissionNeeds(in: document, now: now).isEmpty)

        let omitted = coordinator.prepare(
            taskID: task.id,
            document: document,
            builtInToolNames: ["web_search"],
            runtime: .init(connectorsEnabled: false),
            skillInstructionComponents: [:],
            subject: subject
        )
        #expect(omitted.allowedPermissionGrantIDs == [])
        #expect(omitted.permissionNeeds(in: document, now: now).count == 1)
    }

    @MainActor
    @Test("Dispatch authorization cannot borrow a grant outside the automation run snapshot")
    func dispatchCannotBorrowAutomationGrant() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "youzi-task-authorizer-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let task = YouziTask(
            id: id(50),
            title: "Scheduled research",
            request: "Check the market",
            helperSelectionIntent: .explicit,
            skillSelectionIntent: .explicit,
            connectionAccountSelectionIntent: .explicit
        )
        let automationID = id(51)
        let record = YouziPermissionRecord(
            id: id(52),
            automationID: automationID,
            automationRevision: 2,
            kind: .networkAccess,
            targetIdentifier: "builtin.network",
            purpose: "Scheduled research",
            duration: .persistent,
            decision: .allowed,
            requestedAt: now.addingTimeInterval(-20),
            decidedAt: now.addingTimeInterval(-15)
        )
        let grant = YouziPermissionGrant(
            id: id(53),
            permissionRecordID: record.id,
            automationID: automationID,
            automationRevision: 2,
            kind: .networkAccess,
            targetIdentifier: "builtin.network",
            duration: .persistent,
            grantedAt: now.addingTimeInterval(-10)
        )
        let automation = YouziAutomation(
            id: automationID,
            name: "Scheduled research",
            revision: 2,
            trigger: .manual,
            action: .init(
                request: task.request,
                skillIDs: [],
                connectionAccountIDs: []
            ),
            permissionRecordIDs: [record.id],
            permissionGrantIDs: [grant.id],
            state: .active,
            confirmedAt: now,
            createdAt: now,
            updatedAt: now
        )
        let document = YouziDomainDocument(
            permissions: [record],
            tasks: [task],
            permissionGrants: [grant],
            automations: [automation]
        )
        let store = YouziDomainStore(fileURL: root.appendingPathComponent("domain.json"))
        try store.save(document)
        let productModel = YouziProductModel(store: store)
        let subject = YouziExecutionPermissionSubject.automation(
            id: automationID,
            revision: 2
        )

        let allowedPlan = coordinator.prepare(
            taskID: task.id,
            document: document,
            builtInToolNames: ["web_search"],
            runtime: .init(connectorsEnabled: false),
            skillInstructionComponents: [:],
            subject: subject,
            allowedPermissionGrantIDs: [grant.id]
        )
        let allowed = await YouziTaskDispatchAuthorizer(
            productModel: productModel,
            plan: allowedPlan
        ).authorize(.init(subject: subject, toolName: "web_search"))
        #expect(allowed == .authorized)

        let omittedPlan = coordinator.prepare(
            taskID: task.id,
            document: document,
            builtInToolNames: ["web_search"],
            runtime: .init(connectorsEnabled: false),
            skillInstructionComponents: [:],
            subject: subject
        )
        let denied = await YouziTaskDispatchAuthorizer(
            productModel: productModel,
            plan: omittedPlan
        ).authorize(.init(subject: subject, toolName: "web_search"))
        let expectedDenial = YouziToolDispatchAuthorizationDecision.denied(
            .domainPermissionRequired
        )
        #expect(denied == expectedDenial)
    }

    @MainActor
    @Test("Dispatch rechecks injected expiry time instead of trusting the prepared snapshot")
    func dispatchRechecksExpiry() async throws {
        let preparedAt = Date(timeIntervalSince1970: 3_000_000)
        let fixture = try makeAuthorizationFixture(
            preparedAt: preparedAt,
            expiresAt: preparedAt.addingTimeInterval(30)
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let decision = await YouziTaskDispatchAuthorizer(
            productModel: fixture.productModel,
            plan: fixture.plan,
            now: { preparedAt.addingTimeInterval(31) }
        ).authorize(.init(subject: fixture.subject, toolName: fixture.toolName))

        #expect(decision == .denied(.domainPermissionRequired))
    }

    @MainActor
    @Test("A durable revocation racing the stream is observed before dispatch")
    func dispatchRefreshesRevocation() async throws {
        let preparedAt = Date(timeIntervalSince1970: 3_100_000)
        let fixture = try makeAuthorizationFixture(preparedAt: preparedAt)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try YouziPermissionRepository(store: fixture.store).revoke(
            grantID: fixture.grantID,
            at: preparedAt.addingTimeInterval(1)
        )

        let decision = await YouziTaskDispatchAuthorizer(
            productModel: fixture.productModel,
            plan: fixture.plan,
            now: { preparedAt.addingTimeInterval(2) }
        ).authorize(.init(subject: fixture.subject, toolName: fixture.toolName))

        #expect(decision == .denied(.denied))
    }

    @MainActor
    @Test("A connector binding recovery race fails closed before dispatch")
    func dispatchRefreshesBindingState() async throws {
        let preparedAt = Date(timeIntervalSince1970: 3_200_000)
        let fixture = try makeAuthorizationFixture(
            preparedAt: preparedAt,
            connectorTool: true
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try fixture.store.update { document in
            document.connectorBindings[0].recoveryCode = .connectorUnavailable
            document.connectorBindings[0].updatedAt = preparedAt.addingTimeInterval(1)
        }

        let decision = await YouziTaskDispatchAuthorizer(
            productModel: fixture.productModel,
            plan: fixture.plan,
            now: { preparedAt.addingTimeInterval(2) }
        ).authorize(.init(subject: fixture.subject, toolName: fixture.toolName))

        #expect(decision == .denied(.bindingUnavailable))
    }

    @MainActor
    @Test("A failed authority refresh never falls back to the stale in-memory grant")
    func dispatchRefreshFailureIsClosed() async throws {
        let preparedAt = Date(timeIntervalSince1970: 3_300_000)
        let fixture = try makeAuthorizationFixture(preparedAt: preparedAt)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let unsupported = YouziDomainEnvelope(
            schemaVersion: YouziDomainSchema.currentVersion + 1,
            document: .empty
        )
        try JSONEncoder().encode(unsupported).write(to: fixture.store.fileURL, options: .atomic)

        let decision = await YouziTaskDispatchAuthorizer(
            productModel: fixture.productModel,
            plan: fixture.plan,
            now: { preparedAt.addingTimeInterval(1) }
        ).authorize(.init(subject: fixture.subject, toolName: fixture.toolName))

        #expect(decision == .denied(.runtimeUnavailable))
        #expect(fixture.productModel.lastPersistenceError != nil)
    }

    @MainActor
    private func makeAuthorizationFixture(
        preparedAt: Date,
        expiresAt: Date? = nil,
        connectorTool: Bool = false
    ) throws -> (
        root: URL,
        store: YouziDomainStore,
        productModel: YouziProductModel,
        plan: YouziTaskExecutionPlan,
        subject: YouziExecutionPermissionSubject,
        grantID: UUID,
        toolName: String
    ) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "youzi-dispatch-race-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let taskID = UUID()
        let automationID = UUID()
        let recordID = UUID()
        let grantID = UUID()
        let connector = makeConnector(id: UUID(), tools: ["calendar__list_events"])
        let account = makeAccount(id: UUID(), connectorID: connector.id)
        let toolName = connectorTool ? "calendar__list_events" : "web_search"
        let kind: YouziPermissionKind = connectorTool ? .connectorRead : .networkAccess
        let target = connectorTool
            ? account.id.uuidString.lowercased()
            : "builtin.network"
        let task = YouziTask(
            id: taskID,
            title: "Scheduled",
            request: "Run safely",
            helperSelectionIntent: .explicit,
            skillSelectionIntent: .explicit,
            connectionAccountIDs: connectorTool ? [account.id] : [],
            connectionAccountSelectionIntent: .explicit
        )
        let record = YouziPermissionRecord(
            id: recordID,
            automationID: automationID,
            automationRevision: 2,
            kind: kind,
            targetIdentifier: target,
            purpose: "Scheduled",
            duration: .persistent,
            decision: .allowed,
            requestedAt: preparedAt.addingTimeInterval(-20),
            decidedAt: preparedAt.addingTimeInterval(-15)
        )
        let grant = YouziPermissionGrant(
            id: grantID,
            permissionRecordID: record.id,
            automationID: automationID,
            automationRevision: 2,
            kind: kind,
            targetIdentifier: target,
            targetRevision: connectorTool ? 1 : nil,
            duration: .persistent,
            grantedAt: preparedAt.addingTimeInterval(-10),
            expiresAt: expiresAt
        )
        let automation = YouziAutomation(
            id: automationID,
            name: "Scheduled",
            revision: 2,
            trigger: .manual,
            action: .init(
                request: task.request,
                skillIDs: [],
                connectionAccountIDs: connectorTool ? [account.id] : []
            ),
            permissionRecordIDs: [record.id],
            permissionGrantIDs: [grant.id],
            state: .active,
            confirmedAt: preparedAt,
            createdAt: preparedAt,
            updatedAt: preparedAt
        )
        let document = YouziDomainDocument(
            permissions: [record],
            tasks: [task],
            connectors: connectorTool ? [connector] : [],
            connectionAccounts: connectorTool ? [account] : [],
            connectorBindings: connectorTool
                ? [makeBinding(accountID: account.id, revision: 1)]
                : [],
            permissionGrants: [grant],
            automations: [automation]
        )
        let store = YouziDomainStore(fileURL: root.appendingPathComponent("domain.json"))
        try store.save(document)
        let productModel = YouziProductModel(store: store)
        let subject = YouziExecutionPermissionSubject.automation(
            id: automationID,
            revision: 2
        )
        let plan = coordinator.prepare(
            taskID: task.id,
            document: document,
            builtInToolNames: connectorTool ? [] : [toolName],
            runtime: connectorTool
                ? runtime(toolName: toolName)
                : .init(connectorsEnabled: false),
            skillInstructionComponents: [:],
            subject: subject,
            allowedPermissionGrantIDs: [grant.id]
        )
        return (root, store, productModel, plan, subject, grantID, toolName)
    }

    private func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }

    private func makeConnector(id: UUID, tools: [String]) -> YouziConnector {
        YouziConnector(
            id: id,
            name: "Calendar",
            summary: "Calendar connector",
            adapter: .mcp,
            authentication: .localSession,
            toolNames: tools,
            source: .init(kind: .userCreated, identifier: "calendar", version: "1.0.0")
        )
    }

    private func makeAccount(id: UUID, connectorID: UUID) -> YouziConnectionAccount {
        YouziConnectionAccount(
            id: id,
            connectorID: connectorID,
            displayName: "My calendar",
            state: .connected
        )
    }

    private func makeBinding(accountID: UUID, revision: Int) -> YouziConnectorBinding {
        YouziConnectorBinding(
            id: accountID,
            runtime: .mcp(serverName: "calendar"),
            configurationRevision: revision
        )
    }

    private func runtime(toolName: String) -> YouziMCPRuntimeSnapshot {
        .init(
            connectorsEnabled: true,
            configuredServers: [.init(name: "calendar")],
            catalogState: .ready,
            liveServers: [.init(name: "calendar", state: .connected)],
            tools: [.init(name: toolName, serverName: "calendar")]
        )
    }
}
