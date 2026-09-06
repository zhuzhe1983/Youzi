import Foundation

/// Frozen wire validation for schema v2. Every legacy collection has its own
/// nominal record shadow and required-key contract; no live v3 record type is
/// referenced while decoding old bytes.
enum YouziDomainFrozenV2 {
    indirect enum JSONValue: Decodable {
        case object([String: JSONValue])
        case array([JSONValue])
        case string(String)
        case integer(Int64)
        case number(Double)
        case bool(Bool)
        case null

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { self = .null }
            else if let value = try? container.decode(Bool.self) { self = .bool(value) }
            else if let value = try? container.decode(Int64.self) { self = .integer(value) }
            else if let value = try? container.decode(Double.self) { self = .number(value) }
            else if let value = try? container.decode(String.self) { self = .string(value) }
            else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
            else { self = .object(try container.decode([String: JSONValue].self)) }
        }
    }

    protocol Requirements {
        static var requiredKeys: Set<String> { get }
    }

    struct Record<Shape: Requirements>: Decodable {
        let object: [String: JSONValue]

        init(from decoder: Decoder) throws {
            let value = try JSONValue(from: decoder)
            guard case let .object(object) = value,
                  Shape.requiredKeys.isSubset(of: Set(object.keys)) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath,
                          debugDescription: "Frozen v2 record is missing required keys")
                )
            }
            self.object = object
        }
    }

    enum Permission: Requirements { static let requiredKeys: Set<String> = ["id", "kind", "targetIdentifier", "purpose", "duration", "decision", "requestedAt"] }
    enum Task: Requirements { static let requiredKeys: Set<String> = ["id", "title", "request", "skillIDs", "connectionAccountIDs", "permissionRecordIDs", "inputFileIDs", "artifactIDs", "status", "isPinned", "createdAt", "updatedAt"] }
    enum Workspace: Requirements { static let requiredKeys: Set<String> = ["id", "name", "location", "state", "createdAt", "updatedAt"] }
    enum Project: Requirements { static let requiredKeys: Set<String> = ["id", "name", "summary", "instructions", "preferences", "defaultHelperIDs", "defaultSkillIDs", "defaultConnectionAccountIDs", "resourceFileIDs", "state", "createdAt", "updatedAt"] }
    enum Helper: Requirements { static let requiredKeys: Set<String> = ["id", "name", "summary", "systemInstructions", "methodology", "recommendedSkillIDs", "allowedConnectorIDs", "preferredOutputTypes", "source", "state", "isFavorite", "createdAt", "updatedAt"] }
    enum Skill: Requirements { static let requiredKeys: Set<String> = ["id", "name", "summary", "packageVersion", "entrypoint", "resourcePaths", "executionLocation", "requestedPermissions", "connectorDependencyIDs", "requiresFirstUseConfirmation", "source", "state", "createdAt", "updatedAt"] }
    enum Connector: Requirements { static let requiredKeys: Set<String> = ["id", "name", "summary", "adapter", "authentication", "declaredScopes", "toolNames", "source", "state", "createdAt", "updatedAt"] }
    enum Account: Requirements { static let requiredKeys: Set<String> = ["id", "connectorID", "displayName", "grantedScopes", "state", "createdAt", "updatedAt"] }
    enum File: Requirements { static let requiredKeys: Set<String> = ["id", "displayName", "role", "location", "availability", "createdAt", "updatedAt"] }
    enum Artifact: Requirements { static let requiredKeys: Set<String> = ["id", "taskID", "title", "kind", "fileID", "state", "createdAt", "updatedAt"] }
    enum Template: Requirements { static let requiredKeys: Set<String> = ["id", "name", "category", "summary", "prefilledRequest", "recommendedSkillIDs", "recommendedConnectorIDs", "requiredInputs", "source", "state", "isFavorite", "createdAt", "updatedAt"] }
    enum Automation: Requirements { static let requiredKeys: Set<String> = ["id", "name", "revision", "trigger", "action", "permissionRecordIDs", "notificationEnabled", "state", "createdAt", "updatedAt"] }
    enum AutomationRun: Requirements { static let requiredKeys: Set<String> = ["id", "automationID", "status", "startedAt"] }
    enum MemoryNode: Requirements { static let requiredKeys: Set<String> = ["id", "label", "content", "kind", "confidence", "scope", "citationIDs", "creationMethod", "state", "createdAt", "updatedAt"] }
    enum MemoryEdge: Requirements { static let requiredKeys: Set<String> = ["id", "sourceNodeID", "targetNodeID", "relation", "explanation", "confidence", "scope", "citationIDs", "state", "createdAt", "updatedAt"] }
    enum MemoryCitation: Requirements { static let requiredKeys: Set<String> = ["id", "sourceType", "sourceID", "title", "stableLocator", "excerpt", "contentChecksum", "authorizationState", "createdAt", "updatedAt"] }
    enum VoiceSession: Requirements { static let requiredKeys: Set<String> = ["id", "dimension", "transcriptMessageIDs", "permissionRecordIDs", "state", "localeIdentifier", "audioWasPersisted", "startedAt", "updatedAt"] }

    struct Envelope: Decodable {
        let formatIdentifier: String
        let schemaVersion: Int
        let document: Document
    }

    struct Document: Decodable {
        let permissions: [Record<Permission>]
        let tasks: [Record<Task>]
        let workspaces: [Record<Workspace>]
        let projects: [Record<Project>]
        let helpers: [Record<Helper>]
        let skills: [Record<Skill>]
        let connectors: [Record<Connector>]
        let connectionAccounts: [Record<Account>]
        let files: [Record<File>]
        let artifacts: [Record<Artifact>]
        let templates: [Record<Template>]
        let automations: [Record<Automation>]
        let automationRuns: [Record<AutomationRun>]
        let memoryNodes: [Record<MemoryNode>]
        let memoryEdges: [Record<MemoryEdge>]
        let memoryCitations: [Record<MemoryCitation>]
        let voiceSessions: [Record<VoiceSession>]
    }
}

