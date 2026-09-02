import Foundation
import Testing
@testable import Rapid

@Suite("YouziDomain — frozen v1 to v2 migration")
struct YouziDomainMigrationTests {
    private final class FailingCreateFileManager: FileManager, @unchecked Sendable {
        override func createFile(
            atPath path: String,
            contents data: Data?,
            attributes attr: [FileAttributeKey: Any]? = nil
        ) -> Bool {
            false
        }
    }

    private struct LegacyEnvelope: Encodable {
        let formatIdentifier = YouziDomainSchema.formatIdentifier
        let schemaVersion = 1
        var document: LegacyDocument
    }

    private struct LegacyDocument: Encodable {
        var permissions: [YouziPermissionRecord] = []
        var tasks: [LegacyTask]
        var workspaces: [YouziWorkspace]
        var projects: [LegacyProject]
        var helpers: [YouziHelper] = []
        var skills: [YouziSkill] = []
        var connectors: [YouziConnector] = []
        var connectionAccounts: [YouziConnectionAccount] = []
        var artifacts: [LegacyArtifact]
        var templates: [YouziTemplate] = []
        var automations: [YouziAutomation] = []
        var automationRuns: [YouziAutomationRun] = []
        var memoryNodes: [YouziMemoryNode] = []
        var memoryEdges: [YouziMemoryEdge] = []
        var memoryCitations: [YouziMemoryCitation] = []
        var voiceSessions: [YouziVoiceSession] = []
    }

    private struct LegacyTask: Encodable {
        let id: UUID
        var title: String
        var request: String
        var conversationID: UUID?
        var workspaceID: UUID?
        var projectID: UUID?
        var helperID: UUID?
        var skillIDs: [UUID]
        var connectionAccountIDs: [UUID]
        var permissionRecordIDs: [UUID]
        var artifactIDs: [UUID]
        var status: YouziTaskStatus
        var failureSummary: String?
        var isPinned: Bool
        let createdAt: Date
        var updatedAt: Date
        var completedAt: Date?
    }

    private struct LegacyProject: Encodable {
        let id: UUID
        var name: String
        var summary: String
        var instructions: String
        var preferences: [String: String]
        var defaultHelperIDs: [UUID]
        var defaultSkillIDs: [UUID]
        var defaultConnectionAccountIDs: [UUID]
        var state: YouziRecordState
        let createdAt: Date
        var updatedAt: Date
    }

    private enum LegacyArtifactLocation: Encodable {
        case workspace(workspaceID: UUID, relativePath: String)
        case appManaged(relativePath: String)
        case securityScopedBookmark(data: Data, displayPath: String)
    }

    private struct LegacyArtifact: Encodable {
        let id: UUID
        var taskID: UUID
        var projectID: UUID?
        var title: String
        var kind: YouziArtifactKind
        var previewText: String?
        var location: LegacyArtifactLocation
        var state: YouziRecordState
        let createdAt: Date
        var updatedAt: Date
    }

    private func fixture() throws -> (Data, UUID, UUID, UUID, UUID) {
        let taskID = UUID()
        let artifactID = UUID()
        let workspaceID = UUID()
        let projectID = UUID()
        let conversationID = UUID()
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let updated = Date(timeIntervalSince1970: 1_700_000_100)
        let task = LegacyTask(
            id: taskID,
            title: "Legacy task",
            request: "Preserve every v1 field",
            conversationID: conversationID,
            workspaceID: workspaceID,
            projectID: projectID,
            helperID: nil,
            skillIDs: [],
            connectionAccountIDs: [],
            permissionRecordIDs: [],
            artifactIDs: [], // Migration repairs the legacy missing back-link.
            status: .completed,
            failureSummary: nil,
            isPinned: true,
            createdAt: created,
            updatedAt: updated,
            completedAt: updated
        )
        let workspace = YouziWorkspace(
            id: workspaceID,
            name: "Legacy workspace",
            location: .managed(relativePath: workspaceID.uuidString.lowercased()),
            createdAt: created,
            updatedAt: updated
        )
        let project = LegacyProject(
            id: projectID,
            name: "Legacy project",
            summary: "summary",
            instructions: "instructions",
            preferences: ["tone": "direct"],
            defaultHelperIDs: [],
            defaultSkillIDs: [],
            defaultConnectionAccountIDs: [],
            state: .active,
            createdAt: created,
            updatedAt: updated
        )
        let artifact = LegacyArtifact(
            id: artifactID,
            taskID: taskID,
            projectID: projectID,
            title: "Legacy result.md",
            kind: .document,
            previewText: "preview",
            location: .workspace(workspaceID: workspaceID, relativePath: "Results/result.md"),
            state: .active,
            createdAt: created,
            updatedAt: updated
        )
        let data = try JSONEncoder().encode(
            LegacyEnvelope(
                document: LegacyDocument(
                    tasks: [task],
                    workspaces: [workspace],
                    projects: [project],
                    artifacts: [artifact]
                )
            )
        )
        return (data, taskID, artifactID, workspaceID, conversationID)
    }

    @Test("v1 migrates losslessly, adds deterministic file identity, and commits v2")
    func migratesAndAtomicallyCommits() throws {
        let (legacyData, taskID, artifactID, workspaceID, conversationID) = try fixture()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("youzi-v1-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("domain.json")
        try legacyData.write(to: fileURL)

        let migrated = try YouziDomainStore(fileURL: fileURL).load()

        let task = try #require(migrated.tasks.first { $0.id == taskID })
        #expect(task.title == "Legacy task")
        #expect(task.request == "Preserve every v1 field")
        #expect(task.conversationID == conversationID)
        #expect(task.workspaceID == workspaceID)
        #expect(task.inputFileIDs.isEmpty)
        #expect(task.artifactIDs == [artifactID])
        let file = try #require(migrated.files.first { $0.id == artifactID })
        #expect(file.role == .artifact)
        #expect(file.originTaskID == taskID)
        #expect(file.location == .workspace(workspaceID: workspaceID, relativePath: "Results/result.md"))
        #expect(migrated.artifacts[0].fileID == file.id)
        #expect(migrated.projects[0].resourceFileIDs.isEmpty)

        let object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        )
        #expect(object["schemaVersion"] as? Int == 2)
    }

    @Test("Migration is deterministic and a failed v2 commit preserves original v1 bytes")
    func retryIsSafe() throws {
        let (legacyData, _, _, _, _) = try fixture()
        #expect(
            try YouziDomainV1Migration.decode(legacyData)
                == YouziDomainV1Migration.decode(legacyData)
        )

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("youzi-v1-retry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("domain.json")
        try legacyData.write(to: fileURL)

        do {
            _ = try YouziDomainStore(
                fileURL: fileURL,
                fileManager: FailingCreateFileManager()
            ).load()
            Issue.record("Expected the atomic migration commit to fail")
        } catch let error as YouziDomainStoreError {
            guard case .writeFailed = error else {
                Issue.record("Expected writeFailed, got \(error)")
                return
            }
        }
        #expect(try Data(contentsOf: fileURL) == legacyData)

        #expect(try YouziDomainStore(fileURL: fileURL).load().files.count == 1)
    }
}
