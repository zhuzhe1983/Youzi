import Foundation

/// Frozen, decode-only representation of the one schema released before files
/// became first-class records. Never loosen these types to match a newer model:
/// they are the permanent proof that every v1 field has an explicit v2 home.
enum YouziDomainV1Migration {
    private struct Envelope: Decodable {
        let formatIdentifier: String
        let schemaVersion: Int
        let document: Document
    }

    private struct Document: Decodable {
        var permissions: [YouziPermissionRecord]
        var tasks: [TaskRecord]
        var workspaces: [YouziWorkspace]
        var projects: [ProjectRecord]
        var helpers: [YouziHelper]
        var skills: [YouziSkill]
        var connectors: [YouziConnector]
        var connectionAccounts: [YouziConnectionAccount]
        var artifacts: [ArtifactRecord]
        var templates: [YouziTemplate]
        var automations: [YouziAutomation]
        var automationRuns: [YouziAutomationRun]
        var memoryNodes: [YouziMemoryNode]
        var memoryEdges: [YouziMemoryEdge]
        var memoryCitations: [YouziMemoryCitation]
        var voiceSessions: [YouziVoiceSession]
    }

    private struct TaskRecord: Decodable {
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

        func migrated() -> YouziTask {
            YouziTask(
                id: id,
                title: title,
                request: request,
                conversationID: conversationID,
                workspaceID: workspaceID,
                projectID: projectID,
                helperID: helperID,
                skillIDs: skillIDs,
                connectionAccountIDs: connectionAccountIDs,
                permissionRecordIDs: permissionRecordIDs,
                inputFileIDs: [],
                artifactIDs: artifactIDs,
                status: status,
                failureSummary: failureSummary,
                isPinned: isPinned,
                createdAt: createdAt,
                updatedAt: updatedAt,
                completedAt: completedAt
            )
        }
    }

    private struct ProjectRecord: Decodable {
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

        func migrated() -> YouziProject {
            YouziProject(
                id: id,
                name: name,
                summary: summary,
                instructions: instructions,
                preferences: preferences,
                defaultHelperIDs: defaultHelperIDs,
                defaultSkillIDs: defaultSkillIDs,
                defaultConnectionAccountIDs: defaultConnectionAccountIDs,
                resourceFileIDs: [],
                state: state,
                createdAt: createdAt,
                updatedAt: updatedAt
            )
        }
    }

    private enum ArtifactLocation: Decodable {
        case workspace(workspaceID: UUID, relativePath: String)
        case appManaged(relativePath: String)
        case securityScopedBookmark(data: Data, displayPath: String)

        var migrated: YouziFileLocation {
            switch self {
            case let .workspace(workspaceID, relativePath):
                return .workspace(workspaceID: workspaceID, relativePath: relativePath)
            case let .appManaged(relativePath):
                return .appManaged(relativePath: relativePath)
            case let .securityScopedBookmark(data, displayPath):
                return .securityScopedBookmark(data: data, displayPath: displayPath)
            }
        }
    }

    private struct ArtifactRecord: Decodable {
        let id: UUID
        var taskID: UUID
        var projectID: UUID?
        var title: String
        var kind: YouziArtifactKind
        var previewText: String?
        var location: ArtifactLocation
        var state: YouziRecordState
        let createdAt: Date
        var updatedAt: Date

        var migratedFile: YouziFile {
            YouziFile(
                id: id,
                displayName: title,
                role: .artifact,
                originTaskID: taskID,
                projectID: projectID,
                location: location.migrated,
                availability: .available,
                createdAt: createdAt,
                updatedAt: updatedAt
            )
        }

        var migratedArtifact: YouziArtifact {
            YouziArtifact(
                id: id,
                taskID: taskID,
                projectID: projectID,
                title: title,
                kind: kind,
                previewText: previewText,
                fileID: id,
                state: state,
                createdAt: createdAt,
                updatedAt: updatedAt
            )
        }
    }

    static func decode(_ data: Data, decoder: JSONDecoder = JSONDecoder()) throws
        -> YouziDomainDocument
    {
        let envelope = try decoder.decode(Envelope.self, from: data)
        guard envelope.formatIdentifier == YouziDomainSchema.formatIdentifier,
              envelope.schemaVersion == 1
        else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "Not a Youzi domain v1 envelope")
            )
        }

        let old = envelope.document
        let migratedArtifacts = old.artifacts.map(\.migratedArtifact)
        let artifactIDsByTask = Dictionary(grouping: migratedArtifacts, by: \.taskID)
            .mapValues { $0.map(\.id) }
        let migratedTasks = old.tasks.map { record -> YouziTask in
            var task = record.migrated()
            for artifactID in artifactIDsByTask[task.id] ?? []
            where !task.artifactIDs.contains(artifactID) {
                task.artifactIDs.append(artifactID)
            }
            return task
        }

        return YouziDomainDocument(
            permissions: old.permissions,
            tasks: migratedTasks,
            workspaces: old.workspaces,
            projects: old.projects.map { $0.migrated() },
            helpers: old.helpers,
            skills: old.skills,
            connectors: old.connectors,
            connectionAccounts: old.connectionAccounts,
            files: old.artifacts.map(\.migratedFile),
            artifacts: migratedArtifacts,
            templates: old.templates,
            automations: old.automations,
            automationRuns: old.automationRuns,
            memoryNodes: old.memoryNodes,
            memoryEdges: old.memoryEdges,
            memoryCitations: old.memoryCitations,
            voiceSessions: old.voiceSessions
        )
    }
}
