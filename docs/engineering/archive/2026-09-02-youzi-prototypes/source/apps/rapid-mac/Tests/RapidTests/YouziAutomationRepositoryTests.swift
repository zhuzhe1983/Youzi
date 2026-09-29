import Foundation
import Testing
@testable import Rapid

@Suite("Youzi automation repository — CAS and occurrence claims")
struct YouziAutomationRepositoryTests {
    @Test("Create is fail-closed; confirm then scheduled claim is idempotent")
    func createConfirmAndClaim() throws {
        let runA = UUID()
        let runB = UUID()
        let fixture = try StoreFixture(ids: [runA, runB])
        defer { fixture.cleanup() }
        let automationID = UUID()
        let date = Date(timeIntervalSinceReferenceDate: 100)
        let draft = YouziAutomation(
            id: automationID,
            name: "Schedule",
            trigger: .schedule(cronExpression: "0 9 * * 1", timeZoneIdentifier: "Asia/Shanghai"),
            action: .init(request: "prepare", skillIDs: [], connectionAccountIDs: []),
            state: .active,
            confirmedAt: date,
            createdAt: date,
            updatedAt: date
        )

        let created = try fixture.repository.create(draft, at: date)
        #expect(created.automations[0].state == .draft)
        #expect(created.automations[0].confirmedAt == nil)
        let confirmed = try fixture.repository.confirm(
            id: automationID, expectedRevision: 1, grantIDs: [], at: date
        )
        #expect(confirmed.automations[0].state == .active)

        let occurrence = date.addingTimeInterval(3_600)
        let (first, _) = try fixture.repository.claimScheduledRun(
            automationID: automationID,
            revision: 1,
            scheduledFor: occurrence,
            at: occurrence
        )
        let (duplicate, duplicateDocument) = try fixture.repository.claimScheduledRun(
            automationID: automationID,
            revision: 1,
            scheduledFor: occurrence,
            at: occurrence.addingTimeInterval(1)
        )
        #expect(first.id == runA)
        #expect(duplicate.id == runA)
        #expect(duplicateDocument.automationRuns.count == 1)

        let (overlap, overlapDocument) = try fixture.repository.claimScheduledRun(
            automationID: automationID,
            revision: 1,
            scheduledFor: occurrence.addingTimeInterval(3_600),
            at: occurrence.addingTimeInterval(2)
        )
        #expect(overlap.id == runB)
        #expect(overlap.status == .skipped)
        #expect(overlapDocument.automationRuns.count == 2)
    }

