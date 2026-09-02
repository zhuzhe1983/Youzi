import Foundation
import Testing
@testable import Rapid

@Suite("YouziDomain — versioned atomic metadata graph")
struct YouziDomainTests {
    private func isolatedStore() throws -> (root: URL, store: YouziDomainStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("youzi-domain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, YouziDomainStore(fileURL: root.appendingPathComponent("domain.json")))
    }

    private func id(_ suffix: String) -> UUID {
        UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!
    }

    private func completeDocument() -> YouziDomainDocument {
        let created = Date(timeIntervalSince1970: 1_800_000_000)
        let updated = Date(timeIntervalSince1970: 1_800_000_100)
        let workspaceID = id("000000000001")
        let projectID = id("000000000002")
        let helperID = id("000000000003")
        let skillID = id("000000000004")
        let connectorID = id("000000000005")
        let accountID = id("000000000006")
        let taskID = id("000000000007")
        let permissionID = id("000000000008")
        let artifactID = id("000000000009")
        let templateID = id("000000000010")
        let automationID = id("000000000011")
        let citationID = id("000000000012")
        let userNodeID = id("000000000013")
        let preferenceNodeID = id("000000000014")

        let source = YouziManifestSource(
            kind: .builtIn,
            identifier: "youzi.builtin.research",
            version: "1.0.0"
        )
        let permission = YouziPermissionRecord(
            id: permissionID,
            taskID: taskID,
            kind: .connectorRead,
            targetIdentifier: accountID.uuidString,
            purpose: "Read the selected calendar while preparing a plan",
            duration: .task,
            decision: .allowed,
            requestedAt: created,
            decidedAt: updated
        )
        let workspace = YouziWorkspace(
            id: workspaceID,
            name: "Family planning",
            location: .securityScopedBookmark(
                data: Data([0x01, 0x02, 0x03]),
                displayPath: "~/Documents/Family planning"
            ),
            createdAt: created,
            updatedAt: updated,
            lastAccessedAt: updated
        )
        let project = YouziProject(
            id: projectID,
            name: "Autumn trip",
            summary: "A continuing family trip project",
            instructions: "Prefer direct rail routes",
            preferences: ["currency": "CNY"],
            defaultHelperIDs: [helperID],
            defaultSkillIDs: [skillID],
            defaultConnectionAccountIDs: [accountID],
            createdAt: created,
            updatedAt: updated
        )
        let helper = YouziHelper(
            id: helperID,
            name: "Trip planner",
            summary: "Plans practical itineraries",
            systemInstructions: "Check constraints before proposing a route.",
            methodology: ["Collect constraints", "Compare options"],
            recommendedSkillIDs: [skillID],
            allowedConnectorIDs: [connectorID],
            preferredOutputTypes: ["document"],
            source: source,
            isFavorite: true,
            createdAt: created,
            updatedAt: updated
        )
        let skill = YouziSkill(
            id: skillID,
            name: "Calendar planning",
            summary: "Finds free time and proposes a plan",
            packageVersion: "1.2.0",
            resourcePaths: ["references/planning.md"],
            executionLocation: .hybrid,
            requestedPermissions: [.workspaceRead, .networkAccess],
            connectorDependencyIDs: [connectorID],
            requiresFirstUseConfirmation: true,
            source: source,
            lastUsedAt: updated,
            createdAt: created,
            updatedAt: updated
        )
        let connector = YouziConnector(
            id: connectorID,
            name: "Calendar",
            summary: "Reads selected calendars",
            adapter: .mcp,
            authentication: .oauth,
            declaredScopes: ["calendar.read"],
            toolNames: ["calendar.list_events"],
            source: source,
            createdAt: created,
            updatedAt: updated
        )
        let account = YouziConnectionAccount(
            id: accountID,
            connectorID: connectorID,
            displayName: "Personal calendar",
            credentialReference: "keychain:calendar-account",
            grantedScopes: ["calendar.read"],
            state: .connected,
            lastCheckedAt: updated,
            createdAt: created,
            updatedAt: updated
        )
        let task = YouziTask(
            id: taskID,
            title: "Plan the autumn trip",
            request: "Find dates that work and prepare an itinerary.",
            conversationID: id("000000000015"),
            workspaceID: workspaceID,
            projectID: projectID,
            helperID: helperID,
            skillIDs: [skillID],
            connectionAccountIDs: [accountID],
            permissionRecordIDs: [permissionID],
            artifactIDs: [artifactID],
            status: .completed,
            isPinned: true,
            createdAt: created,
            updatedAt: updated,
            completedAt: updated
        )
        let artifact = YouziArtifact(
            id: artifactID,
            taskID: taskID,
            projectID: projectID,
            title: "Trip plan",
            kind: .document,
            previewText: "Three-day itinerary",
            location: .workspace(workspaceID: workspaceID, relativePath: "Results/trip-plan.md"),
            createdAt: created,
            updatedAt: updated
        )
        let template = YouziTemplate(
            id: templateID,
            name: "Plan a family trip",
            category: "Life planning",
            summary: "Turn constraints into a draft itinerary",
            samplePreview: "A day-by-day plan",
            prefilledRequest: "Help me plan a trip to…",
            recommendedHelperID: helperID,
            recommendedSkillIDs: [skillID],
            recommendedConnectorIDs: [connectorID],
            requiredInputs: ["Destination", "Date range"],
            source: source,
            isFavorite: true,
            createdAt: created,
            updatedAt: updated
        )
        let automation = YouziAutomation(
            id: automationID,
            name: "Weekly trip update",
            trigger: .schedule(cronExpression: "0 17 * * 5", timeZoneIdentifier: "Asia/Shanghai"),
            action: YouziAutomationAction(
                request: "Summarize changes made this week",
                projectID: projectID,
                workspaceID: workspaceID,
                helperID: helperID,
                skillIDs: [skillID],
                connectionAccountIDs: [accountID]
            ),
            permissionRecordIDs: [permissionID],
            nextRunAt: Date(timeIntervalSince1970: 1_800_604_800),
            lastRunAt: updated,
            createdAt: created,
            updatedAt: updated
        )
        let run = YouziAutomationRun(
            id: id("000000000016"),
            automationID: automationID,
            taskID: taskID,
            status: .completed,
            summary: "No scheduling conflicts",
            startedAt: created,
            finishedAt: updated
        )
        let citation = YouziMemoryCitation(
            id: citationID,
            sourceType: .workspaceFile,
            sourceID: "file:travel-plan",
            scopeID: workspaceID,
            title: "Travel plan.md",
            stableLocator: "旅行计划.md#section-4",
            sourceTimestamp: created,
            excerpt: "Prefer direct rail routes.",
            contentChecksum: "sha256:example",
            createdAt: created,
            updatedAt: updated
        )
        let userNode = YouziMemoryNode(
            id: userNodeID,
            label: "Me",
            content: "The owner of this personal graph",
            kind: .user,
            confidence: 1,
            scope: .personal,
            citationIDs: [citationID],
            creationMethod: .userConfirmed,
            state: .confirmed,
            createdAt: created,
            updatedAt: updated,
            lastConfirmedAt: updated
        )
        let preferenceNode = YouziMemoryNode(
            id: preferenceNodeID,
            label: "Direct trains",
            content: "Prefers direct rail routes for family travel",
            kind: .preference,
            confidence: 0.91,
            scope: .project(projectID),
            citationIDs: [citationID],
            creationMethod: .extracted,
            state: .confirmed,
            validFrom: created,
            createdAt: created,
            updatedAt: updated,
            lastConfirmedAt: updated
        )
        let edge = YouziMemoryEdge(
            id: id("000000000017"),
            sourceNodeID: userNodeID,
            targetNodeID: preferenceNodeID,
            relation: .likes,
            explanation: "Repeated preference in the project source",
            confidence: 0.91,
            scope: .project(projectID),
            citationIDs: [citationID],
            state: .confirmed,
            validFrom: created,
            createdAt: created,
            updatedAt: updated
        )
        let voice = YouziVoiceSession(
            id: id("000000000018"),
            dimension: .helper,
            taskID: taskID,
            conversationID: task.conversationID,
            helperID: helperID,
            transcriptMessageIDs: [id("000000000019")],
            permissionRecordIDs: [permissionID],
            state: .speaking,
            localeIdentifier: "zh-Hans-CN",
            inputDeviceID: "default-input",
            outputDeviceID: "default-output",
            startedAt: created,
            updatedAt: updated
        )

        return YouziDomainDocument(
            permissions: [permission],
            tasks: [task],
            workspaces: [workspace],
            projects: [project],
            helpers: [helper],
            skills: [skill],
            connectors: [connector],
            connectionAccounts: [account],
            artifacts: [artifact],
            templates: [template],
            automations: [automation],
            automationRuns: [run],
            memoryNodes: [userNode, preferenceNode],
            memoryEdges: [edge],
            memoryCitations: [citation],
            voiceSessions: [voice]
        )
    }

    @Test("Every declared record and ID reference round-trips")
    func completeGraphRoundTrips() throws {
        let fixture = try isolatedStore()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let expected = completeDocument()

        try fixture.store.save(expected)
        let restored = try fixture.store.load()

        #expect(restored == expected)
        #expect(restored.tasks[0].workspaceID == restored.workspaces[0].id)
        #expect(restored.tasks[0].projectID == restored.projects[0].id)
        #expect(restored.tasks[0].artifactIDs == [restored.artifacts[0].id])
        #expect(restored.connectionAccounts[0].connectorID == restored.connectors[0].id)
        #expect(restored.memoryEdges[0].citationIDs == [restored.memoryCitations[0].id])
        #expect(restored.voiceSessions[0].conversationID == restored.tasks[0].conversationID)
        #expect(restored.helpers[0].source.version == "1.0.0")
        #expect(restored.automations[0].revision == 1)
    }

    @Test("Envelope pins format and schema version from the first write")
    func envelopeIsExplicit() throws {
        let fixture = try isolatedStore()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try fixture.store.save(.empty)
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture.store.fileURL))
                as? [String: Any]
        )

        #expect(object["formatIdentifier"] as? String == YouziDomainSchema.formatIdentifier)
        #expect(object["schemaVersion"] as? Int == YouziDomainSchema.currentVersion)
        #expect(object["document"] is [String: Any])
    }

    @Test("A missing store loads empty without creating a file")
    func missingStoreIsEmpty() throws {
        let fixture = try isolatedStore()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        #expect(try fixture.store.load() == .empty)
        #expect(!FileManager.default.fileExists(atPath: fixture.store.fileURL.path))
    }

    @Test("Unsupported schema versions fail explicitly and remain untouched")
    func unsupportedVersionIsPreserved() throws {
        let fixture = try isolatedStore()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let envelope = YouziDomainEnvelope(
            schemaVersion: YouziDomainSchema.currentVersion + 1,
            document: .empty
        )
        let data = try JSONEncoder().encode(envelope)
        try data.write(to: fixture.store.fileURL)

        do {
            _ = try fixture.store.load()
            Issue.record("Expected an unsupported schema error")
        } catch let error as YouziDomainStoreError {
            #expect(
                error == .unsupportedSchemaVersion(
                    found: YouziDomainSchema.currentVersion + 1,
                    supported: YouziDomainSchema.currentVersion
                )
            )
        }

        #expect(try Data(contentsOf: fixture.store.fileURL) == data)
    }

    @Test("Corrupt storage is quarantined, reported, and then loads empty")
    func corruptFileIsRecoverable() throws {
        let fixture = try isolatedStore()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let corruptData = Data("{not-json".utf8)
        try corruptData.write(to: fixture.store.fileURL)
        var recoveryURL: URL?

        do {
            _ = try fixture.store.load()
            Issue.record("Expected a corruption error")
        } catch let error as YouziDomainStoreError {
            guard case let .corruptFile(originalURL, recovered) = error else {
                Issue.record("Expected corruptFile, got \(error)")
                return
            }
            #expect(originalURL == fixture.store.fileURL)
            recoveryURL = recovered
        }

        let recovered = try #require(recoveryURL)
        let recoveredAttributes = try FileManager.default.attributesOfItem(atPath: recovered.path)
        let recoveredMode = try #require(recoveredAttributes[.posixPermissions] as? NSNumber)
        #expect(!FileManager.default.fileExists(atPath: fixture.store.fileURL.path))
        #expect(try Data(contentsOf: recovered) == corruptData)
        #expect(recoveredMode.intValue & 0o777 == 0o600)
        #expect(try fixture.store.load() == .empty)
    }

    @Test("Atomic saves leave owner-only storage and no temporary file")
    func saveIsAtomicAndOwnerOnly() throws {
        let fixture = try isolatedStore()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try fixture.store.save(completeDocument())
        try fixture.store.save(.empty)

        let fileAttributes = try FileManager.default.attributesOfItem(
            atPath: fixture.store.fileURL.path
        )
        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: fixture.root.path
        )
        let fileMode = try #require(fileAttributes[.posixPermissions] as? NSNumber)
        let directoryMode = try #require(directoryAttributes[.posixPermissions] as? NSNumber)
        let siblings = try FileManager.default.contentsOfDirectory(
            at: fixture.root,
            includingPropertiesForKeys: nil
        )

        #expect(fileMode.intValue & 0o777 == 0o600)
        #expect(directoryMode.intValue & 0o777 == 0o700)
        #expect(siblings.map(\.lastPathComponent) == ["domain.json"])
        #expect(try fixture.store.load() == .empty)
    }

    @Test("Update performs a stable-ID lifecycle transaction")
    func lifecycleUpdateKeepsIdentity() throws {
        let fixture = try isolatedStore()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let original = completeDocument()
        try fixture.store.save(original)

        let updated = try fixture.store.update { document in
            var task = document.tasks[0]
            task.status = .archived
            task.updatedAt = Date(timeIntervalSince1970: 1_800_001_000)
            document.upsert(task)

            var account = document.connectionAccounts[0]
            account.state = .needsAttention
            document.upsert(account)

            var automation = document.automations[0]
            automation.state = .paused
            document.upsert(automation)

            var memory = document.memoryNodes[1]
            memory.state = .forgotten
            document.upsert(memory)

            var citation = document.memoryCitations[0]
            citation.authorizationState = .revoked
            document.upsert(citation)

            var voice = document.voiceSessions[0]
            voice.state = .ended
            voice.endedAt = Date(timeIntervalSince1970: 1_800_001_000)
            document.upsert(voice)
        }

        #expect(updated.tasks.count == original.tasks.count)
        #expect(updated.tasks[0].id == original.tasks[0].id)
        #expect(updated.tasks[0].status == .archived)
        #expect(updated.connectionAccounts[0].state == .needsAttention)
        #expect(updated.automations[0].state == .paused)
        #expect(updated.memoryNodes[1].state == .forgotten)
        #expect(updated.memoryCitations[0].authorizationState == .revoked)
        #expect(updated.voiceSessions[0].state == .ended)
        #expect(try fixture.store.load() == updated)
    }
}
