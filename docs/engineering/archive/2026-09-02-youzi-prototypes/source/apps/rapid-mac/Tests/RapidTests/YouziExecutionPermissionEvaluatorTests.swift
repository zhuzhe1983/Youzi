import Foundation
import Testing
@testable import Rapid

@Suite("Youzi execution permission evaluator")
struct YouziExecutionPermissionEvaluatorTests {
    private let evaluator = YouziExecutionPermissionEvaluator()
    private let now = Date(timeIntervalSince1970: 2_000_000)

    @Test("Interactive task authority is exact and once consumption is only an intent")
    func interactiveAuthorizationAndOnceIntent() throws {
        let requirement = networkRequirement()
        let taskAuthority = authority(
            recordID: 101,
            grantID: 201,
            subject: .interactiveTask(id(1)),
            requirement: requirement,
            duration: .task
        )
        let taskResult = evaluate(
            subject: .interactiveTask(id(1)),
            requirement: requirement,
            records: [taskAuthority.record],
            grants: [taskAuthority.grant]
        )
        let taskAuthorization = try authorized(taskResult)
        #expect(taskAuthorization.matchingGrantIDs == [id(201)])
        #expect(taskAuthorization.selectedGrantID == id(201))
        #expect(taskAuthorization.permissionRecordID == id(101))
        #expect(taskAuthorization.consumptionIntent == nil)
        #expect(taskResult.recovery == .none)

        let onceAuthority = authority(
            recordID: 102,
            grantID: 202,
            subject: .interactiveTask(id(1)),
            requirement: requirement,
            duration: .once
        )
        let onceResult = evaluate(
            subject: .interactiveTask(id(1)),
            requirement: requirement,
            records: [onceAuthority.record],
            grants: [onceAuthority.grant]
        )
        let onceAuthorization = try authorized(onceResult)
        #expect(onceAuthorization.consumptionIntent == .consumeOnce(grantID: id(202)))
        // Evaluation is pure: the supplied domain grant was not consumed.
        #expect(onceAuthority.grant.consumedAt == nil)
    }

    @Test("Permission decisions are history and never authority without a grant")
    func requestAloneNeverAuthorizes() {
        let requirement = networkRequirement()
        let allowed = authority(
            subject: .interactiveTask(id(1)),
            requirement: requirement,
            duration: .task
        ).record
        var pending = allowed
        pending.decision = .pending
        pending.decidedAt = nil
        var denied = allowed
        denied.decision = .denied

        let allowedResult = evaluate(
            subject: .interactiveTask(id(1)),
            requirement: requirement,
            records: [allowed],
            grants: []
        )
        #expect(allowedResult.outcome == .domainPermissionRequired)
        #expect(allowedResult.recovery == .requestDomainPermission)

        let pendingResult = evaluate(
            subject: .interactiveTask(id(1)),
            requirement: requirement,
            records: [pending],
            grants: []
        )
        #expect(pendingResult.outcome == .domainPermissionRequired)

        let deniedResult = evaluate(
            subject: .interactiveTask(id(1)),
            requirement: requirement,
            records: [denied],
            grants: []
        )
        #expect(deniedResult.outcome == .denied)
        #expect(deniedResult.recovery == .reviewDeniedPermission)
    }

