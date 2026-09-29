import Foundation
import Testing
@testable import Rapid

@Suite("Youzi permission repository — grant lifecycle")
struct YouziPermissionRepositoryTests {
    @Test("Allowed once request issues exactly one grant and consumes exactly once")
    func issueAndConsumeOnce() throws {
        let grantID = UUID()
        let fixture = try StoreFixture(ids: [grantID])
        defer { fixture.cleanup() }
        let taskID = UUID()
        let requestID = UUID()
        let date = Date(timeIntervalSinceReferenceDate: 100)
        try fixture.store.save(
            YouziDomainDocument(tasks: [YouziTask(id: taskID, title: "Task", request: "work")])
        )
        _ = try fixture.repository.request(
            YouziPermissionRecord(
                id: requestID,
                taskID: taskID,
                kind: .microphone,
                targetIdentifier: "microphone",
                purpose: "Dictation",
                duration: .once,
                requestedAt: date
            )
        )
        #expect(try fixture.store.load().tasks[0].permissionRecordIDs == [requestID])

        let (issued, decided) = try fixture.repository.decide(
            id: requestID,
            decision: .allowed,
            at: date.addingTimeInterval(1)
        )
        #expect(issued?.id == grantID)
        #expect(decided.permissions[0].decision == .allowed)
        #expect(decided.permissionGrants.count == 1)

        let consumed = try fixture.repository.consume(
            grantID: grantID,
            at: date.addingTimeInterval(2)
        )
        #expect(consumed.permissionGrants[0].consumedAt == date.addingTimeInterval(2))
        let baseline = try Data(contentsOf: fixture.fileURL)
        do {
            _ = try fixture.repository.consume(
                grantID: grantID,
                at: date.addingTimeInterval(3)
            )
            Issue.record("Expected second consume to fail")
        } catch let error as YouziPermissionRepositoryError {
            guard case .grantNotConsumable = error else {
                Issue.record("Expected grantNotConsumable, got \(error)")
                return
            }
        }
        #expect(try Data(contentsOf: fixture.fileURL) == baseline)
    }

    @Test("Task batch reuses exact pending requests and preserves decided history")
    func taskBatchRulesAndGrantBacklinks() throws {
        let onceGrantID = UUID()
        let taskGrantID = UUID()
        let fixture = try StoreFixture(ids: [onceGrantID, taskGrantID])
        defer { fixture.cleanup() }
        let taskID = UUID()
        let onceRequestID = UUID()
        let taskRequestID = UUID()
        let date = Date(timeIntervalSinceReferenceDate: 150)
        try fixture.store.save(
            YouziDomainDocument(tasks: [YouziTask(id: taskID, title: "Task", request: "work")])
        )

        let onceRequest = taskRequest(
            id: onceRequestID,
            taskID: taskID,
            kind: .microphone,
            target: "microphone",
            purpose: "Dictation",
            duration: .once,
            date: date
        )
        let taskRequest = taskRequest(
            id: taskRequestID,
            taskID: taskID,
            kind: .networkAccess,
            target: "builtin.web_search",
            purpose: "Search",
            duration: .task,
            date: date
        )
        let created = try fixture.repository.requestForTask(
            taskID: taskID,
            requests: [onceRequest, taskRequest]
        )
        #expect(created.permissionRecordIDs == [onceRequestID, taskRequestID])
        #expect(Set(created.document.tasks[0].permissionRecordIDs)
            == Set([onceRequestID, taskRequestID]))

        let reused = try fixture.repository.requestForTask(
            taskID: taskID,
            requests: [
                self.taskRequest(
                    id: UUID(), taskID: taskID, kind: .microphone,
                    target: "microphone", purpose: "Dictation", duration: .once,
                    date: date.addingTimeInterval(1)
                ),
                self.taskRequest(
                    id: UUID(), taskID: taskID, kind: .networkAccess,
                    target: "builtin.web_search", purpose: "Search", duration: .task,
                    date: date.addingTimeInterval(1)
                ),
            ]
        )
        #expect(reused.permissionRecordIDs == [onceRequestID, taskRequestID])
        #expect(reused.document.permissions.count == 2)

