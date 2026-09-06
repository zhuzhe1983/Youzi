import Foundation
import Testing
@testable import Rapid

@Suite("YouziDomain — frozen v1/v2 to v3 migration")
struct YouziDomainMigrationTests {
    private final class FailingCreateFileManager: FileManager, @unchecked Sendable {
        override func createFile(
            atPath path: String,
            contents data: Data?,
            attributes attr: [FileAttributeKey: Any]? = nil
        ) -> Bool { false }
    }

    private static let taskID = UUID(uuidString: "00000000-0000-0000-0000-000000000007")!
    private static let artifactID = UUID(uuidString: "00000000-0000-0000-0000-000000000009")!
    private static let accountID = UUID(uuidString: "00000000-0000-0000-0000-000000000006")!

    // Literal legacy bytes: neither fixture encodes a mutable v3 type. Every
    // collection accepted by its historical schema is non-empty.
    private static let v2Fixture = Data(#"""
    {
      "formatIdentifier":"com.rapidmlx.youzi.domain",
      "schemaVersion":2,
      "document":{
        "permissions":[{
          "id":"00000000-0000-0000-0000-000000000008",
          "taskID":"00000000-0000-0000-0000-000000000007",
          "kind":"microphone","targetIdentifier":"microphone",
          "purpose":"Voice input","duration":"task","decision":"allowed",
          "requestedAt":100,"decidedAt":101
        }],
        "tasks":[{
          "id":"00000000-0000-0000-0000-000000000007",
          "title":"Legacy task","request":"Preserve every v2 field",
          "conversationID":"00000000-0000-0000-0000-000000000019",
          "workspaceID":"00000000-0000-0000-0000-000000000001",
          "projectID":"00000000-0000-0000-0000-000000000002",
          "helperID":"00000000-0000-0000-0000-000000000003",
          "skillIDs":["00000000-0000-0000-0000-000000000004"],
          "connectionAccountIDs":["00000000-0000-0000-0000-000000000006"],
          "permissionRecordIDs":["00000000-0000-0000-0000-000000000008"],
          "inputFileIDs":[],
          "artifactIDs":["00000000-0000-0000-0000-000000000009"],
          "status":"completed","isPinned":true,
          "createdAt":100,"updatedAt":110,"completedAt":110
        }],
        "workspaces":[{
          "id":"00000000-0000-0000-0000-000000000001",
          "name":"Legacy workspace",
          "location":{"managed":{"relativePath":"00000000-0000-0000-0000-000000000001"}},
          "state":"active","createdAt":100,"updatedAt":110
        }],
        "projects":[{
          "id":"00000000-0000-0000-0000-000000000002",
          "name":"Legacy project","summary":"summary","instructions":"instructions",
          "preferences":{"tone":"direct"},
          "defaultHelperIDs":["00000000-0000-0000-0000-000000000003"],
          "defaultSkillIDs":["00000000-0000-0000-0000-000000000004"],
          "defaultConnectionAccountIDs":["00000000-0000-0000-0000-000000000006"],
          "resourceFileIDs":[],"state":"active","createdAt":100,"updatedAt":110
        }],
        "helpers":[{
          "id":"00000000-0000-0000-0000-000000000003",
          "name":"Legacy helper","summary":"summary","systemInstructions":"help",
          "methodology":["inspect"],
          "recommendedSkillIDs":["00000000-0000-0000-0000-000000000004"],
          "allowedConnectorIDs":["00000000-0000-0000-0000-000000000005"],
          "preferredOutputTypes":["document"],
          "source":{"kind":"builtIn","identifier":"legacy.helper","version":"1"},
          "state":"active","isFavorite":true,"createdAt":100,"updatedAt":110
        }],
        "skills":[{
          "id":"00000000-0000-0000-0000-000000000004",
          "name":"Legacy skill","summary":"summary","packageVersion":"1",
          "entrypoint":"SKILL.md","resourcePaths":["references/guide.md"],
          "executionLocation":"local","requestedPermissions":["workspaceRead"],
          "connectorDependencyIDs":["00000000-0000-0000-0000-000000000005"],
          "requiresFirstUseConfirmation":true,
          "source":{"kind":"builtIn","identifier":"legacy.skill","version":"1"},
          "state":"active","createdAt":100,"updatedAt":110
        }],
        "connectors":[{
          "id":"00000000-0000-0000-0000-000000000005",
          "name":"Legacy connector","summary":"summary","adapter":"native",
          "authentication":"apiKey","declaredScopes":["read"],"toolNames":["lookup"],
          "source":{"kind":"builtIn","identifier":"legacy.connector","version":"1"},
          "state":"active","createdAt":100,"updatedAt":110
        }],
        "connectionAccounts":[{
          "id":"00000000-0000-0000-0000-000000000006",
          "connectorID":"00000000-0000-0000-0000-000000000005",
          "displayName":"Legacy account",
          "credentialReference":"youzi.connector.00000000-0000-0000-0000-000000000006",
          "grantedScopes":["read"],"state":"connected",
          "createdAt":100,"updatedAt":110
        }],
        "files":[{
          "id":"00000000-0000-0000-0000-000000000009",
          "displayName":"result.md","role":"artifact",
          "originTaskID":"00000000-0000-0000-0000-000000000007",
          "projectID":"00000000-0000-0000-0000-000000000002",
          "location":{"workspace":{"workspaceID":"00000000-0000-0000-0000-000000000001","relativePath":"Results/result.md"}},
          "availability":"available","createdAt":100,"updatedAt":110
        }],
        "artifacts":[{
          "id":"00000000-0000-0000-0000-000000000009",
          "taskID":"00000000-0000-0000-0000-000000000007",
          "projectID":"00000000-0000-0000-0000-000000000002",
          "title":"result.md","kind":"document","previewText":"preview",
          "fileID":"00000000-0000-0000-0000-000000000009",
          "state":"active","createdAt":100,"updatedAt":110
        }],
        "templates":[{
          "id":"00000000-0000-0000-0000-000000000010",
          "name":"Legacy template","category":"work","summary":"summary",
          "prefilledRequest":"prepare","recommendedHelperID":"00000000-0000-0000-0000-000000000003",
          "recommendedSkillIDs":["00000000-0000-0000-0000-000000000004"],
          "recommendedConnectorIDs":["00000000-0000-0000-0000-000000000005"],
          "requiredInputs":["topic"],
          "source":{"kind":"builtIn","identifier":"legacy.template","version":"1"},
          "state":"active","isFavorite":false,"createdAt":100,"updatedAt":110
        }],
        "automations":[
          {"id":"00000000-0000-0000-0000-000000000011","name":"Manual","revision":2,
           "trigger":{"manual":{}},
           "action":{"request":"manual","projectID":"00000000-0000-0000-0000-000000000002","workspaceID":"00000000-0000-0000-0000-000000000001","helperID":"00000000-0000-0000-0000-000000000003","skillIDs":["00000000-0000-0000-0000-000000000004"],"connectionAccountIDs":["00000000-0000-0000-0000-000000000006"]},
           "permissionRecordIDs":["00000000-0000-0000-0000-000000000008"],"notificationEnabled":true,"state":"active","createdAt":100,"updatedAt":110},
          {"id":"00000000-0000-0000-0000-000000000021","name":"Interval","revision":1,
           "trigger":{"interval":{"seconds":300}},
           "action":{"request":"interval","skillIDs":[],"connectionAccountIDs":[]},
           "permissionRecordIDs":[],"notificationEnabled":false,"state":"active","createdAt":101,"updatedAt":110},
          {"id":"00000000-0000-0000-0000-000000000022","name":"Schedule","revision":1,
           "trigger":{"schedule":{"cronExpression":"0 17 * * 5","timeZoneIdentifier":"Asia/Shanghai"}},
           "action":{"request":"schedule","skillIDs":[],"connectionAccountIDs":[]},
           "permissionRecordIDs":[],"notificationEnabled":true,"state":"active","createdAt":102,"updatedAt":110}
        ],
        "automationRuns":[{
          "id":"00000000-0000-0000-0000-000000000016",
          "automationID":"00000000-0000-0000-0000-000000000011",
          "taskID":"00000000-0000-0000-0000-000000000007",
          "status":"completed","summary":"done","startedAt":105,"finishedAt":106
        }],
        "memoryNodes":[{
          "id":"00000000-0000-0000-0000-000000000013",
          "label":"Topic","content":"content","kind":"topic","confidence":0.9,
          "scope":{"project":{"_0":"00000000-0000-0000-0000-000000000002"}},
          "citationIDs":["00000000-0000-0000-0000-000000000012"],
          "creationMethod":"imported","state":"confirmed","createdAt":100,"updatedAt":110
        }],
        "memoryEdges":[{
          "id":"00000000-0000-0000-0000-000000000017",
          "sourceNodeID":"00000000-0000-0000-0000-000000000013",
          "targetNodeID":"00000000-0000-0000-0000-000000000013",
          "relation":"sourcedFrom","explanation":"legacy","confidence":0.8,
          "scope":{"project":{"_0":"00000000-0000-0000-0000-000000000002"}},
          "citationIDs":["00000000-0000-0000-0000-000000000012"],
          "state":"confirmed","createdAt":100,"updatedAt":110
        }],
        "memoryCitations":[{
          "id":"00000000-0000-0000-0000-000000000012",
          "sourceType":"manualImport","sourceID":"source","scopeID":"00000000-0000-0000-0000-000000000002",
          "title":"Citation","stableLocator":"section-1","excerpt":"excerpt",
          "contentChecksum":"checksum","authorizationState":"authorized",
          "createdAt":100,"updatedAt":110
        }],
        "voiceSessions":[{
          "id":"00000000-0000-0000-0000-000000000018","dimension":"helper",
          "taskID":"00000000-0000-0000-0000-000000000007",
          "conversationID":"00000000-0000-0000-0000-000000000019",
          "helperID":"00000000-0000-0000-0000-000000000003",
          "transcriptMessageIDs":["00000000-0000-0000-0000-000000000023"],
          "permissionRecordIDs":["00000000-0000-0000-0000-000000000008"],
          "state":"ended","localeIdentifier":"en-US","audioWasPersisted":false,
          "startedAt":100,"endedAt":110,"updatedAt":110
        }]
      }
    }
    """#.utf8)

    private static let v1Fixture = Data(#"""
    {
      "formatIdentifier":"com.rapidmlx.youzi.domain","schemaVersion":1,"document":{
        "permissions":[{"id":"00000000-0000-0000-0000-000000000008","taskID":"00000000-0000-0000-0000-000000000007","kind":"microphone","targetIdentifier":"microphone","purpose":"Voice input","duration":"task","decision":"allowed","requestedAt":100,"decidedAt":101}],
        "tasks":[{"id":"00000000-0000-0000-0000-000000000007","title":"Legacy task","request":"Preserve every v1 field","conversationID":"00000000-0000-0000-0000-000000000019","workspaceID":"00000000-0000-0000-0000-000000000001","projectID":"00000000-0000-0000-0000-000000000002","helperID":"00000000-0000-0000-0000-000000000003","skillIDs":["00000000-0000-0000-0000-000000000004"],"connectionAccountIDs":["00000000-0000-0000-0000-000000000006"],"permissionRecordIDs":["00000000-0000-0000-0000-000000000008"],"artifactIDs":[],"status":"completed","isPinned":true,"createdAt":100,"updatedAt":110,"completedAt":110}],
        "workspaces":[{"id":"00000000-0000-0000-0000-000000000001","name":"Legacy workspace","location":{"managed":{"relativePath":"00000000-0000-0000-0000-000000000001"}},"state":"active","createdAt":100,"updatedAt":110}],
        "projects":[{"id":"00000000-0000-0000-0000-000000000002","name":"Legacy project","summary":"summary","instructions":"instructions","preferences":{"tone":"direct"},"defaultHelperIDs":["00000000-0000-0000-0000-000000000003"],"defaultSkillIDs":["00000000-0000-0000-0000-000000000004"],"defaultConnectionAccountIDs":["00000000-0000-0000-0000-000000000006"],"state":"active","createdAt":100,"updatedAt":110}],
        "helpers":[{"id":"00000000-0000-0000-0000-000000000003","name":"Legacy helper","summary":"summary","systemInstructions":"help","methodology":["inspect"],"recommendedSkillIDs":["00000000-0000-0000-0000-000000000004"],"allowedConnectorIDs":["00000000-0000-0000-0000-000000000005"],"preferredOutputTypes":["document"],"source":{"kind":"builtIn","identifier":"legacy.helper","version":"1"},"state":"active","isFavorite":true,"createdAt":100,"updatedAt":110}],
        "skills":[{"id":"00000000-0000-0000-0000-000000000004","name":"Legacy skill","summary":"summary","packageVersion":"1","entrypoint":"SKILL.md","resourcePaths":["references/guide.md"],"executionLocation":"local","requestedPermissions":["workspaceRead"],"connectorDependencyIDs":["00000000-0000-0000-0000-000000000005"],"requiresFirstUseConfirmation":true,"source":{"kind":"builtIn","identifier":"legacy.skill","version":"1"},"state":"active","createdAt":100,"updatedAt":110}],
        "connectors":[{"id":"00000000-0000-0000-0000-000000000005","name":"Legacy connector","summary":"summary","adapter":"native","authentication":"apiKey","declaredScopes":["read"],"toolNames":["lookup"],"source":{"kind":"builtIn","identifier":"legacy.connector","version":"1"},"state":"active","createdAt":100,"updatedAt":110}],
        "connectionAccounts":[{"id":"00000000-0000-0000-0000-000000000006","connectorID":"00000000-0000-0000-0000-000000000005","displayName":"Legacy account","credentialReference":"youzi.connector.00000000-0000-0000-0000-000000000006","grantedScopes":["read"],"state":"connected","createdAt":100,"updatedAt":110}],
        "artifacts":[{"id":"00000000-0000-0000-0000-000000000009","taskID":"00000000-0000-0000-0000-000000000007","projectID":"00000000-0000-0000-0000-000000000002","title":"result.md","kind":"document","previewText":"preview","location":{"workspace":{"workspaceID":"00000000-0000-0000-0000-000000000001","relativePath":"Results/result.md"}},"state":"active","createdAt":100,"updatedAt":110}],
        "templates":[{"id":"00000000-0000-0000-0000-000000000010","name":"Legacy template","category":"work","summary":"summary","prefilledRequest":"prepare","recommendedHelperID":"00000000-0000-0000-0000-000000000003","recommendedSkillIDs":["00000000-0000-0000-0000-000000000004"],"recommendedConnectorIDs":["00000000-0000-0000-0000-000000000005"],"requiredInputs":["topic"],"source":{"kind":"builtIn","identifier":"legacy.template","version":"1"},"state":"active","isFavorite":false,"createdAt":100,"updatedAt":110}],
        "automations":[{"id":"00000000-0000-0000-0000-000000000011","name":"Manual","revision":2,"trigger":{"manual":{}},"action":{"request":"manual","projectID":"00000000-0000-0000-0000-000000000002","workspaceID":"00000000-0000-0000-0000-000000000001","helperID":"00000000-0000-0000-0000-000000000003","skillIDs":["00000000-0000-0000-0000-000000000004"],"connectionAccountIDs":[]},"permissionRecordIDs":[],"notificationEnabled":true,"state":"active","createdAt":100,"updatedAt":110}],
        "automationRuns":[{"id":"00000000-0000-0000-0000-000000000016","automationID":"00000000-0000-0000-0000-000000000011","taskID":"00000000-0000-0000-0000-000000000007","status":"completed","summary":"done","startedAt":105,"finishedAt":106}],
        "memoryNodes":[{"id":"00000000-0000-0000-0000-000000000013","label":"Topic","content":"content","kind":"topic","confidence":0.9,"scope":{"project":{"_0":"00000000-0000-0000-0000-000000000002"}},"citationIDs":["00000000-0000-0000-0000-000000000012"],"creationMethod":"imported","state":"confirmed","createdAt":100,"updatedAt":110}],
        "memoryEdges":[{"id":"00000000-0000-0000-0000-000000000017","sourceNodeID":"00000000-0000-0000-0000-000000000013","targetNodeID":"00000000-0000-0000-0000-000000000013","relation":"sourcedFrom","explanation":"legacy","confidence":0.8,"scope":{"project":{"_0":"00000000-0000-0000-0000-000000000002"}},"citationIDs":["00000000-0000-0000-0000-000000000012"],"state":"confirmed","createdAt":100,"updatedAt":110}],
        "memoryCitations":[{"id":"00000000-0000-0000-0000-000000000012","sourceType":"manualImport","sourceID":"source","scopeID":"00000000-0000-0000-0000-000000000002","title":"Citation","stableLocator":"section-1","excerpt":"excerpt","contentChecksum":"checksum","authorizationState":"authorized","createdAt":100,"updatedAt":110}],
        "voiceSessions":[{"id":"00000000-0000-0000-0000-000000000018","dimension":"helper","taskID":"00000000-0000-0000-0000-000000000007","conversationID":"00000000-0000-0000-0000-000000000019","helperID":"00000000-0000-0000-0000-000000000003","transcriptMessageIDs":["00000000-0000-0000-0000-000000000023"],"permissionRecordIDs":["00000000-0000-0000-0000-000000000008"],"state":"ended","localeIdentifier":"en-US","audioWasPersisted":false,"startedAt":100,"endedAt":110,"updatedAt":110}]
      }
    }
    """#.utf8)

    @Test("Literal v1 preserves every collection, repairs artifact links, and commits v3")
    func migratesV1AndAtomicallyCommits() throws {
        let (store, fileURL, cleanup) = try makeStore(with: Self.v1Fixture)
        defer { cleanup() }

        let migrated = try store.load()

        #expect(migrated.permissions.count == 1)
        #expect(migrated.tasks.count == 1)
        #expect(migrated.workspaces.count == 1)
        #expect(migrated.projects.count == 1)
        #expect(migrated.helpers.count == 1)
        #expect(migrated.skills.count == 1)
        #expect(migrated.connectors.count == 1)
        #expect(migrated.connectionAccounts.count == 1)
        #expect(migrated.files.count == 1)
        #expect(migrated.artifacts.count == 1)
        #expect(migrated.templates.count == 1)
        #expect(migrated.automations.count == 1)
        #expect(migrated.automationRuns.count == 1)
        #expect(migrated.memoryNodes.count == 1)
        #expect(migrated.memoryEdges.count == 1)
        #expect(migrated.memoryCitations.count == 1)
        #expect(migrated.voiceSessions.count == 1)
        #expect(migrated.tasks[0].artifactIDs == [Self.artifactID])
        #expect(migrated.tasks[0].helperSelectionIntent == .inheritProjectDefaults)
        #expect(migrated.tasks[0].skillSelectionIntent == .inheritProjectDefaults)
        #expect(migrated.tasks[0].connectionAccountSelectionIntent == .inheritProjectDefaults)
        #expect(migrated.artifacts[0].fileID == Self.artifactID)
        #expect(migrated.files[0].originTaskID == Self.taskID)
        #expect(migrated.skillPackages.isEmpty)
        #expect(migrated.connectorBindings.isEmpty)
        #expect(migrated.permissionGrants.isEmpty)
        #expect(migrated.executionAuditEvents.isEmpty)
        #expect(try schemaVersion(at: fileURL) == 3)
    }

    @Test("Literal v2 migrates all trigger cases and adds only fail-closed v3 defaults")
    func migratesV2AndAtomicallyCommits() throws {
        let (store, fileURL, cleanup) = try makeStore(with: Self.v2Fixture)
        defer { cleanup() }

        let migrated = try store.load()

        #expect(migrated.tasks[0].conversationID?.uuidString.hasSuffix("19") == true)
        #expect(migrated.tasks[0].helperSelectionIntent == .inheritProjectDefaults)
        #expect(migrated.tasks[0].skillSelectionIntent == .inheritProjectDefaults)
        #expect(migrated.tasks[0].connectionAccountSelectionIntent == .inheritProjectDefaults)
        #expect(migrated.files[0].id == Self.artifactID)
        #expect(migrated.skills[0].state == .unavailable)
        #expect(migrated.connectionAccounts[0].credentialReference
            == "youzi.connector.\(Self.accountID.uuidString.lowercased())")
        #expect(migrated.skillPackages.isEmpty)
        #expect(migrated.connectorBindings.isEmpty)
        #expect(migrated.permissionGrants.isEmpty)
        #expect(migrated.executionAuditEvents.isEmpty)
        #expect(migrated.automations.allSatisfy { $0.permissionGrantIDs.isEmpty })
        let manual = try #require(migrated.automations.first { $0.name == "Manual" })
        #expect(manual.state == .needsAttention)
        #expect(manual.confirmedAt == nil)
        #expect(migrated.automations.filter { $0.name != "Manual" }
            .allSatisfy { $0.confirmedAt != nil })
        #expect(migrated.automationRuns[0].automationRevision == 2)
        #expect(migrated.automationRuns[0].permissionGrantIDs.isEmpty)
        #expect(migrated.automationRuns[0].attemptCount == 1)
        #expect(migrated.automations.contains { if case .manual = $0.trigger { true } else { false } })
        #expect(migrated.automations.contains {
            if case let .interval(seconds, anchor) = $0.trigger {
                return seconds == 300 && anchor == Date(timeIntervalSinceReferenceDate: 101)
            }
            return false
        })
        #expect(migrated.automations.contains {
            if case let .schedule(expression, zone) = $0.trigger {
                return expression == "0 17 * * 5" && zone == "Asia/Shanghai"
            }
            return false
        })
        #expect(try schemaVersion(at: fileURL) == 3)
    }

    @Test("Frozen decoders are deterministic and failed migration writes preserve exact bytes")
    func retryIsSafe() throws {
        #expect(try YouziDomainV1Migration.decode(Self.v1Fixture)
            == YouziDomainV1Migration.decode(Self.v1Fixture))
        #expect(try YouziDomainV2Migration.decode(Self.v2Fixture)
            == YouziDomainV2Migration.decode(Self.v2Fixture))

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("youzi-v1-retry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("domain.json")
        try Self.v1Fixture.write(to: fileURL)

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
        #expect(try Data(contentsOf: fileURL) == Self.v1Fixture)
        #expect(try YouziDomainStore(fileURL: fileURL).load().files.count == 1)
    }

    @Test("Invalid legacy credential references migrate without preserving the value")
    func stripsInvalidCredentialReferences() throws {
        let sentinel = "CREDENTIAL_SENTINEL_DO_NOT_PERSIST"
        let fixture = Data(
            String(decoding: Self.v2Fixture, as: UTF8.self)
                .replacingOccurrences(
                    of: "youzi.connector.00000000-0000-0000-0000-000000000006",
                    with: sentinel
                ).utf8
        )
        let (store, fileURL, cleanup) = try makeStore(with: fixture)
        defer { cleanup() }

        let migrated = try store.load()

        #expect(migrated.connectionAccounts[0].credentialReference == nil)
        #expect(migrated.connectionAccounts[0].state == .needsAttention)
        #expect(migrated.connectionAccounts[0].recoveryCode == .credentialMissing)
        #expect(!String(decoding: try Data(contentsOf: fileURL), as: UTF8.self).contains(sentinel))
    }

    @Test("Known v2 corruption is quarantined with its exact bytes")
    func corruptV2IsQuarantined() throws {
        let corrupt = Data(
            String(decoding: Self.v2Fixture, as: UTF8.self)
                .replacingOccurrences(of: "\"title\":\"Legacy task\",", with: "")
                .utf8
        )
        let (store, fileURL, cleanup) = try makeStore(with: corrupt)
        defer { cleanup() }

        do {
            _ = try store.load()
            Issue.record("Expected corrupt v2 quarantine")
        } catch let error as YouziDomainStoreError {
            guard case let .corruptFile(originalURL, recoveryURL) = error else {
                Issue.record("Expected corruptFile, got \(error)")
                return
            }
            #expect(originalURL == fileURL)
            let recovered = try #require(recoveryURL)
            #expect(try Data(contentsOf: recovered) == corrupt)
            #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        }
    }

    @Test("Unsupported v4 remains byte-identical and is never quarantined")
    func unsupportedVersionPreservesBytes() throws {
        let unsupported = Data(
            String(decoding: Self.v2Fixture, as: UTF8.self)
                .replacingOccurrences(of: "\"schemaVersion\":2", with: "\"schemaVersion\":4")
                .utf8
        )
        let (store, fileURL, cleanup) = try makeStore(with: unsupported)
        defer { cleanup() }

        do {
            _ = try store.load()
            Issue.record("Expected unsupported schema version")
        } catch let error as YouziDomainStoreError {
            guard case let .unsupportedSchemaVersion(found, supported) = error else {
                Issue.record("Expected unsupportedSchemaVersion, got \(error)")
                return
            }
            #expect(found == 4)
            #expect(supported == 3)
        }
        #expect(try Data(contentsOf: fileURL) == unsupported)
    }

    @Test("Post-migration graph validation failure preserves exact v2 bytes")
    func validationFailurePreservesV2Bytes() throws {
        let invalid = Data(
            String(decoding: Self.v2Fixture, as: UTF8.self)
                .replacingOccurrences(
                    of: "\"workspaceID\":\"00000000-0000-0000-0000-000000000001\"",
                    with: "\"workspaceID\":\"ffffffff-0000-0000-0000-000000000001\""
                ).utf8
        )
        let (store, fileURL, cleanup) = try makeStore(with: invalid)
        defer { cleanup() }

        do {
            _ = try store.load()
            Issue.record("Expected post-migration graph validation failure")
        } catch let error as YouziDomainStoreError {
            guard case let .invalidDocument(issues) = error else {
                Issue.record("Expected invalidDocument, got \(error)")
                return
            }
            #expect(issues.contains { $0.code == .danglingReference })
        }
        #expect(try Data(contentsOf: fileURL) == invalid)
    }

    private func makeStore(with data: Data) throws
        -> (YouziDomainStore, URL, () -> Void)
    {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("youzi-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fileURL = root.appendingPathComponent("domain.json")
        try data.write(to: fileURL)
        return (
            YouziDomainStore(fileURL: fileURL),
            fileURL,
            { try? FileManager.default.removeItem(at: root) }
        )
    }

    private func schemaVersion(at url: URL) throws -> Int? {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return (object as? [String: Any])?["schemaVersion"] as? Int
    }
}