    @Test("Task grants do not cross tasks, automations, or unscoped app records")
    func subjectIsolation() {
        let requirement = networkRequirement()
        let taskAuthority = authority(
            subject: .interactiveTask(id(1)),
            requirement: requirement,
            duration: .task
        )

        #expect(evaluate(
            subject: .interactiveTask(id(2)),
            requirement: requirement,
            records: [taskAuthority.record],
            grants: [taskAuthority.grant]
        ).outcome == .domainPermissionRequired)
        #expect(evaluate(
            subject: .automation(id: id(3), revision: 1),
            requirement: requirement,
            records: [taskAuthority.record],
            grants: [taskAuthority.grant]
        ).outcome == .domainPermissionRequired)

        let appRecord = YouziPermissionRecord(
            id: id(120),
            kind: requirement.kind,
            targetIdentifier: requirement.targetIdentifier,
            purpose: "First use",
            duration: .persistent,
            decision: .allowed,
            requestedAt: now.addingTimeInterval(-20),
            decidedAt: now.addingTimeInterval(-15)
        )
        let appGrant = YouziPermissionGrant(
            id: id(220),
            permissionRecordID: appRecord.id,
            kind: requirement.kind,
            targetIdentifier: requirement.targetIdentifier,
            duration: .persistent,
            grantedAt: now.addingTimeInterval(-10)
        )
        #expect(evaluate(
            subject: .interactiveTask(id(1)),
            requirement: requirement,
            records: [appRecord],
            grants: [appGrant]
        ).outcome == .domainPermissionRequired)
    }

    @Test("Automation authority requires persistent duration and its exact revision")
    func automationRevisionAndDuration() throws {
        let requirement = networkRequirement()
        let subject = YouziExecutionPermissionSubject.automation(id: id(3), revision: 7)
        let exact = authority(
            subject: subject,
            requirement: requirement,
            duration: .persistent
        )
        _ = try authorized(evaluate(
            subject: subject,
            requirement: requirement,
            records: [exact.record],
            grants: [exact.grant]
        ))

        #expect(evaluate(
            subject: .automation(id: id(3), revision: 8),
            requirement: requirement,
            records: [exact.record],
            grants: [exact.grant]
        ).outcome == .domainPermissionRequired)

        let wrongDuration = authority(
            recordID: 103,
            grantID: 203,
            subject: subject,
            requirement: requirement,
            duration: .task
        )
        #expect(evaluate(
            subject: subject,
            requirement: requirement,
            records: [wrongDuration.record],
            grants: [wrongDuration.grant]
        ).outcome == .domainPermissionRequired)
    }

    @Test("Expired, revoked, consumed-once, and future grants fail closed")
    func grantLifecycle() {
        let requirement = networkRequirement()
        let base = authority(
            subject: .interactiveTask(id(1)),
            requirement: requirement,
            duration: .once
        )
        var consumed = base.grant
        consumed.consumedAt = now.addingTimeInterval(-1)
        var revoked = base.grant
        revoked.revokedAt = now.addingTimeInterval(-1)
        var expired = base.grant
        expired.expiresAt = now
        let future = authority(
            recordID: 104,
            grantID: 204,
            subject: .interactiveTask(id(1)),
            requirement: requirement,
            duration: .once,
            requestedAt: now.addingTimeInterval(-20),
            decidedAt: now.addingTimeInterval(-10),
            grantedAt: now.addingTimeInterval(1)
        )

        for grant in [consumed, revoked, expired] {
            #expect(evaluate(
                subject: .interactiveTask(id(1)),
                requirement: requirement,
                records: [base.record],
                grants: [grant]
            ).outcome == .domainPermissionRequired)
        }
        #expect(evaluate(
            subject: .interactiveTask(id(1)),
            requirement: requirement,
            records: [future.record],
            grants: [future.grant]
        ).outcome == .domainPermissionRequired)
    }

    @Test("Dangling, mismatched, non-allowed, and incoherent grants fail closed")
    func corruptedAuthorityFailsClosed() {
        let requirement = networkRequirement()
        let base = authority(
            subject: .interactiveTask(id(1)),
            requirement: requirement,
            duration: .task
        )
        var pendingRecord = base.record
        pendingRecord.decision = .pending
        pendingRecord.decidedAt = nil
        let mismatchedRecord = YouziPermissionRecord(
            id: base.record.id,
            taskID: id(1),
            kind: .networkAccess,
            targetIdentifier: "builtin.weather",
            purpose: "Mismatch",
            duration: .task,
            decision: .allowed,
            requestedAt: now.addingTimeInterval(-20),
            decidedAt: now.addingTimeInterval(-15)
        )
        let incoherentRecord = YouziPermissionRecord(
            id: base.record.id,
            taskID: id(1),
            automationID: id(3),
            automationRevision: 1,
            kind: requirement.kind,
            targetIdentifier: requirement.targetIdentifier,
            purpose: "Incoherent",
            duration: .task,
            decision: .allowed,
            requestedAt: now.addingTimeInterval(-20),
            decidedAt: now.addingTimeInterval(-15)
        )

        #expect(evaluate(
            subject: .interactiveTask(id(1)),
            requirement: requirement,
            records: [],
            grants: [base.grant]
        ).outcome == .domainPermissionRequired)
        for record in [pendingRecord, mismatchedRecord, incoherentRecord] {
            #expect(evaluate(
                subject: .interactiveTask(id(1)),
                requirement: requirement,
                records: [record],
                grants: [base.grant]
            ).outcome == .domainPermissionRequired)
        }
    }

    @Test("Connector authority requires canonical account target and exact live binding")
    func connectorAuthorityAndBinding() throws {
        let accountID = id(5)
        let requirement = connectorRequirement(accountID: accountID, revision: 3)
        let exact = authority(
            subject: .interactiveTask(id(1)),
            requirement: requirement,
            duration: .task
        )
        let account = connectionAccount(id: accountID, state: .connected)
        let binding = connectorBinding(id: accountID, revision: 3)
        let runtime = connectorRuntime(accountID: accountID, revision: 3)

        _ = try authorized(evaluate(
            subject: .interactiveTask(id(1)),
            requirement: requirement,
            records: [exact.record],
            grants: [exact.grant],
            accounts: [account],
            bindings: [binding],
            runtime: runtime
        ))

        let unavailableAccount = connectionAccount(id: accountID, state: .needsAttention)
        #expect(evaluate(
            subject: .interactiveTask(id(1)),
            requirement: requirement,
            records: [exact.record],
            grants: [exact.grant],
            accounts: [unavailableAccount],
            bindings: [binding],
            runtime: runtime
        ).outcome == .accountUnavailable)

        #expect(evaluate(
            subject: .interactiveTask(id(1)),
            requirement: requirement,
            records: [exact.record],
            grants: [exact.grant],
            accounts: [account],
            bindings: [connectorBinding(id: accountID, revision: 4)],
            runtime: runtime
        ).outcome == .bindingUnavailable)

        let staleRequirement = connectorRequirement(accountID: accountID, revision: 4)
        #expect(evaluate(
            subject: .interactiveTask(id(1)),
            requirement: staleRequirement,
            records: [exact.record],
            grants: [exact.grant],
            accounts: [account],
            bindings: [connectorBinding(id: accountID, revision: 4)],
            runtime: connectorRuntime(accountID: accountID, revision: 4)
        ).outcome == .domainPermissionRequired)

        #expect(evaluate(
            subject: .interactiveTask(id(1)),
            requirement: requirement,
            records: [exact.record],
            grants: [exact.grant],
            accounts: [account],
            bindings: [binding],
            runtime: connectorRuntime(
                accountID: accountID,
                revision: 3,
                approval: .awaitingUser
            )
        ).outcome == .awaitingLowLevelConfirmation)
        #expect(evaluate(
            subject: .interactiveTask(id(1)),
            requirement: requirement,
            records: [exact.record],
            grants: [exact.grant],
            accounts: [account],
            bindings: [binding],
            runtime: connectorRuntime(
                accountID: accountID,
                revision: 3,
                approval: .denied
            )
        ).outcome == .denied)
    }

    @Test("Low-level approval, advertisement, and enablement remain load-bearing")
    func runtimeGates() {
        let requirement = networkRequirement()
        let exact = authority(
            subject: .interactiveTask(id(1)),
            requirement: requirement,
            duration: .task
        )

        let cases: [(YouziExecutionPermissionRuntimeGate, YouziExecutionPermissionOutcome)] = [
            (networkRuntime(approval: .awaitingUser), .awaitingLowLevelConfirmation),
            (networkRuntime(approval: .denied), .denied),
            (networkRuntime(approval: .unavailable), .runtimeUnavailable),
            (networkRuntime(advertised: false), .notAdvertised),
            (networkRuntime(globalEnabled: false), .disabled(.global)),
            (networkRuntime(toolEnabled: false), .disabled(.tool)),
            (networkRuntime(runtimeAvailable: false), .runtimeUnavailable),
        ]
        for (runtime, expected) in cases {
            #expect(evaluate(
                subject: .interactiveTask(id(1)),
                requirement: requirement,
                records: [exact.record],
                grants: [exact.grant],
                runtime: runtime
            ).outcome == expected)
        }
    }

    @Test("Built-in network tools require first-use domain authority plus runtime approval")
    func builtInFirstUse() throws {
        let requirement = networkRequirement()
        let exact = authority(
            subject: .interactiveTask(id(1)),
            requirement: requirement,
            duration: .task
        )
        #expect(evaluate(
            subject: .interactiveTask(id(1)),
            requirement: requirement,
            records: [exact.record],
            grants: []
        ).outcome == .domainPermissionRequired)
        _ = try authorized(evaluate(
            subject: .interactiveTask(id(1)),
            requirement: requirement,
            records: [exact.record],
            grants: [exact.grant],
            runtime: networkRuntime(approval: .approved)
        ))
    }

    @Test("Shuffled duplicate matching authority has stable audit order and selection")
    func deterministicUnderShuffle() throws {
        let requirement = networkRequirement()
        let once = authority(
            recordID: 150,
            grantID: 250,
            subject: .interactiveTask(id(1)),
            requirement: requirement,
            duration: .once
        )
        let higherTask = authority(
            recordID: 180,
            grantID: 280,
            subject: .interactiveTask(id(1)),
            requirement: requirement,
            duration: .task
        )
        let lowerTask = authority(
            recordID: 170,
            grantID: 270,
            subject: .interactiveTask(id(1)),
            requirement: requirement,
            duration: .task
        )
        let records = [higherTask.record, once.record, lowerTask.record]
        let grants = [once.grant, lowerTask.grant, higherTask.grant]
        let first = try authorized(evaluate(
            subject: .interactiveTask(id(1)),
            requirement: requirement,
            records: records,
            grants: grants
        ))
        let second = try authorized(evaluate(
            subject: .interactiveTask(id(1)),
            requirement: requirement,
            records: records.reversed(),
            grants: grants.reversed()
        ))

        #expect(first == second)
        #expect(first.matchingGrantIDs == [id(250), id(270), id(280)])
        #expect(first.selectedGrantID == id(270))
        #expect(first.consumptionIntent == nil)
    }

    @Test("Duplicate record or grant identities cannot widen authority")
    func duplicateIdentitiesFailClosed() {
        let requirement = networkRequirement()
        let exact = authority(
            subject: .interactiveTask(id(1)),
            requirement: requirement,
            duration: .task
        )
        #expect(evaluate(
            subject: .interactiveTask(id(1)),
            requirement: requirement,
            records: [exact.record, exact.record],
            grants: [exact.grant]
        ).outcome == .domainPermissionRequired)
        #expect(evaluate(
            subject: .interactiveTask(id(1)),
            requirement: requirement,
            records: [exact.record],
            grants: [exact.grant, exact.grant]
        ).outcome == .domainPermissionRequired)
    }

    @Test("Malformed identities and mismatched runtime snapshots fail without echoing inputs")
    func malformedAndNoSensitiveEcho() {
        let malformed = YouziExecutionPermissionRequirement(
            kind: .destructiveLocalAction,
            targetIdentifier: "/Users/person/private.txt",
            toolName: "delete"
        )
        let malformedResult = evaluate(
            subject: .interactiveTask(id(1)),
            requirement: malformed,
            records: [],
            grants: []
        )
        #expect(malformedResult.outcome == .malformedRequirement)
        #expect(malformedResult.recovery == .correctRequirement)
        #expect(!String(describing: malformedResult).contains("private.txt"))

        let requirement = networkRequirement()
        let exact = authority(
            subject: .interactiveTask(id(1)),
            requirement: requirement,
            duration: .task
        )
        let wrongSnapshot = YouziExecutionPermissionRuntimeGate(
            toolName: "weather",
            capabilityIdentifier: "builtin.weather",
            advertisedForTurn: true,
            globallyEnabled: true,
            toolEnabled: true,
            runtimeAvailable: true,
            lowLevelApproval: .approved
        )
        #expect(evaluate(
            subject: .interactiveTask(id(1)),
            requirement: requirement,
            records: [exact.record],
            grants: [exact.grant],
            runtime: wrongSnapshot
        ).outcome == .runtimeUnavailable)
        #expect(evaluate(
            subject: .automation(id: id(3), revision: 0),
            requirement: requirement,
            records: [],
            grants: []
        ).outcome == .malformedRequirement)
    }

    private func networkRequirement() -> YouziExecutionPermissionRequirement {
        .init(
            kind: .networkAccess,
            targetIdentifier: "builtin.web_search",
            capabilityIdentifier: "builtin.web_search",
            toolName: "web_search"
        )
    }

    private func connectorRequirement(
        accountID: UUID,
        revision: Int
    ) -> YouziExecutionPermissionRequirement {
        .init(
            kind: .connectorRead,
            targetIdentifier: accountID.uuidString.lowercased(),
            targetRevision: revision,
            connectionAccountID: accountID,
            toolName: "calendar.read"
        )
    }

    private func authority(
        recordID: Int = 100,
        grantID: Int = 200,
        subject: YouziExecutionPermissionSubject,
        requirement: YouziExecutionPermissionRequirement,
        duration: YouziPermissionDuration,
        requestedAt: Date? = nil,
        decidedAt: Date? = nil,
        grantedAt: Date? = nil
    ) -> (record: YouziPermissionRecord, grant: YouziPermissionGrant) {
        let subjectFields = fields(for: subject)
        let record = YouziPermissionRecord(
            id: id(recordID),
            taskID: subjectFields.taskID,
            automationID: subjectFields.automationID,
            automationRevision: subjectFields.automationRevision,
            kind: requirement.kind,
            targetIdentifier: requirement.targetIdentifier,
            purpose: "Execute requested capability",
            duration: duration,
            decision: .allowed,
            requestedAt: requestedAt ?? now.addingTimeInterval(-20),
            decidedAt: decidedAt ?? now.addingTimeInterval(-15)
        )
        let grant = YouziPermissionGrant(
            id: id(grantID),
            permissionRecordID: record.id,
            taskID: subjectFields.taskID,
            automationID: subjectFields.automationID,
            automationRevision: subjectFields.automationRevision,
            kind: requirement.kind,
            targetIdentifier: requirement.targetIdentifier,
            targetRevision: requirement.targetRevision,
            duration: duration,
            grantedAt: grantedAt ?? now.addingTimeInterval(-10)
        )
        return (record, grant)
    }

    private func fields(
        for subject: YouziExecutionPermissionSubject
    ) -> (taskID: UUID?, automationID: UUID?, automationRevision: Int?) {
        switch subject {
        case let .interactiveTask(taskID):
            return (taskID, nil, nil)
        case let .automation(automationID, revision):
            return (nil, automationID, revision)
        }
    }

    private func evaluate(
        subject: YouziExecutionPermissionSubject,
        requirement: YouziExecutionPermissionRequirement,
        records: [YouziPermissionRecord],
        grants: [YouziPermissionGrant],
        accounts: [YouziConnectionAccount] = [],
        bindings: [YouziConnectorBinding] = [],
        runtime: YouziExecutionPermissionRuntimeGate? = nil
    ) -> YouziExecutionPermissionEvaluation {
        evaluator.evaluate(
            subject: subject,
            requirement: requirement,
            permissionRecords: records,
            grants: grants,
            connectionAccounts: accounts,
            connectorBindings: bindings,
            runtime: runtime ?? networkRuntime(),
            now: now
        )
    }

    private func authorized(
        _ result: YouziExecutionPermissionEvaluation
    ) throws -> YouziExecutionPermissionAuthorization {
        guard case let .authorized(authorization) = result.outcome else {
            Issue.record("Expected authorization, got \(result.outcome)")
            throw AuthorizationError.notAuthorized
        }
        return authorization
    }

    private func networkRuntime(
        advertised: Bool = true,
        globalEnabled: Bool = true,
        toolEnabled: Bool = true,
        runtimeAvailable: Bool = true,
        approval: YouziExecutionLowLevelApproval = .approved
    ) -> YouziExecutionPermissionRuntimeGate {
        .init(
            toolName: "web_search",
            capabilityIdentifier: "builtin.web_search",
            advertisedForTurn: advertised,
            globallyEnabled: globalEnabled,
            toolEnabled: toolEnabled,
            runtimeAvailable: runtimeAvailable,
            lowLevelApproval: approval
        )
    }

    private func connectorRuntime(
        accountID: UUID,
        revision: Int,
        approval: YouziExecutionLowLevelApproval = .approved
    ) -> YouziExecutionPermissionRuntimeGate {
        .init(
            toolName: "calendar.read",
            connectionAccountID: accountID,
            bindingRevision: revision,
            advertisedForTurn: true,
            globallyEnabled: true,
            toolEnabled: true,
            runtimeAvailable: true,
            lowLevelApproval: approval
        )
    }

    private func connectionAccount(
        id: UUID,
        state: YouziConnectionState
    ) -> YouziConnectionAccount {
        .init(
            id: id,
            connectorID: self.id(6),
            displayName: "Calendar",
            state: state,
            createdAt: now.addingTimeInterval(-100),
            updatedAt: now.addingTimeInterval(-10)
        )
    }

    private func connectorBinding(id: UUID, revision: Int) -> YouziConnectorBinding {
        .init(
            id: id,
            runtime: .mcp(serverName: "calendar"),
            configurationRevision: revision,
            createdAt: now.addingTimeInterval(-100),
            updatedAt: now.addingTimeInterval(-10)
        )
    }

    private func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }

    private enum AuthorizationError: Error {
        case notAuthorized
    }
}