        let (onceGrant, _) = try fixture.repository.decide(
            id: onceRequestID, decision: .allowed, at: date.addingTimeInterval(2)
        )
        let (taskGrant, decided) = try fixture.repository.decide(
            id: taskRequestID, decision: .allowed, at: date.addingTimeInterval(2)
        )
        #expect(onceGrant?.id == onceGrantID)
        #expect(onceGrant?.duration == .once)
        #expect(taskGrant?.id == taskGrantID)
        #expect(taskGrant?.duration == .task)
        #expect(Set(decided.tasks[0].permissionRecordIDs) == Set([onceRequestID, taskRequestID]))

        let freshID = UUID()
        let afterDecision = try fixture.repository.requestForTask(
            taskID: taskID,
            requests: [
                self.taskRequest(
                    id: freshID, taskID: taskID, kind: .microphone,
                    target: "microphone", purpose: "Dictation", duration: .once,
                    date: date.addingTimeInterval(3)
                )
            ]
        )
        #expect(afterDecision.permissionRecordIDs == [freshID])
        #expect(afterDecision.document.permissions.count == 3)
        #expect(afterDecision.document.tasks[0].permissionRecordIDs.contains(freshID))

        let baseline = try Data(contentsOf: fixture.fileURL)
        do {
            _ = try fixture.repository.requestForTask(
                taskID: taskID,
                requests: [onceRequest]
            )
            Issue.record("Expected a decided request ID to remain immutable")
        } catch let error as YouziPermissionRepositoryError {
            #expect(error == .requestAlreadyDecided(onceRequestID))
        }
        #expect(try Data(contentsOf: fixture.fileURL) == baseline)
    }

    @Test("Invalid task request batch rolls back records and backlinks")
    func taskBatchRollback() throws {
        let fixture = try StoreFixture(ids: [])
        defer { fixture.cleanup() }
        let taskID = UUID()
        let date = Date(timeIntervalSinceReferenceDate: 175)
        try fixture.store.save(
            YouziDomainDocument(tasks: [YouziTask(id: taskID, title: "Task", request: "work")])
        )
        let baseline = try Data(contentsOf: fixture.fileURL)

        do {
            _ = try fixture.repository.requestForTask(
                taskID: taskID,
                requests: [
                    taskRequest(
                        id: UUID(), taskID: taskID, kind: .microphone,
                        target: "microphone", purpose: "Dictation", duration: .once,
                        date: date
                    ),
                    taskRequest(
                        id: UUID(), taskID: UUID(), kind: .networkAccess,
                        target: "builtin.web_search", purpose: "Search", duration: .task,
                        date: date
                    ),
                ]
            )
            Issue.record("Expected the mismatched task batch to fail")
        } catch let error as YouziPermissionRepositoryError {
            guard case .requestTaskMismatch = error else {
                Issue.record("Expected requestTaskMismatch, got \(error)")
                return
            }
        }

        #expect(try Data(contentsOf: fixture.fileURL) == baseline)
        let restored = try fixture.store.load()
        #expect(restored.permissions.isEmpty)
        #expect(restored.tasks[0].permissionRecordIDs.isEmpty)
    }

    @Test("Task plan allow and deny decisions are atomic and deterministically ordered")
    func taskPlanBatchDecision() throws {
        let lowRequestID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let highRequestID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let lowGrantID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let highGrantID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        let fixture = try StoreFixture(ids: [lowGrantID, highGrantID])
        defer { fixture.cleanup() }
        let taskID = UUID()
        let date = Date(timeIntervalSinceReferenceDate: 180)
        try fixture.store.save(
            YouziDomainDocument(tasks: [YouziTask(id: taskID, title: "Task", request: "work")])
        )
        _ = try fixture.repository.requestForTask(
            taskID: taskID,
            requests: [
                taskRequest(
                    id: highRequestID, taskID: taskID, kind: .networkAccess,
                    target: "builtin.web_search", purpose: "Search", duration: .task,
                    date: date
                ),
                taskRequest(
                    id: lowRequestID, taskID: taskID, kind: .microphone,
                    target: "microphone", purpose: "Dictation", duration: .once,
                    date: date
                ),
            ]
        )

        let allowed = try fixture.repository.decideForTask(
            taskID: taskID,
            requestIDs: [highRequestID, lowRequestID],
            decision: .allowed,
            at: date.addingTimeInterval(1)
        )
        #expect(allowed.grants.map(\.permissionRecordID) == [lowRequestID, highRequestID])
        #expect(allowed.grants.map(\.id) == [lowGrantID, highGrantID])
        #expect(allowed.grants.map(\.duration) == [.once, .task])
        #expect(allowed.document.permissions.allSatisfy { $0.decision == .allowed })

        let deniedFixture = try StoreFixture(ids: [])
        defer { deniedFixture.cleanup() }
        let deniedTaskID = UUID()
        let deniedRequestIDs = [UUID(), UUID()]
        try deniedFixture.store.save(
            YouziDomainDocument(
                tasks: [YouziTask(id: deniedTaskID, title: "Denied", request: "work")]
            )
        )
        _ = try deniedFixture.repository.requestForTask(
            taskID: deniedTaskID,
            requests: [
                taskRequest(
                    id: deniedRequestIDs[0], taskID: deniedTaskID, kind: .microphone,
                    target: "microphone", purpose: "Dictation", duration: .once,
                    date: date
                ),
                taskRequest(
                    id: deniedRequestIDs[1], taskID: deniedTaskID, kind: .networkAccess,
                    target: "builtin.web_search", purpose: "Search", duration: .task,
                    date: date
                ),
            ]
        )
        let denied = try deniedFixture.repository.decideForTask(
            taskID: deniedTaskID,
            requestIDs: Array(deniedRequestIDs.reversed()),
            decision: .denied,
            at: date.addingTimeInterval(1)
        )
        #expect(denied.grants.isEmpty)
        #expect(denied.document.permissionGrants.isEmpty)
        #expect(denied.document.permissions.allSatisfy { $0.decision == .denied })
    }

    @Test("Task plan grant collision leaves every request and byte unchanged")
    func taskPlanGrantCollisionRollsBack() throws {
        let collidingGrantID = UUID()
        let fixture = try StoreFixture(ids: [collidingGrantID, UUID()])
        defer { fixture.cleanup() }
        let taskID = UUID()
        let historicalRequestID = UUID()
        let pendingRequestIDs = [UUID(), UUID()]
        let date = Date(timeIntervalSinceReferenceDate: 190)
        let historicalRequest = taskRequest(
            id: historicalRequestID,
            taskID: taskID,
            kind: .networkAccess,
            target: "builtin.weather",
            purpose: "Weather",
            duration: .task,
            date: date
        )
        var allowedHistory = historicalRequest
        allowedHistory.decision = .allowed
        allowedHistory.decidedAt = date
        try fixture.store.save(
            YouziDomainDocument(
                permissions: [allowedHistory],
                tasks: [
                    YouziTask(
                        id: taskID,
                        title: "Task",
                        request: "work",
                        permissionRecordIDs: [historicalRequestID]
                    )
                ],
                permissionGrants: [
                    YouziPermissionGrant(
                        id: collidingGrantID,
                        permissionRecordID: historicalRequestID,
                        taskID: taskID,
                        kind: allowedHistory.kind,
                        targetIdentifier: allowedHistory.targetIdentifier,
                        duration: .task,
                        grantedAt: date
                    )
                ]
            )
        )
        _ = try fixture.repository.requestForTask(
            taskID: taskID,
            requests: [
                taskRequest(
                    id: pendingRequestIDs[0], taskID: taskID, kind: .microphone,
                    target: "microphone", purpose: "Dictation", duration: .once,
                    date: date
                ),
                taskRequest(
                    id: pendingRequestIDs[1], taskID: taskID, kind: .networkAccess,
                    target: "builtin.web_search", purpose: "Search", duration: .task,
                    date: date
                ),
            ]
        )
        let baseline = try Data(contentsOf: fixture.fileURL)

        do {
            _ = try fixture.repository.decideForTask(
                taskID: taskID,
                requestIDs: pendingRequestIDs,
                decision: .allowed,
                at: date.addingTimeInterval(1)
            )
            Issue.record("Expected the grant-ID collision to reject the batch")
        } catch let error as YouziPermissionRepositoryError {
            #expect(error == .grantIDConflict(collidingGrantID))
        }
        #expect(try Data(contentsOf: fixture.fileURL) == baseline)
        let restored = try fixture.store.load()
        #expect(restored.permissions.filter { pendingRequestIDs.contains($0.id) }
            .allSatisfy { $0.decision == .pending })
        #expect(restored.permissionGrants.count == 1)
    }

    @Test("Automation request preparation reuses pending scope without revision changes")
    func automationRequestPreparation() throws {
        let fixture = try StoreFixture(ids: [])
        defer { fixture.cleanup() }
        let automationID = UUID()
        let requestIDs = [UUID(), UUID()]
        let date = Date(timeIntervalSinceReferenceDate: 195)
        try fixture.store.save(
            YouziDomainDocument(
                automations: [
                    YouziAutomation(
                        id: automationID,
                        name: "Automation",
                        revision: 3,
                        trigger: .manual,
                        action: .init(request: "run", skillIDs: [], connectionAccountIDs: []),
                        state: .draft,
                        createdAt: date,
                        updatedAt: date
                    )
                ]
            )
        )
        let baseline = try Data(contentsOf: fixture.fileURL)
        do {
            _ = try fixture.repository.preparePermissionRequests(
                automationID: automationID,
                expectedRevision: 3,
                requests: [
                    automationRequest(
                        id: requestIDs[0], automationID: automationID, revision: 3,
                        kind: .microphone, target: "microphone", purpose: "Record",
                        duration: .persistent, date: date
                    ),
                    automationRequest(
                        id: requestIDs[1], automationID: automationID, revision: 3,
                        kind: .networkAccess, target: "builtin.web_search", purpose: "Search",
                        duration: .task, date: date
                    ),
                ]
            )
            Issue.record("Expected non-persistent automation scope to fail")
        } catch let error as YouziPermissionRepositoryError {
            #expect(error == .invalidAutomationRequestDuration(requestIDs[1]))
        }
        #expect(try Data(contentsOf: fixture.fileURL) == baseline)

        let prepared = try fixture.repository.preparePermissionRequests(
            automationID: automationID,
            expectedRevision: 3,
            requests: [
                automationRequest(
                    id: requestIDs[0], automationID: automationID, revision: 3,
                    kind: .microphone, target: "microphone", purpose: "Record",
                    duration: .persistent, date: date
                ),
                automationRequest(
                    id: requestIDs[1], automationID: automationID, revision: 3,
                    kind: .networkAccess, target: "builtin.web_search", purpose: "Search",
                    duration: .persistent, date: date
                ),
            ]
        )
        #expect(prepared.permissionRecordIDs == requestIDs)
        #expect(prepared.document.automations[0].revision == 3)
        #expect(Set(prepared.document.automations[0].permissionRecordIDs) == Set(requestIDs))

        let reused = try fixture.repository.preparePermissionRequests(
            automationID: automationID,
            expectedRevision: 3,
            requests: [
                automationRequest(
                    id: UUID(), automationID: automationID, revision: 3,
                    kind: .microphone, target: "microphone", purpose: "Record",
                    duration: .persistent, date: date.addingTimeInterval(1)
                ),
                automationRequest(
                    id: UUID(), automationID: automationID, revision: 3,
                    kind: .networkAccess, target: "builtin.web_search", purpose: "Search",
                    duration: .persistent, date: date.addingTimeInterval(1)
                ),
            ]
        )
        #expect(reused.permissionRecordIDs == requestIDs)
        #expect(reused.document.permissions.count == 2)
        #expect(reused.document.automations[0].revision == 3)
    }

    @Test("Automation batch decisions issue ordered grants that confirm by exact revision")
    func automationBatchDecisionAndConfirm() throws {
        let lowRequestID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
        let highRequestID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        let lowGrantID = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
        let highGrantID = UUID(uuidString: "30000000-0000-0000-0000-000000000002")!
        let fixture = try StoreFixture(ids: [lowGrantID, highGrantID])
        defer { fixture.cleanup() }
        let automationID = UUID()
        let date = Date(timeIntervalSinceReferenceDate: 197)
        try fixture.store.save(
            YouziDomainDocument(
                automations: [
                    YouziAutomation(
                        id: automationID,
                        name: "Automation",
                        trigger: .manual,
                        action: .init(request: "run", skillIDs: [], connectionAccountIDs: []),
                        state: .draft,
                        createdAt: date,
                        updatedAt: date
                    )
                ]
            )
        )
        _ = try fixture.repository.preparePermissionRequests(
            automationID: automationID,
            expectedRevision: 1,
            requests: [
                automationRequest(
                    id: highRequestID, automationID: automationID, revision: 1,
                    kind: .networkAccess, target: "builtin.web_search", purpose: "Search",
                    duration: .persistent, date: date
                ),
                automationRequest(
                    id: lowRequestID, automationID: automationID, revision: 1,
                    kind: .microphone, target: "microphone", purpose: "Record",
                    duration: .persistent, date: date
                ),
            ]
        )
        let allowed = try fixture.repository.decideForAutomation(
            automationID: automationID,
            expectedRevision: 1,
            requestIDs: [highRequestID, lowRequestID],
            decision: .allowed,
            at: date.addingTimeInterval(1)
        )
        #expect(allowed.grants.map(\.permissionRecordID) == [lowRequestID, highRequestID])
        #expect(allowed.grants.map(\.id) == [lowGrantID, highGrantID])
        #expect(allowed.grants.allSatisfy { $0.duration == .persistent })
        #expect(allowed.document.automations[0].revision == 1)
        #expect(allowed.document.automations[0].permissionGrantIDs.isEmpty)

        let automationRepository = YouziAutomationRepository(store: fixture.store)
        let confirmed = try automationRepository.confirm(
            id: automationID,
            expectedRevision: 1,
            grantIDs: Array(allowed.grants.map(\.id).reversed()),
            at: date.addingTimeInterval(2)
        )
        #expect(confirmed.automations[0].revision == 1)
        #expect(confirmed.automations[0].state == .active)
        #expect(Set(confirmed.automations[0].permissionGrantIDs)
            == Set([lowGrantID, highGrantID]))
    }

    @Test("Automation batch decision conflict preserves every pending byte")
    func automationBatchDecisionRollback() throws {
        let fixture = try StoreFixture(ids: [UUID(), UUID()])
        defer { fixture.cleanup() }
        let automationID = UUID()
        let requestIDs = [UUID(), UUID()]
        let date = Date(timeIntervalSinceReferenceDate: 199)
        try fixture.store.save(
            YouziDomainDocument(
                automations: [
                    YouziAutomation(
                        id: automationID,
                        name: "Automation",
                        trigger: .manual,
                        action: .init(request: "run", skillIDs: [], connectionAccountIDs: []),
                        state: .draft,
                        createdAt: date,
                        updatedAt: date
                    )
                ]
            )
        )
        _ = try fixture.repository.preparePermissionRequests(
            automationID: automationID,
            expectedRevision: 1,
            requests: requestIDs.map {
                automationRequest(
                    id: $0, automationID: automationID, revision: 1,
                    kind: .networkAccess, target: "builtin.\($0.uuidString.lowercased())",
                    purpose: "Network", duration: .persistent, date: date
                )
            }
        )
        _ = try fixture.repository.decide(
            id: requestIDs[0], decision: .denied, at: date.addingTimeInterval(1)
        )
        let baseline = try Data(contentsOf: fixture.fileURL)

        do {
            _ = try fixture.repository.decideForAutomation(
                automationID: automationID,
                expectedRevision: 1,
                requestIDs: requestIDs,
                decision: .allowed,
                at: date.addingTimeInterval(2)
            )
            Issue.record("Expected decided automation history to reject the whole batch")
        } catch let error as YouziPermissionRepositoryError {
            #expect(error == .requestAlreadyDecided(requestIDs[0]))
        }
        #expect(try Data(contentsOf: fixture.fileURL) == baseline)
        let restored = try fixture.store.load()
        #expect(restored.permissions.first(where: { $0.id == requestIDs[1] })?.decision == .pending)
        #expect(restored.permissionGrants.isEmpty)
    }

    @Test("Active automation permission scope changes bump once and revoke old authority")
    func activeAutomationPermissionScopeRevision() throws {
        let replacementGrantID = UUID()
        let fixture = try StoreFixture(ids: [replacementGrantID])
        defer { fixture.cleanup() }
        let connectorID = UUID()
        let accountID = UUID()
        let automationID = UUID()
        let oldRequestID = UUID()
        let oldGrantID = UUID()
        let newRequestID = UUID()
        let date = Date(timeIntervalSinceReferenceDate: 199.5)
        let target = accountID.uuidString.lowercased()
        let oldRequest = YouziPermissionRecord(
            id: oldRequestID,
            automationID: automationID,
            automationRevision: 1,
            kind: .connectorRead,
            targetIdentifier: target,
            purpose: "Read account",
            duration: .persistent,
            decision: .allowed,
            requestedAt: date,
            decidedAt: date
        )
        try fixture.store.save(
            YouziDomainDocument(
                permissions: [oldRequest],
                connectors: [
                    YouziConnector(
                        id: connectorID,
                        name: "Connector",
                        summary: "fixture",
                        adapter: .native,
                        authentication: .none,
                        source: .init(
                            kind: .builtIn,
                            identifier: "fixture.connector",
                            version: "1"
                        )
                    )
                ],
                connectionAccounts: [
                    YouziConnectionAccount(
                        id: accountID,
                        connectorID: connectorID,
                        displayName: "Account",
                        state: .connected
                    )
                ],
                connectorBindings: [
                    YouziConnectorBinding(
                        id: accountID,
                        runtime: .builtIn(capabilityIdentifier: "native.account"),
                        configurationRevision: 1
                    )
                ],
                permissionGrants: [
                    YouziPermissionGrant(
                        id: oldGrantID,
                        permissionRecordID: oldRequestID,
                        automationID: automationID,
                        automationRevision: 1,
                        kind: .connectorRead,
                        targetIdentifier: target,
                        targetRevision: 1,
                        duration: .persistent,
                        grantedAt: date
                    )
                ],
                automations: [
                    YouziAutomation(
                        id: automationID,
                        name: "Automation",
                        trigger: .manual,
                        action: .init(request: "run", skillIDs: [], connectionAccountIDs: []),
                        permissionRecordIDs: [oldRequestID],
                        permissionGrantIDs: [oldGrantID],
                        state: .active,
                        confirmedAt: date,
                        createdAt: date,
                        updatedAt: date
                    )
                ]
            )
        )

        let unchangedBaseline = try Data(contentsOf: fixture.fileURL)
        let unchanged = try fixture.repository.revisePermissionScope(
            automationID: automationID,
            expectedRevision: 1,
            requests: [
                automationRequest(
                    id: UUID(), automationID: automationID, revision: 1,
                    kind: .connectorRead, target: target, purpose: "Read account",
                    duration: .persistent, date: date.addingTimeInterval(1)
                )
            ],
            at: date.addingTimeInterval(1)
        )
        #expect(!unchanged.didChange)
        #expect(unchanged.revision == 1)
        #expect(unchanged.permissionRecordIDs == [oldRequestID])
        #expect(try Data(contentsOf: fixture.fileURL) == unchangedBaseline)

        let collisionBaseline = try Data(contentsOf: fixture.fileURL)
        do {
            _ = try fixture.repository.revisePermissionScope(
                automationID: automationID,
                expectedRevision: 1,
                requests: [
                    automationRequest(
                        id: oldRequestID, automationID: automationID, revision: 1,
                        kind: .connectorWrite, target: target, purpose: "Write account",
                        duration: .persistent, date: date.addingTimeInterval(2)
                    )
                ],
                at: date.addingTimeInterval(2)
            )
            Issue.record("Expected historical decided ID collision to roll back")
        } catch let error as YouziPermissionRepositoryError {
            #expect(error == .requestAlreadyDecided(oldRequestID))
        }
        #expect(try Data(contentsOf: fixture.fileURL) == collisionBaseline)

        let changed = try fixture.repository.revisePermissionScope(
            automationID: automationID,
            expectedRevision: 1,
            requests: [
                automationRequest(
                    id: newRequestID, automationID: automationID, revision: 1,
                    kind: .connectorWrite, target: target, purpose: "Write account",
                    duration: .persistent, date: date.addingTimeInterval(3)
                )
            ],
            at: date.addingTimeInterval(3)
        )
        #expect(changed.didChange)
        #expect(changed.revision == 2)
        #expect(changed.permissionRecordIDs == [newRequestID])
        #expect(changed.document.automations[0].revision == 2)
        #expect(changed.document.automations[0].state == .needsAttention)
        #expect(changed.document.automations[0].confirmedAt == nil)
        #expect(changed.document.automations[0].permissionGrantIDs.isEmpty)
        #expect(changed.document.permissionGrants.first(where: { $0.id == oldGrantID })?.revokedAt
            == date.addingTimeInterval(3))
        #expect(changed.document.permissions.first(where: { $0.id == newRequestID })?
            .automationRevision == 2)

        let allowed = try fixture.repository.decideForAutomation(
            automationID: automationID,
            expectedRevision: 2,
            requestIDs: [newRequestID],
            decision: .allowed,
            at: date.addingTimeInterval(4)
        )
        let automationRepository = YouziAutomationRepository(store: fixture.store)
        _ = try automationRepository.confirm(
            id: automationID,
            expectedRevision: 2,
            grantIDs: allowed.grants.map(\.id),
            at: date.addingTimeInterval(5)
        )
        let removed = try fixture.repository.revisePermissionScope(
            automationID: automationID,
            expectedRevision: 2,
            requests: [],
            at: date.addingTimeInterval(6)
        )
        #expect(removed.didChange)
        #expect(removed.revision == 3)
        #expect(removed.permissionRecordIDs.isEmpty)
        #expect(removed.document.automations[0].permissionGrantIDs.isEmpty)
        #expect(removed.document.permissionGrants.allSatisfy { $0.revokedAt != nil })
    }

    @Test("Connector grants capture binding revision and denial issues no authority")
    func connectorRevisionAndDenial() throws {
        let grantID = UUID()
        let fixture = try StoreFixture(ids: [grantID])
        defer { fixture.cleanup() }
        let connectorID = UUID()
        let accountID = UUID()
        let taskID = UUID()
        let allowedID = UUID()
        let deniedID = UUID()
        let date = Date(timeIntervalSinceReferenceDate: 200)
        let target = accountID.uuidString.lowercased()
        try fixture.store.save(
            YouziDomainDocument(
                tasks: [YouziTask(id: taskID, title: "Task", request: "work")],
                connectors: [
                    YouziConnector(
                        id: connectorID,
                        name: "Connector",
                        summary: "fixture",
                        adapter: .native,
                        authentication: .apiKey,
                        source: .init(kind: .builtIn, identifier: "fixture.connector", version: "1")
                    )
                ],
                connectionAccounts: [
                    YouziConnectionAccount(id: accountID, connectorID: connectorID, displayName: "A")
                ],
                connectorBindings: [
                    YouziConnectorBinding(
                        id: accountID,
                        runtime: .builtIn(capabilityIdentifier: "native.lookup"),
                        configurationRevision: 7
                    )
                ]
            )
        )
        _ = try fixture.repository.request(
            YouziPermissionRecord(
                id: allowedID,
                taskID: taskID,
                kind: .connectorRead,
                targetIdentifier: target,
                purpose: "Lookup",
                duration: .task,
                requestedAt: date
            )
        )
        let (issued, _) = try fixture.repository.decide(
            id: allowedID, decision: .allowed, at: date
        )
        #expect(issued?.targetRevision == 7)

        _ = try fixture.repository.request(
            YouziPermissionRecord(
                id: deniedID,
                taskID: taskID,
                kind: .networkAccess,
                targetIdentifier: "api.example.test",
                purpose: "Network",
                requestedAt: date
            )
        )
        let (deniedGrant, denied) = try fixture.repository.decide(
            id: deniedID, decision: .denied, at: date
        )
        #expect(deniedGrant == nil)
        #expect(denied.permissionGrants.count == 1)
    }

    @Test("Revoking one automation grant revokes attached authority and bumps revision")
    func revokeInvalidatesAutomation() throws {
        let fixture = try StoreFixture(ids: [])
        defer { fixture.cleanup() }
        let date = Date(timeIntervalSinceReferenceDate: 300)
        let automationID = UUID()
        let requestA = UUID()
        let requestB = UUID()
        let grantA = UUID()
        let grantB = UUID()
        let permissionA = automationPermission(
            id: requestA, automationID: automationID, kind: .microphone,
            target: "microphone", date: date
        )
        let permissionB = automationPermission(
            id: requestB, automationID: automationID, kind: .networkAccess,
            target: "api.example.test", date: date
        )
        let authorityA = automationGrant(
            id: grantA, request: permissionA, automationID: automationID, date: date
        )
        let authorityB = automationGrant(
            id: grantB, request: permissionB, automationID: automationID, date: date
        )
        try fixture.store.save(
            YouziDomainDocument(
                permissions: [permissionA, permissionB],
                permissionGrants: [authorityA, authorityB],
                automations: [
                    YouziAutomation(
                        id: automationID,
                        name: "Automation",
                        trigger: .manual,
                        action: .init(request: "run", skillIDs: [], connectionAccountIDs: []),
                        permissionRecordIDs: [requestA, requestB],
                        permissionGrantIDs: [grantA, grantB],
                        state: .active,
                        confirmedAt: date,
                        createdAt: date,
                        updatedAt: date
                    )
                ]
            )
        )

        let revoked = try fixture.repository.revoke(
            grantID: grantA,
            at: date.addingTimeInterval(1)
        )

        #expect(revoked.permissionGrants.allSatisfy { $0.revokedAt != nil })
        #expect(revoked.automations[0].revision == 2)
        #expect(revoked.automations[0].permissionGrantIDs.isEmpty)
        #expect(revoked.automations[0].state == .needsAttention)
        #expect(revoked.automations[0].confirmedAt == nil)
    }

    private func automationPermission(
        id: UUID,
        automationID: UUID,
        kind: YouziPermissionKind,
        target: String,
        date: Date
    ) -> YouziPermissionRecord {
        YouziPermissionRecord(
            id: id,
            automationID: automationID,
            automationRevision: 1,
            kind: kind,
            targetIdentifier: target,
            purpose: "Automation authority",
            duration: .persistent,
            decision: .allowed,
            requestedAt: date,
            decidedAt: date
        )
    }

    private func taskRequest(
        id: UUID,
        taskID: UUID,
        kind: YouziPermissionKind,
        target: String,
        purpose: String,
        duration: YouziPermissionDuration,
        date: Date
    ) -> YouziPermissionRecord {
        YouziPermissionRecord(
            id: id,
            taskID: taskID,
            kind: kind,
            targetIdentifier: target,
            purpose: purpose,
            duration: duration,
            requestedAt: date
        )
    }

    private func automationRequest(
        id: UUID,
        automationID: UUID,
        revision: Int,
        kind: YouziPermissionKind,
        target: String,
        purpose: String,
        duration: YouziPermissionDuration,
        date: Date
    ) -> YouziPermissionRecord {
        YouziPermissionRecord(
            id: id,
            automationID: automationID,
            automationRevision: revision,
            kind: kind,
            targetIdentifier: target,
            purpose: purpose,
            duration: duration,
            requestedAt: date
        )
    }

    private func automationGrant(
        id: UUID,
        request: YouziPermissionRecord,
        automationID: UUID,
        date: Date
    ) -> YouziPermissionGrant {
        YouziPermissionGrant(
            id: id,
            permissionRecordID: request.id,
            automationID: automationID,
            automationRevision: 1,
            kind: request.kind,
            targetIdentifier: request.targetIdentifier,
            duration: .persistent,
            grantedAt: date
        )
    }

    private final class StoreFixture {
        let root: URL
        let fileURL: URL
        let store: YouziDomainStore
        let repository: YouziPermissionRepository

        init(ids: [UUID]) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("youzi-permission-repo-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            fileURL = root.appendingPathComponent("domain.json")
            let createdStore = YouziDomainStore(fileURL: fileURL)
            store = createdStore
            let idQueue = LockedIDQueue(ids)
            repository = YouziPermissionRepository(store: createdStore) { idQueue.next() }
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    private final class LockedIDQueue: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [UUID]

        init(_ ids: [UUID]) { self.ids = ids }

        func next() -> UUID {
            lock.lock()
            defer { lock.unlock() }
            return ids.isEmpty ? UUID() : ids.removeFirst()
        }
    }
}
