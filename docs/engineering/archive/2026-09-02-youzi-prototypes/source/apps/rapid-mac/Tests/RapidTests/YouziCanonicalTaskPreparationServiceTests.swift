import Foundation
import Testing
@testable import Rapid

@MainActor
@Suite("Youzi canonical task preparation")
struct YouziCanonicalTaskPreparationServiceTests {
    @Test("Automation retry reuses the task persisted on its exact run")
    func automationPrepareIsIdempotent() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let request = fixture.request()

        let first = fixture.service.prepare(request)
        let second = fixture.service.prepare(request)
        let firstID = try readyTaskID(first)
        let secondID = try readyTaskID(second)

        #expect(firstID == fixture.taskID)
        #expect(secondID == firstID)
        let document = try fixture.store.load()
        #expect(document.tasks.filter { $0.id == firstID }.count == 1)
        #expect(document.automationRuns.first?.taskID == firstID)
        #expect(document.tasks.first?.conversationID == firstID)
        #expect(document.tasks.first?.helperSelectionIntent == .explicit)
        #expect(document.tasks.first?.skillSelectionIntent == .explicit)
        #expect(document.tasks.first?.connectionAccountSelectionIntent == .explicit)
        #expect(document.tasks.first?.workspaceID != nil)
    }

    @Test("Automation retry rejects a persisted task whose conversation identity drifted")
    func automationRetryRejectsConversationIdentityDrift() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let request = fixture.request()
        #expect(fixture.service.prepare(request) == .ready(taskID: fixture.taskID))
        _ = try fixture.store.update { document in
            document.tasks[0].conversationID = UUID()
        }

        #expect(fixture.service.prepare(request)
            == .unavailable(recoveryCode: .automationRevisionChanged))
        let document = try fixture.store.load()
        #expect(document.tasks.count == 1)
        #expect(document.automationRuns.first?.taskID == fixture.taskID)
    }

    @Test("Changed revision, action, or grant snapshot cannot reuse a scheduled task")
    func frozenAutomationIdentityFailsClosed() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }

        var changedAction = fixture.action
        changedAction.request = "different request"
        let actionMismatch = fixture.service.prepare(.init(
            origin: fixture.origin,
            input: .automationAction(changedAction),
            permissionGrantIDs: fixture.grantIDs
        ))
        #expect(actionMismatch == .unavailable(recoveryCode: .automationRevisionChanged))

        let grantMismatch = fixture.service.prepare(.init(
            origin: fixture.origin,
            input: .automationAction(fixture.action),
            permissionGrantIDs: []
        ))
        #expect(grantMismatch == .unavailable(recoveryCode: .automationRevisionChanged))

        let revisionMismatch = fixture.service.prepare(.init(
            origin: .automation(
                automationID: fixture.automationID,
                revision: 2,
                runID: fixture.runID
            ),
            input: .automationAction(fixture.action),
            permissionGrantIDs: fixture.grantIDs
        ))
        #expect(revisionMismatch == .unavailable(recoveryCode: .automationRevisionChanged))
        #expect(try fixture.store.load().tasks.isEmpty)
    }

    @Test("Interactive preparation preserves the existing task and creates one workspace")
    func interactivePrepare() throws {
        let fixture = try Fixture(interactiveOnly: true)
        defer { fixture.cleanup() }
        let request = YouziTaskExecutionRequest(
            origin: .interactive,
            input: .existingTask(taskID: fixture.taskID),
            permissionGrantIDs: []
        )

        #expect(fixture.service.prepare(request) == .ready(taskID: fixture.taskID))
        #expect(fixture.service.prepare(request) == .ready(taskID: fixture.taskID))
        let document = try fixture.store.load()
        #expect(document.tasks.count == 1)
        #expect(document.workspaces.count == 1)
        #expect(document.tasks.first?.workspaceID == document.workspaces.first?.id)
    }

    private func readyTaskID(_ value: YouziTaskExecutionPreparation) throws -> UUID {
        guard case .ready(let taskID) = value else {
            Issue.record("Expected ready preparation, got \(value)")
            throw PreparationTestFailure.notReady
        }
        return taskID
    }
}

private enum PreparationTestFailure: Error { case notReady }

@MainActor
private final class Fixture {
    let root: URL
    let store: YouziDomainStore
    let productModel: YouziProductModel
    let service: YouziCanonicalTaskPreparationService
    let taskID = Fixture.id(90)
    let automationID = Fixture.id(91)
    let runID = Fixture.id(92)
    let grantIDs: [UUID]
    let action: YouziAutomationAction
    let origin: YouziTaskExecutionOrigin
    private let now = Date(timeIntervalSince1970: 2_000_000)

    init(interactiveOnly: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "youzi-canonical-preparation-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = YouziDomainStore(fileURL: root.appendingPathComponent("domain.json"))
        productModel = YouziProductModel(store: store)
        grantIDs = interactiveOnly ? [] : [Self.id(93)]
        action = .init(request: "Prepare a brief", skillIDs: [], connectionAccountIDs: [])
        origin = .automation(automationID: automationID, revision: 1, runID: runID)
        let workspaceAccess = YouziWorkspaceAccessCoordinator(
            managedRoot: root.appendingPathComponent("workspaces", isDirectory: true)
        )
        service = YouziCanonicalTaskPreparationService(
            store: store,
            productModel: productModel,
            lifecycle: YouziLifecycleRepository(
                store: store,
                workspaceAccess: workspaceAccess
            ),
            idGenerator: { Self.id(90) },
            now: { Date(timeIntervalSince1970: 2_000_000) }
        )

        if interactiveOnly {
            try store.save(YouziDomainDocument(tasks: [
                YouziTask(id: taskID, title: "Interactive", request: "Help me")
            ]))
            productModel.refresh()
            return
        }

        let record = YouziPermissionRecord(
            id: Self.id(94), automationID: automationID, automationRevision: 1,
            kind: .networkAccess, targetIdentifier: "builtin.network",
            purpose: "Scheduled research", duration: .persistent,
            decision: .allowed, requestedAt: now.addingTimeInterval(-20),
            decidedAt: now.addingTimeInterval(-15)
        )
        let grant = YouziPermissionGrant(
            id: grantIDs[0], permissionRecordID: record.id,
            automationID: automationID, automationRevision: 1,
            kind: .networkAccess, targetIdentifier: "builtin.network",
            duration: .persistent, grantedAt: now.addingTimeInterval(-10)
        )
        let automation = YouziAutomation(
            id: automationID, name: "Morning brief", revision: 1,
            trigger: .manual, action: action,
            permissionRecordIDs: [record.id], permissionGrantIDs: grantIDs,
            state: .active, confirmedAt: now, createdAt: now, updatedAt: now
        )
        let run = YouziAutomationRun(
            id: runID, automationID: automationID, automationRevision: 1,
            permissionGrantIDs: grantIDs, retryPolicy: .init(),
            attemptCount: 0, status: .queued,
            createdAt: now, startedAt: nil
        )
        try store.save(.init(
            permissions: [record], permissionGrants: [grant],
            automations: [automation], automationRuns: [run]
        ))
        productModel.refresh()
    }

    func request() -> YouziTaskExecutionRequest {
        .init(
            origin: origin,
            input: .automationAction(action),
            permissionGrantIDs: grantIDs
        )
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    nonisolated private static func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }
}
