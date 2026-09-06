import Foundation
import Testing
@testable import Rapid

@Suite("YouziDomain — v3 graph integrity")
struct YouziDomainIntegrityValidatorTests {
    @Test("A conversation can belong to at most one persisted task")
    func duplicateConversationOwnership() throws {
        let conversationID = UUID()
        let firstTaskID = UUID()
        let secondTaskID = UUID()

        do {
            try YouziDomainIntegrityValidator.validate(.init(tasks: [
                YouziTask(
                    id: firstTaskID,
                    title: "First",
                    request: "first",
                    conversationID: conversationID
                ),
                YouziTask(
                    id: secondTaskID,
                    title: "Second",
                    request: "second",
                    conversationID: conversationID
                ),
            ]))
            Issue.record("Expected duplicate conversation ownership to fail")
        } catch let error as YouziDomainIntegrityError {
            #expect(error.issues.contains {
                $0.code == .duplicateConversationID
                    && $0.recordID == secondTaskID
                    && $0.relatedID == firstTaskID
            })
        }
    }

    @Test("Dangling and duplicate references are rejected before bytes change")
    func rejectionIsAtomic() throws {
        let fixture = try StoreFixture()
        defer { fixture.cleanup() }
        try fixture.store.save(.empty)
        let baseline = try Data(contentsOf: fixture.fileURL)
        let taskID = UUID()
        let missingWorkspaceID = UUID()

        do {
            _ = try fixture.store.update { document in
                document.tasks.append(
                    YouziTask(
                        id: taskID,
                        title: "Invalid",
                        request: "dangling and duplicate",
                        workspaceID: missingWorkspaceID,
                        skillIDs: [UUID(), UUID()]
                    )
                )
                document.tasks.append(
                    YouziTask(id: taskID, title: "Duplicate", request: "same id")
                )
            }
            Issue.record("Expected whole-graph validation to reject the transaction")
        } catch let error as YouziDomainStoreError {
            guard case let .invalidDocument(issues) = error else {
                Issue.record("Expected invalidDocument, got \(error)")
                return
            }
            let codes = Set(issues.map(\.code))
            #expect(codes.contains(.duplicateRecordID))
            #expect(codes.contains(.danglingReference))
        }

        #expect(try Data(contentsOf: fixture.fileURL) == baseline)
    }

    @Test("Credentials, package traversal, and invalid digests fail with redacted errors")
    func securityBoundariesAreRedacted() throws {
        let connectorID = UUID()
        let accountID = UUID()
        let skillID = UUID()
        let secret = "CREDENTIAL_SENTINEL_DO_NOT_PERSIST"
        let source = YouziManifestSource(kind: .localPackage, identifier: "local.skill", version: "1")
        let document = YouziDomainDocument(
            skills: [
                YouziSkill(
                    id: skillID,
                    name: "Unsafe",
                    summary: "unsafe fixture",
                    packageVersion: "1",
                    source: source
                )
            ],
            skillPackages: [
                YouziSkillPackageRecord(
                    id: skillID,
                    location: .appManaged(relativePath: "../escape"),
                    packageVersion: "1",
                    contentSHA256: "NOT-A-DIGEST"
                )
            ],
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
                YouziConnectionAccount(
                    id: accountID,
                    connectorID: connectorID,
                    displayName: "Account",
                    credentialReference: secret
                )
            ]
        )

        do {
            try YouziDomainIntegrityValidator.validate(document)
            Issue.record("Expected security validation failure")
        } catch let error as YouziDomainIntegrityError {
            let codes = Set(error.issues.map(\.code))
            #expect(codes.contains(.invalidCredentialReference))
            #expect(codes.contains(.invalidPath))
            #expect(codes.contains(.invalidDigest))
            #expect(!error.localizedDescription.contains(secret))
            #expect(!error.localizedDescription.contains("../escape"))
        }
    }

    @Test("V3 tagged unions and canonical record order have stable wire bytes")
    func taggedWireAndCanonicalOrder() throws {
        let earlier = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let later = UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!
        let date = Date(timeIntervalSinceReferenceDate: 42)
        let automation = YouziAutomation(
            id: later,
            name: "Interval",
            trigger: .interval(seconds: 300, anchorAt: date),
            action: .init(request: "run", skillIDs: [], connectionAccountIDs: []),
            createdAt: date,
            updatedAt: date
        )
        var document = YouziDomainDocument(
            tasks: [
                YouziTask(id: later, title: "Later", request: "later"),
                YouziTask(id: earlier, title: "Earlier", request: "earlier"),
            ],
            automations: [automation]
        )
        document.canonicalizeRecordOrder()

        #expect(document.tasks.map(\.id) == [earlier, later])
        let data = try JSONEncoder().encode(automation)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let trigger = try #require(object["trigger"] as? [String: Any])
        #expect(trigger["kind"] as? String == "interval")
        #expect(trigger["seconds"] as? Double == 300)
        #expect(trigger["interval"] == nil)
        #expect(trigger["anchorAt"] != nil)

        let workspaceData = try JSONEncoder().encode(
            YouziWorkspace(
                id: earlier,
                name: "Workspace",
                location: .managed(relativePath: earlier.uuidString.lowercased()),
                createdAt: date,
                updatedAt: date
            )
        )
        let workspaceObject = try #require(
            JSONSerialization.jsonObject(with: workspaceData) as? [String: Any]
        )
        let workspaceLocation = try #require(workspaceObject["location"] as? [String: Any])
        #expect(workspaceLocation["kind"] as? String == "managed")
        #expect(workspaceLocation["managed"] == nil)

        let fileData = try JSONEncoder().encode(
            YouziFile(
                displayName: "input.txt",
                role: .taskInput,
                location: .workspace(workspaceID: earlier, relativePath: "Inputs/input.txt"),
                createdAt: date,
                updatedAt: date
            )
        )
        let fileObject = try #require(JSONSerialization.jsonObject(with: fileData) as? [String: Any])
        let fileLocation = try #require(fileObject["location"] as? [String: Any])
        #expect(fileLocation["kind"] as? String == "workspace")
        #expect(fileLocation["workspaceID"] as? String == earlier.uuidString.uppercased())

        let memoryData = try JSONEncoder().encode(
            YouziMemoryNode(
                label: "Topic",
                content: "content",
                kind: .topic,
                confidence: 1,
                scope: .project(earlier),
                creationMethod: .manual,
                createdAt: date,
                updatedAt: date
            )
        )
        let memoryObject = try #require(
            JSONSerialization.jsonObject(with: memoryData) as? [String: Any]
        )
        let memoryScope = try #require(memoryObject["scope"] as? [String: Any])
        #expect(memoryScope["kind"] as? String == "project")
        #expect(memoryScope["projectID"] as? String == earlier.uuidString.uppercased())
    }

    @Test("Explicit-empty task selections survive durable v3 round trip")
    func taskSelectionIntentRoundTrip() throws {
        let task = YouziTask(
            title: "No defaults",
            request: "Run without inherited capabilities",
            helperSelectionIntent: .explicit,
            skillSelectionIntent: .explicit,
            connectionAccountSelectionIntent: .explicit
        )
        let data = try JSONEncoder().encode(task)
        let restored = try JSONDecoder().decode(YouziTask.self, from: data)

        #expect(restored.helperID == nil)
        #expect(restored.skillIDs.isEmpty)
        #expect(restored.connectionAccountIDs.isEmpty)
        #expect(restored.helperSelectionIntent == .explicit)
        #expect(restored.skillSelectionIntent == .explicit)
        #expect(restored.connectionAccountSelectionIntent == .explicit)
    }

    @Test("Run state and compact audit sequence invariants reject malformed direct saves")
    func runAndAuditStateInvariants() throws {
        let date = Date(timeIntervalSinceReferenceDate: 500)
        let taskID = UUID()
        let automationID = UUID()
        let automation = YouziAutomation(
            id: automationID,
            name: "Automation",
            trigger: .manual,
            action: .init(request: "run", skillIDs: [], connectionAccountIDs: []),
            confirmedAt: date,
            createdAt: date,
            updatedAt: date
        )
        let malformedRun = YouziAutomationRun(
            automationID: automationID,
            automationRevision: 1,
            attemptCount: 1,
            status: .queued,
            createdAt: date,
            startedAt: date
        )
        let events = [
            YouziExecutionAuditEvent(
                sequence: 1,
                taskID: taskID,
                kind: .executionStarted,
                outcome: .allowed,
                occurredAt: date.addingTimeInterval(2)
            ),
            YouziExecutionAuditEvent(
                sequence: 3,
                taskID: taskID,
                kind: .executionCompleted,
                outcome: .succeeded,
                occurredAt: date.addingTimeInterval(1)
            ),
            YouziExecutionAuditEvent(
                sequence: 3,
                taskID: taskID,
                kind: .executionFailed,
                outcome: .failed,
                occurredAt: date.addingTimeInterval(1)
            ),
        ]

        do {
            try YouziDomainIntegrityValidator.validate(
                YouziDomainDocument(
                    tasks: [YouziTask(id: taskID, title: "Task", request: "run")],
                    automations: [automation],
                    automationRuns: [malformedRun],
                    executionAuditEvents: events
                )
            )
            Issue.record("Expected run/audit invariant failure")
        } catch let error as YouziDomainIntegrityError {
            let codes = Set(error.issues.map(\.code))
            #expect(codes.contains(.invalidState))
            #expect(codes.contains(.invalidRevision))
            #expect(codes.contains(.invalidTimestamp))
            #expect(codes.contains(.duplicateAuditSequence))
        }
    }

    @Test("Automation run grant snapshots reject foreign subjects and revisions")
    func runGrantSnapshotSubjectAndRevision() throws {
        let date = Date(timeIntervalSinceReferenceDate: 600)
        let automationID = UUID()
        let foreignAutomationID = UUID()
        let requestID = UUID()
        let grantID = UUID()
        let permission = YouziPermissionRecord(
            id: requestID,
            automationID: foreignAutomationID,
            automationRevision: 2,
            kind: .networkAccess,
            targetIdentifier: "api.example.test",
            purpose: "Foreign authority",
            duration: .persistent,
            decision: .allowed,
            requestedAt: date,
            decidedAt: date
        )
        let grant = YouziPermissionGrant(
            id: grantID,
            permissionRecordID: requestID,
            automationID: foreignAutomationID,
            automationRevision: 2,
            kind: .networkAccess,
            targetIdentifier: "api.example.test",
            duration: .persistent,
            grantedAt: date
        )
        let run = YouziAutomationRun(
            automationID: automationID,
            automationRevision: 1,
            permissionGrantIDs: [grantID],
            attemptCount: 0,
            status: .queued,
            createdAt: date,
            startedAt: nil
        )
        let document = YouziDomainDocument(
            permissions: [permission],
            permissionGrants: [grant],
            automations: [
                YouziAutomation(
                    id: automationID,
                    name: "Run owner",
                    trigger: .manual,
                    action: .init(request: "run", skillIDs: [], connectionAccountIDs: []),
                    createdAt: date,
                    updatedAt: date
                ),
                YouziAutomation(
                    id: foreignAutomationID,
                    name: "Grant owner",
                    revision: 2,
                    trigger: .manual,
                    action: .init(request: "run", skillIDs: [], connectionAccountIDs: []),
                    permissionRecordIDs: [requestID],
                    permissionGrantIDs: [grantID],
                    state: .active,
                    confirmedAt: date,
                    createdAt: date,
                    updatedAt: date
                ),
            ],
            automationRuns: [run]
        )

        do {
            try YouziDomainIntegrityValidator.validate(document)
            Issue.record("Expected foreign run grant snapshot rejection")
        } catch let error as YouziDomainIntegrityError {
            #expect(error.issues.contains {
                $0.code == .invalidGrant && $0.recordID == run.id && $0.relatedID == grantID
            })
        }
    }

    private final class StoreFixture {
        let root: URL
        let fileURL: URL
        let store: YouziDomainStore

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("youzi-integrity-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            fileURL = root.appendingPathComponent("domain.json")
            store = YouziDomainStore(fileURL: fileURL)
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
}