enum YouziDomainV2Migration {
    enum MigrationError: Error {
        case wrongEnvelope
        case malformedDocument
        case danglingAutomationRun
    }

    static func decode(_ data: Data, decoder: JSONDecoder = JSONDecoder()) throws
        -> YouziDomainDocument
    {
        let frozen = try decoder.decode(YouziDomainFrozenV2.Envelope.self, from: data)
        guard frozen.formatIdentifier == YouziDomainSchema.formatIdentifier,
              frozen.schemaVersion == 2 else { throw MigrationError.wrongEnvelope }

        let object = try JSONSerialization.jsonObject(with: data)
        guard var envelope = object as? [String: Any],
              var document = envelope["document"] as? [String: Any] else {
            throw MigrationError.malformedDocument
        }
        try migrateV2DocumentJSONObject(&document)
        envelope["schemaVersion"] = 3
        envelope["document"] = document
        let migratedData = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        return try decoder.decode(YouziDomainEnvelope.self, from: migratedData).document
    }

    /// Shared by the v1 migration after it has deterministically constructed a
    /// complete v2-shaped object. This transformation never reads external
    /// state and never manufactures package, binding, grant, or audit records.
    static func migrateV2DocumentJSONObject(_ document: inout [String: Any]) throws {
        document["skillPackages"] = []
        document["connectorBindings"] = []
        document["permissionGrants"] = []
        document["executionAuditEvents"] = []

        var tasks = try arrayOfObjects(document["tasks"])
        for index in tasks.indices {
            tasks[index]["helperSelectionIntent"] = "inheritProjectDefaults"
            tasks[index]["skillSelectionIntent"] = "inheritProjectDefaults"
            tasks[index]["connectionAccountSelectionIntent"] = "inheritProjectDefaults"
        }
        document["tasks"] = tasks

        var workspaces = try arrayOfObjects(document["workspaces"])
        for index in workspaces.indices {
            workspaces[index]["location"] = try migrateWorkspaceLocation(
                workspaces[index]["location"]
            )
        }
        document["workspaces"] = workspaces

        var files = try arrayOfObjects(document["files"])
        for index in files.indices {
            files[index]["location"] = try migrateFileLocation(files[index]["location"])
        }
        document["files"] = files

        var memoryNodes = try arrayOfObjects(document["memoryNodes"])
        for index in memoryNodes.indices {
            memoryNodes[index]["scope"] = try migrateMemoryScope(memoryNodes[index]["scope"])
        }
        document["memoryNodes"] = memoryNodes

        var memoryEdges = try arrayOfObjects(document["memoryEdges"])
        for index in memoryEdges.indices {
            memoryEdges[index]["scope"] = try migrateMemoryScope(memoryEdges[index]["scope"])
        }
        document["memoryEdges"] = memoryEdges

        var permissions = try arrayOfObjects(document["permissions"])
        for index in permissions.indices {
            if let kind = permissions[index]["kind"] as? String,
               ["workspaceRead", "workspaceWrite", "connectorRead", "connectorWrite",
                "externalPublish"].contains(kind),
               let target = permissions[index]["targetIdentifier"] as? String,
               let id = UUID(uuidString: target) {
                permissions[index]["targetIdentifier"] = id.uuidString.lowercased()
            }
        }
        document["permissions"] = permissions

        var accounts = try arrayOfObjects(document["connectionAccounts"])
        for index in accounts.indices {
            guard let reference = accounts[index]["credentialReference"] as? String,
                  let idString = accounts[index]["id"] as? String,
                  let id = UUID(uuidString: idString),
                  !isValidLegacyCredentialReference(reference, accountID: id) else { continue }
            accounts[index].removeValue(forKey: "credentialReference")
            accounts[index]["state"] = "needsAttention"
            accounts[index]["recoveryCode"] = "credentialMissing"
        }
        document["connectionAccounts"] = accounts

        var skills = try arrayOfObjects(document["skills"])
        for index in skills.indices {
            if skills[index]["state"] as? String == "active" {
                skills[index]["state"] = "unavailable"
            }
        }
        document["skills"] = skills

        var automations = try arrayOfObjects(document["automations"])
        var revisions: [String: Int] = [:]
        for index in automations.indices {
            guard let id = automations[index]["id"] as? String,
                  let revision = integer(automations[index]["revision"]),
                  let createdAt = automations[index]["createdAt"] else {
                throw MigrationError.malformedDocument
            }
            revisions[id.lowercased()] = revision
            automations[index]["trigger"] = try migrateTrigger(
                automations[index]["trigger"], anchorAt: createdAt
            )
            automations[index]["permissionGrantIDs"] = []
            automations[index]["missedRunPolicy"] = "runOnce"
            automations[index]["overlapPolicy"] = "skipWhileActive"
            automations[index]["retryPolicy"] = [
                "maximumAttempts": 1,
                "baseDelaySeconds": 1,
            ]
            let permissionIDs = automations[index]["permissionRecordIDs"] as? [Any] ?? []
            let action = automations[index]["action"] as? [String: Any]
            let accountIDs = action?["connectionAccountIDs"] as? [Any] ?? []
            if automations[index]["state"] as? String == "active" {
                if !permissionIDs.isEmpty || !accountIDs.isEmpty {
                    automations[index]["state"] = "needsAttention"
                } else {
                    automations[index]["confirmedAt"] = createdAt
                }
            }
        }
        document["automations"] = automations

        var runs = try arrayOfObjects(document["automationRuns"])
        for index in runs.indices {
            guard let automationID = runs[index]["automationID"] as? String,
                  let revision = revisions[automationID.lowercased()],
                  let startedAt = runs[index]["startedAt"] else {
                throw MigrationError.danglingAutomationRun
            }
            runs[index]["automationRevision"] = revision
            runs[index]["permissionGrantIDs"] = []
            runs[index]["retryPolicy"] = [
                "maximumAttempts": 1,
                "baseDelaySeconds": 1,
            ]
            runs[index]["attemptCount"] = 1
            runs[index]["createdAt"] = startedAt
            if let status = runs[index]["status"] as? String,
               ["completed", "failed", "cancelled"].contains(status),
               runs[index]["finishedAt"] == nil {
                runs[index]["finishedAt"] = startedAt
            }
        }
        document["automationRuns"] = runs
    }