    @Test("Confirm requires exact complete current-revision permission coverage")
    func confirmRequiresCompletePermissionScope() throws {
        let fixture = try StoreFixture(ids: [])
        defer { fixture.cleanup() }
        let date = Date(timeIntervalSinceReferenceDate: 150)
        let automationID = UUID()
        let requestIDs = [UUID(), UUID()]
        let grantIDs = [UUID(), UUID()]
        let requests = requestIDs.enumerated().map { offset, requestID in
            YouziPermissionRecord(
                id: requestID,
                automationID: automationID,
                automationRevision: 1,
                kind: .networkAccess,
                targetIdentifier: "api-\(offset).example.test",
                purpose: "Required scope \(offset)",
                duration: .persistent,
                requestedAt: date
            )
        }
        try fixture.store.save(
            YouziDomainDocument(
                permissions: requests,
                automations: [
                    YouziAutomation(
                        id: automationID,
                        name: "Complete scope",
                        trigger: .manual,
                        action: .init(request: "run", skillIDs: [], connectionAccountIDs: []),
                        permissionRecordIDs: requestIDs,
                        createdAt: date,
                        updatedAt: date
                    )
                ]
            )
        )

        let pendingBytes = try Data(contentsOf: fixture.fileURL)
        do {
            _ = try fixture.repository.confirm(
                id: automationID, expectedRevision: 1, grantIDs: [], at: date
            )
            Issue.record("Expected pending scope to reject empty confirmation")
        } catch let error as YouziAutomationRepositoryError {
            #expect(error == .incompletePermissionScope(automationID))
        }
        #expect(try Data(contentsOf: fixture.fileURL) == pendingBytes)

        _ = try fixture.store.update { document in
            for index in document.permissions.indices {
                document.permissions[index].decision = .allowed
                document.permissions[index].decidedAt = date
                document.permissionGrants.append(
                    YouziPermissionGrant(
                        id: grantIDs[index],
                        permissionRecordID: document.permissions[index].id,
                        automationID: automationID,
                        automationRevision: 1,
                        kind: document.permissions[index].kind,
                        targetIdentifier: document.permissions[index].targetIdentifier,
                        duration: .persistent,
                        grantedAt: date
                    )
                )
            }
        }
        let allowedBytes = try Data(contentsOf: fixture.fileURL)
        do {
            _ = try fixture.repository.confirm(
                id: automationID, expectedRevision: 1, grantIDs: [grantIDs[0]], at: date
            )
            Issue.record("Expected partial grant set to reject confirmation")
        } catch let error as YouziAutomationRepositoryError {
            #expect(error == .incompletePermissionScope(automationID))
        }
        #expect(try Data(contentsOf: fixture.fileURL) == allowedBytes)

        let confirmed = try fixture.repository.confirm(
            id: automationID,
            expectedRevision: 1,
            grantIDs: Array(grantIDs.reversed()),
            at: date
        )
        #expect(confirmed.automations[0].state == .active)
        #expect(confirmed.automations[0].permissionGrantIDs == grantIDs.sorted {
            $0.uuidString.lowercased() < $1.uuidString.lowercased()
        })
    }

    @Test("Run settlement uses status CAS, bounded retry, and exact terminal state")
    func settlementCAS() throws {
        let runID = UUID()
        let fixture = try StoreFixture(ids: [runID])
        defer { fixture.cleanup() }
        let taskID = UUID()
        let automationID = UUID()
        let date = Date(timeIntervalSinceReferenceDate: 200)
        try fixture.store.save(
            YouziDomainDocument(tasks: [YouziTask(id: taskID, title: "Task", request: "run")])
        )
        _ = try fixture.repository.create(
            YouziAutomation(
                id: automationID,
                name: "Retry",
                trigger: .manual,
                action: .init(request: "run", skillIDs: [], connectionAccountIDs: []),
                retryPolicy: .init(maximumAttempts: 2, baseDelaySeconds: 1),
                createdAt: date,
                updatedAt: date
            ),
            at: date
        )
        _ = try fixture.repository.confirm(
            id: automationID, expectedRevision: 1, grantIDs: [], at: date
        )
        let (run, _) = try fixture.repository.claimRunNow(
            automationID: automationID, at: date
        )
        #expect(run.id == runID)
        let running = try fixture.repository.settleRun(
            id: runID,
            expectedStatus: .queued,
            settlement: .running(taskID: taskID),
            at: date.addingTimeInterval(1)
        )
        #expect(running.automationRuns[0].attemptCount == 1)
        let retryAt = date.addingTimeInterval(3)
        _ = try fixture.repository.settleRun(
            id: runID,
            expectedStatus: .running,
            settlement: .retryScheduled(nextRetryAt: retryAt, recoveryCode: .runtimeUnavailable),
            at: date.addingTimeInterval(2)
        )
        _ = try fixture.repository.settleRun(
            id: runID,
            expectedStatus: .retryScheduled,
            settlement: .running(taskID: taskID),
            at: retryAt
        )
        let completed = try fixture.repository.settleRun(
            id: runID,
            expectedStatus: .running,
            settlement: .completed(taskID: taskID, summary: "done"),
            at: retryAt.addingTimeInterval(1)
        )
        #expect(completed.automationRuns[0].status == .completed)
        #expect(completed.automationRuns[0].attemptCount == 2)
        #expect(completed.automations[0].lastRunAt == retryAt.addingTimeInterval(1))

        let baseline = try Data(contentsOf: fixture.fileURL)
        do {
            _ = try fixture.repository.settleRun(
                id: runID,
                expectedStatus: .running,
                settlement: .cancelled(taskID: taskID),
                at: retryAt.addingTimeInterval(2)
            )
            Issue.record("Expected stale status CAS to fail")
        } catch let error as YouziAutomationRepositoryError {
            guard case let .statusConflict(expected, actual) = error else {
                Issue.record("Expected statusConflict, got \(error)")
                return
            }
            #expect(expected == .running)
            #expect(actual == .completed)
        }
        #expect(try Data(contentsOf: fixture.fileURL) == baseline)
    }

    @Test("Authority-changing revision revokes grants; audit sequence is unique")
    func revisionAndAuditIntegrity() throws {
        let fixture = try StoreFixture(ids: [])
        defer { fixture.cleanup() }
        let date = Date(timeIntervalSinceReferenceDate: 300)
        let taskID = UUID()
        let automationID = UUID()
        let requestID = UUID()
        let grantID = UUID()
        let permission = YouziPermissionRecord(
            id: requestID,
            automationID: automationID,
            automationRevision: 1,
            kind: .networkAccess,
            targetIdentifier: "api.example.test",
            purpose: "Automation",
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
            kind: .networkAccess,
            targetIdentifier: "api.example.test",
            duration: .persistent,
            grantedAt: date
        )
        try fixture.store.save(
            YouziDomainDocument(
                permissions: [permission],
                tasks: [YouziTask(id: taskID, title: "Task", request: "run")],
                permissionGrants: [grant],
                automations: [
                    YouziAutomation(
                        id: automationID,
                        name: "Automation",
                        trigger: .manual,
                        action: .init(request: "run", skillIDs: [], connectionAccountIDs: []),
                        permissionRecordIDs: [requestID],
                        permissionGrantIDs: [grantID],
                        state: .active,
                        confirmedAt: date,
                        createdAt: date,
                        updatedAt: date
                    )
                ]
            )
        )

        let renamed = try fixture.repository.revise(
            id: automationID,
            expectedRevision: 1,
            mutation: { $0.name = "Renamed" },
            at: date.addingTimeInterval(1)
        )
        #expect(renamed.automations[0].revision == 1)
        #expect(renamed.automations[0].permissionGrantIDs == [grantID])
        #expect(renamed.permissionGrants[0].revokedAt == nil)

        let revised = try fixture.repository.revise(
            id: automationID,
            expectedRevision: 1,
            mutation: { $0.action.request = "changed" },
            at: date.addingTimeInterval(2)
        )
        #expect(revised.automations[0].revision == 2)
        #expect(revised.automations[0].state == .needsAttention)
        #expect(revised.permissionGrants[0].revokedAt != nil)

        let event = YouziExecutionAuditEvent(
            sequence: 1,
            taskID: taskID,
            kind: .executionStarted,
            outcome: .allowed,
            occurredAt: date.addingTimeInterval(3)
        )
        _ = try fixture.repository.appendAudit(event)
        do {
            _ = try fixture.repository.appendAudit(
                YouziExecutionAuditEvent(
                    sequence: 1,
                    taskID: taskID,
                    kind: .executionCompleted,
                    outcome: .succeeded,
                    occurredAt: date.addingTimeInterval(4)
                )
            )
            Issue.record("Expected duplicate compact audit sequence rejection")
        } catch let error as YouziAutomationRepositoryError {
            guard case let .auditSequenceConflict(expected, actual) = error else {
                Issue.record("Expected auditSequenceConflict, got \(error)")
                return
            }
            #expect(expected == 2)
            #expect(actual == 1)
        }
    }

    private final class StoreFixture {
        let root: URL
        let fileURL: URL
        let store: YouziDomainStore
        let repository: YouziAutomationRepository

        init(ids: [UUID]) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("youzi-automation-repo-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            fileURL = root.appendingPathComponent("domain.json")
            let createdStore = YouziDomainStore(fileURL: fileURL)
            store = createdStore
            let idQueue = LockedIDQueue(ids)
            repository = YouziAutomationRepository(store: createdStore) { idQueue.next() }
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
