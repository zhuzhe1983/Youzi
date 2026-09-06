import Foundation

/// Frozen schema-v1 wire decoder. It shares only the frozen primitive record
/// machinery with v2 and never references a mutable v3 record type while
/// decoding old bytes.
enum YouziDomainV1Migration {
    private enum Task: YouziDomainFrozenV2.Requirements {
        static let requiredKeys: Set<String> = [
            "id", "title", "request", "skillIDs", "connectionAccountIDs",
            "permissionRecordIDs", "artifactIDs", "status", "isPinned",
            "createdAt", "updatedAt",
        ]
    }

    private enum Project: YouziDomainFrozenV2.Requirements {
        static let requiredKeys: Set<String> = [
            "id", "name", "summary", "instructions", "preferences",
            "defaultHelperIDs", "defaultSkillIDs", "defaultConnectionAccountIDs",
            "state", "createdAt", "updatedAt",
        ]
    }

    private enum Artifact: YouziDomainFrozenV2.Requirements {
        static let requiredKeys: Set<String> = [
            "id", "taskID", "title", "kind", "location", "state",
            "createdAt", "updatedAt",
        ]
    }

    private struct Envelope: Decodable {
        let formatIdentifier: String
        let schemaVersion: Int
        let document: Document
    }

    private struct Document: Decodable {
        let permissions: [YouziDomainFrozenV2.Record<YouziDomainFrozenV2.Permission>]
        let tasks: [YouziDomainFrozenV2.Record<Task>]
        let workspaces: [YouziDomainFrozenV2.Record<YouziDomainFrozenV2.Workspace>]
        let projects: [YouziDomainFrozenV2.Record<Project>]
        let helpers: [YouziDomainFrozenV2.Record<YouziDomainFrozenV2.Helper>]
        let skills: [YouziDomainFrozenV2.Record<YouziDomainFrozenV2.Skill>]
        let connectors: [YouziDomainFrozenV2.Record<YouziDomainFrozenV2.Connector>]
        let connectionAccounts: [YouziDomainFrozenV2.Record<YouziDomainFrozenV2.Account>]
        let artifacts: [YouziDomainFrozenV2.Record<Artifact>]
        let templates: [YouziDomainFrozenV2.Record<YouziDomainFrozenV2.Template>]
        let automations: [YouziDomainFrozenV2.Record<YouziDomainFrozenV2.Automation>]
        let automationRuns: [YouziDomainFrozenV2.Record<YouziDomainFrozenV2.AutomationRun>]
        let memoryNodes: [YouziDomainFrozenV2.Record<YouziDomainFrozenV2.MemoryNode>]
        let memoryEdges: [YouziDomainFrozenV2.Record<YouziDomainFrozenV2.MemoryEdge>]
        let memoryCitations: [YouziDomainFrozenV2.Record<YouziDomainFrozenV2.MemoryCitation>]
        let voiceSessions: [YouziDomainFrozenV2.Record<YouziDomainFrozenV2.VoiceSession>]
    }

    enum MigrationError: Error {
        case wrongEnvelope
        case malformedDocument
    }

    static func decode(_ data: Data, decoder: JSONDecoder = JSONDecoder()) throws
        -> YouziDomainDocument
    {
        let frozen = try decoder.decode(Envelope.self, from: data)
        guard frozen.formatIdentifier == YouziDomainSchema.formatIdentifier,
              frozen.schemaVersion == 1 else { throw MigrationError.wrongEnvelope }

        let object = try JSONSerialization.jsonObject(with: data)
        guard var envelope = object as? [String: Any],
              var document = envelope["document"] as? [String: Any] else {
            throw MigrationError.malformedDocument
        }

        var tasks = try YouziDomainV2Migration.arrayOfObjects(document["tasks"])
        for index in tasks.indices { tasks[index]["inputFileIDs"] = [] }

        var projects = try YouziDomainV2Migration.arrayOfObjects(document["projects"])
        for index in projects.indices { projects[index]["resourceFileIDs"] = [] }

        let oldArtifacts = try YouziDomainV2Migration.arrayOfObjects(document["artifacts"])
        var files: [[String: Any]] = []
        var artifacts: [[String: Any]] = []
        var artifactIDsByTask: [String: [String]] = [:]
        for old in oldArtifacts {
            guard let id = old["id"] as? String,
                  let taskID = old["taskID"] as? String,
                  let title = old["title"],
                  let location = old["location"],
                  let createdAt = old["createdAt"],
                  let updatedAt = old["updatedAt"] else {
                throw MigrationError.malformedDocument
            }
            var file: [String: Any] = [
                "id": id,
                "displayName": title,
                "role": "artifact",
                "originTaskID": taskID,
                "location": location,
                "availability": "available",
                "createdAt": createdAt,
                "updatedAt": updatedAt,
            ]
            if let projectID = old["projectID"] { file["projectID"] = projectID }
            files.append(file)

            var artifact = old
            artifact.removeValue(forKey: "location")
            artifact["fileID"] = id
            artifacts.append(artifact)
            artifactIDsByTask[taskID.lowercased(), default: []].append(id)
        }

        for index in tasks.indices {
            guard let taskID = tasks[index]["id"] as? String else {
                throw MigrationError.malformedDocument
            }
            var artifactIDs = tasks[index]["artifactIDs"] as? [String] ?? []
            for artifactID in artifactIDsByTask[taskID.lowercased()] ?? []
            where !artifactIDs.contains(artifactID) {
                artifactIDs.append(artifactID)
            }
            tasks[index]["artifactIDs"] = artifactIDs
        }

        document["tasks"] = tasks
        document["projects"] = projects
        document["files"] = files
        document["artifacts"] = artifacts
        try YouziDomainV2Migration.migrateV2DocumentJSONObject(&document)

        envelope["schemaVersion"] = 3
        envelope["document"] = document
        let migratedData = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        return try decoder.decode(YouziDomainEnvelope.self, from: migratedData).document
    }
}