    private static func migrateTrigger(_ value: Any?, anchorAt: Any) throws -> [String: Any] {
        guard let trigger = value as? [String: Any] else { throw MigrationError.malformedDocument }
        if trigger["manual"] != nil { return ["kind": "manual"] }
        if let interval = trigger["interval"] as? [String: Any],
           let seconds = interval["seconds"] {
            return ["kind": "interval", "seconds": seconds, "anchorAt": anchorAt]
        }
        if let schedule = trigger["schedule"] as? [String: Any],
           let expression = schedule["cronExpression"],
           let zone = schedule["timeZoneIdentifier"] {
            return [
                "kind": "schedule",
                "cronExpression": expression,
                "timeZoneIdentifier": zone,
            ]
        }
        throw MigrationError.malformedDocument
    }

    private static func migrateWorkspaceLocation(_ value: Any?) throws -> [String: Any] {
        guard let location = value as? [String: Any] else {
            throw MigrationError.malformedDocument
        }
        if let payload = location["managed"] as? [String: Any],
           let path = payload["relativePath"] {
            return ["kind": "managed", "relativePath": path]
        }
        if let payload = location["securityScopedBookmark"] as? [String: Any],
           let data = payload["data"], let displayPath = payload["displayPath"] {
            return [
                "kind": "securityScopedBookmark",
                "data": data,
                "displayPath": displayPath,
            ]
        }
        throw MigrationError.malformedDocument
    }

    private static func migrateFileLocation(_ value: Any?) throws -> [String: Any] {
        guard let location = value as? [String: Any] else {
            throw MigrationError.malformedDocument
        }
        if let payload = location["workspace"] as? [String: Any],
           let workspaceID = payload["workspaceID"], let path = payload["relativePath"] {
            return [
                "kind": "workspace",
                "workspaceID": workspaceID,
                "relativePath": path,
            ]
        }
        if let payload = location["appManaged"] as? [String: Any],
           let path = payload["relativePath"] {
            return ["kind": "appManaged", "relativePath": path]
        }
        if let payload = location["securityScopedBookmark"] as? [String: Any],
           let data = payload["data"], let displayPath = payload["displayPath"] {
            return [
                "kind": "securityScopedBookmark",
                "data": data,
                "displayPath": displayPath,
            ]
        }
        throw MigrationError.malformedDocument
    }

    private static func migrateMemoryScope(_ value: Any?) throws -> [String: Any] {
        guard let scope = value as? [String: Any] else { throw MigrationError.malformedDocument }
        if scope["personal"] != nil { return ["kind": "personal"] }
        if scope["sensitiveSealed"] != nil { return ["kind": "sensitiveSealed"] }
        if let payload = scope["project"] as? [String: Any], let id = payload["_0"] {
            return ["kind": "project", "projectID": id]
        }
        if let payload = scope["workspace"] as? [String: Any], let id = payload["_0"] {
            return ["kind": "workspace", "workspaceID": id]
        }
        throw MigrationError.malformedDocument
    }

    static func arrayOfObjects(_ value: Any?) throws -> [[String: Any]] {
        guard let array = value as? [Any] else { throw MigrationError.malformedDocument }
        return try array.map {
            guard let object = $0 as? [String: Any] else { throw MigrationError.malformedDocument }
            return object
        }
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private static func isValidLegacyCredentialReference(_ reference: String, accountID: UUID) -> Bool {
        if reference == "youzi.connector.\(accountID.uuidString.lowercased())" { return true }
        guard reference.hasPrefix("keychain:"), reference.count <= 128 else { return false }
        let suffix = reference.dropFirst("keychain:".count)
        return !suffix.isEmpty && suffix.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-")).contains($0)
        }
    }
}
