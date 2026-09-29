import Foundation
import Testing
@testable import Rapid

@Suite("Youzi Memory SQLite authority", .serialized)
struct YouziMemoryRepositoryTests {
    private final class Fixture {
        let root: URL
        let databaseURL: URL
        let repository: YouziMemoryRepository

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "youzi-memory-\(UUID().uuidString)", isDirectory: true
            )
            databaseURL = root.appendingPathComponent("memory.sqlite")
            repository = try YouziMemoryRepository(databaseURL: databaseURL)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func source(
        id: UUID = UUID(),
        scope: YouziMemoryScopeRecord = .personal,
        authorization: YouziMemorySourceAuthorization = .authorized,
        title: String = "家庭旅行对话"
    ) -> YouziMemorySourceRecord {
        .init(
            id: id, kind: .chat, externalIdentifier: UUID().uuidString.lowercased(),
            revision: "chat-r1", title: title, scope: scope,
            permissionID: nil, importMode: nil, authorization: authorization,
            contentChecksum: nil, importedAt: now, updatedAt: now, deletedAt: nil
        )
    }

    private func citation(
        id: UUID = UUID(),
        sourceID: UUID,
        excerpt: String = "用户喜欢安静的海边酒店"
    ) -> YouziMemoryCitationRecord {
        .init(
            id: id, sourceID: sourceID, sourceRevision: "chat-r1",
            locator: .init(kind: .message, key: UUID().uuidString.lowercased(), detail: "user", ordinal: 3),
            sourceTimestamp: now, excerpt: excerpt,
            contentChecksum: String(repeating: "a", count: 64), createdAt: now
        )
    }

    private func context(
        scopes: Set<YouziMemoryScopeRecord> = [.personal],
        sensitive: Bool = false,
        propose: Bool = true,
        manage: Bool = true
    ) -> YouziMemoryAccessContext {
        .init(
            requestID: UUID(), allowedScopes: scopes,
            mayReadSensitive: sensitive, mayPropose: propose,
            mayManageCandidates: manage, maximumResults: 20
        )
    }

    private func batch(
        source: YouziMemorySourceRecord,
        citationID: UUID,
        nodes: [YouziMemoryNodeCandidate],
        edges: [YouziMemoryEdgeCandidate] = [],
        key: String = "proposal-v1"
    ) -> YouziMemoryCandidateBatch {
        .init(
            idempotencyKey: key, sourceID: source.id,
            sourceRevision: source.revision, policyVersion: "policy-v1",
            nodes: nodes, edges: edges, submittedAt: now
        )
    }

    private func candidate(
        id: UUID = UUID(),
        key: String,
        content: String,
        citationID: UUID,
        sensitivity: YouziMemorySensitivity = .ordinary,
        scope: YouziMemoryScopeRecord = .personal,
        confidence: Double = 0.9
    ) -> YouziMemoryNodeCandidate {
        .init(
            id: id, canonicalKey: key, label: content, content: content,
            kind: .preference, confidence: confidence, sensitivity: sensitivity,
            scope: scope, validFrom: nil, validUntil: nil,
            citationIDs: [citationID], categoryIDs: []
        )
    }

    @Test("Fresh schema is private, current, and upgrades a real v1 layout")
    func schemaAndMigration() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let version = try await fixture.repository.schemaVersion()
        #expect(version == 2)
        let permissions = try FileManager.default.attributesOfItem(atPath: fixture.databaseURL.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)

        let oldRoot = FileManager.default.temporaryDirectory.appendingPathComponent("youzi-memory-v1-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: oldRoot) }
        let oldURL = oldRoot.appendingPathComponent("memory.sqlite")
        try YouziMemoryRepository.createVersionOneFixture(at: oldURL)
        let upgraded = try YouziMemoryRepository(databaseURL: oldURL)
        let upgradedVersion = try await upgraded.schemaVersion()
        #expect(upgradedVersion == 2)
        try await upgraded.integrityCheck()
    }

    @Test("Unsupported future schema and missing evidence fail closed without raw errors")
    func failClosed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("youzi-memory-future-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("memory.sqlite")
        try YouziMemoryRepository.createUnsupportedSchemaFixture(at: url, version: 99)
        #expect(throws: YouziMemoryRepositoryError.unsupportedSchemaVersion(99)) {
            try YouziMemoryRepository(databaseURL: url)
        }

        let fixture = try Fixture()
        defer { fixture.remove() }
        let orphan = citation(sourceID: UUID())
        await #expect(throws: YouziMemoryRepositoryError.recordNotFound) {
            try await fixture.repository.addCitation(orphan)
        }
        let description = YouziMemoryRepositoryError.databaseUnavailable.localizedDescription
        #expect(!description.contains("sqlite"))
        #expect(!description.contains("SELECT"))
    }

    @Test("FTS returns confirmed cited memory and source revoke removes search and excerpt")
    func ftsEvidenceAndRevocation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = source()
        let citation = citation(sourceID: source.id)
        try await fixture.repository.registerSource(source)
        try await fixture.repository.addCitation(citation)
        let node = candidate(key: "quiet seaside hotel", content: "偏好安静的海边酒店", citationID: citation.id)
        let service = YouziMemoryMCPService(repository: fixture.repository)
        let result = try await service.propose(
            batch(source: source, citationID: citation.id, nodes: [node]),
            context: context()
        )
        #expect(result.nodeIDs == [node.id])
        let proposed = try #require(await fixture.repository.node(id: node.id))
        _ = try await service.confirm(
            nodeID: node.id, expectedRevision: proposed.revision,
            context: context(), at: now.addingTimeInterval(1)
        )

        let before = try await service.search("海边酒店", context: context(manage: false))
        #expect(before.map(\.node.id) == [node.id])
        let evidence = try await service.queryCitations(nodeID: node.id, context: context(manage: false))
        #expect(evidence.first?.excerpt == citation.excerpt)

        _ = try await fixture.repository.revokeSource(id: source.id, at: now.addingTimeInterval(2))
        let after = try await service.search("海边酒店", context: context(manage: false))
        #expect(after.isEmpty)
        let revokedEvidence = try await service.queryCitations(nodeID: node.id, context: context(manage: false))
        #expect(revokedEvidence.first?.excerpt == "")
        try await fixture.repository.integrityCheck()
    }

    @Test("Proposal replay and concurrent delivery commit exactly once")
    func idempotencyAndConcurrency() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = source()
        let citation = citation(sourceID: source.id)
        try await fixture.repository.registerSource(source)
        try await fixture.repository.addCitation(citation)
        let node = candidate(key: "uses swift", content: "使用 Swift", citationID: citation.id)
        let proposal = batch(source: source, citationID: citation.id, nodes: [node], key: "concurrent-proposal")
        let service = YouziMemoryMCPService(repository: fixture.repository)
        let access = context()

        let results = try await withThrowingTaskGroup(of: YouziMemoryProposalResult.self) { group in
            for _ in 0..<20 {
                group.addTask { try await service.propose(proposal, context: access) }
            }
            var collected: [YouziMemoryProposalResult] = []
            for try await result in group { collected.append(result) }
            return collected
        }
        #expect(results.count == 20)
        #expect(results.filter { !$0.wasReplay }.count == 1)
        #expect(results.allSatisfy { $0.nodeIDs == [node.id] })
        let stored = try #require(await fixture.repository.node(id: node.id))
        #expect(stored.revision == 1)
        try await fixture.repository.integrityCheck()
    }

    @Test("Secret-shaped text is redacted before every durable channel")
    func privacyRedaction() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let secret = "SUPERSECRET_SENTINEL_123456"
        let source = source(title: "Bearer \(secret)")
        let citation = citation(sourceID: source.id, excerpt: "token=\(secret) private note")
        try await fixture.repository.registerSource(source)
        let storedCitation = try await fixture.repository.addCitation(citation)
        #expect(!storedCitation.excerpt.contains(secret))
        let node = candidate(
            key: "password=\(secret)", content: "api_key=\(secret)", citationID: citation.id
        )
        let service = YouziMemoryMCPService(repository: fixture.repository)
        _ = try await service.propose(
            batch(source: source, citationID: citation.id, nodes: [node], key: "privacy-proposal"),
            context: context()
        )
        let storedNode = try #require(await fixture.repository.node(id: node.id))
        #expect(!storedNode.content.contains(secret))
        #expect(!storedNode.canonicalKey.contains(secret.lowercased()))

        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: fixture.databaseURL.path + suffix)
            guard let data = try? Data(contentsOf: url) else { continue }
            #expect(data.range(of: Data(secret.utf8)) == nil)
        }
    }

    @Test("Idle admission excludes private capture and queue leases recover without duplicate jobs")
    func ingestionQueue() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = source()
        let denied = YouziMemoryIngestionAdmission(
            source: source, extractorVersion: "extractor-v1", policyVersion: "policy-v1",
            priority: 5, captureAllowed: false, admittedAt: now
        )
        await #expect(throws: YouziMemoryRepositoryError.sourceUnauthorized) {
            try await fixture.repository.admit(denied)
        }
        let missing = try await fixture.repository.source(id: source.id)
        #expect(missing == nil)

        var allowed = denied
        allowed.captureAllowed = true
        let queued = try await fixture.repository.admit(allowed)
        let replay = try await fixture.repository.admit(allowed)
        #expect(queued.id == replay.id)

        let repository = fixture.repository
        let claimTime = now
        let claimed = await withTaskGroup(of: YouziMemoryIngestionJob?.self) { group in
            group.addTask { try? await repository.claimNext(workerID: "worker-a", leaseDuration: 60, at: claimTime) }
            group.addTask { try? await repository.claimNext(workerID: "worker-b", leaseDuration: 60, at: claimTime) }
            var values: [YouziMemoryIngestionJob] = []
            for await value in group { if let value { values.append(value) } }
            return values
        }
        #expect(claimed.count == 1)
        #expect(claimed.first?.attemptCount == 1)
        let owner = try #require(claimed.first?.leaseOwner)
        await #expect(throws: YouziMemoryRepositoryError.revisionConflict) {
            try await fixture.repository.settle(
                jobID: queued.id, workerID: "wrong-worker", outcome: .completed,
                recoveryCode: nil, retryAt: nil, at: now.addingTimeInterval(1)
            )
        }
        let reclaimed = try #require(await fixture.repository.claimNext(
            workerID: "worker-c", leaseDuration: 30, at: now.addingTimeInterval(61)
        ))
        #expect(reclaimed.id == queued.id)
        #expect(reclaimed.attemptCount == 2)
        #expect(reclaimed.leaseOwner == "worker-c")
        _ = owner
        let completed = try await fixture.repository.settle(
            jobID: queued.id, workerID: "worker-c", outcome: .completed,
            recoveryCode: nil, retryAt: nil, at: now.addingTimeInterval(62)
        )
        #expect(completed.state == .completed)
    }

    @Test("File import persists metadata and queue identity but accepts no raw file payload")
    func fileImport() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let request = YouziMemoryFileImportRequest(
            sourceID: UUID(), fileID: UUID(), displayName: "旅行计划.pdf",
            uniformTypeIdentifier: "public.pdf", byteCount: 2_048,
            sha256: String(repeating: "b", count: 64), mode: .securityScopedReference,
            scope: .personal, permissionID: UUID(), importedAt: now,
            extractorVersion: "extractor-v1", policyVersion: "policy-v1"
        )
        let service = YouziMemoryMCPService(repository: fixture.repository)
        let first = try await service.importFile(request, context: context())
        let replay = try await service.importFile(request, context: context())
        #expect(first.sourceID == request.sourceID)
        #expect(first.jobID == replay.jobID)
        #expect(!first.wasAlreadyImported)
        #expect(replay.wasAlreadyImported)

        var unsupported = request
        unsupported.sourceID = UUID()
        unsupported.fileID = UUID()
        unsupported.uniformTypeIdentifier = "public.executable"
        await #expect(throws: YouziMemoryRepositoryError.invalidInput(.unsupportedFile)) {
            try await service.importFile(unsupported, context: context())
        }
    }

    @Test("Manual file categories are explicit, idempotent, and cannot widen app scope")
    func fileClassification() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let categories = try await fixture.repository.seedSystemCategories(at: now)
        #expect(categories.map(\.name) == [
            "关于我", "人物与关系", "偏好与习惯", "目标与计划", "经历与事件",
            "项目与工作", "知识主题", "重要日期", "待确认"
        ])
        let preference = try #require(categories.first { $0.name == "偏好与习惯" })
        let project = try #require(categories.first { $0.name == "项目与工作" })
        let request = YouziMemoryFileImportRequest(
            sourceID: UUID(), fileID: UUID(), displayName: "偏好.md",
            uniformTypeIdentifier: "net.daringfireball.markdown", byteCount: 1_024,
            sha256: String(repeating: "d", count: 64), mode: .managedCopy,
            scope: .personal, permissionID: UUID(), categoryIDs: [preference.id],
            importedAt: now, extractorVersion: "extractor-v1", policyVersion: "policy-v1"
        )
        let service = YouziMemoryMCPService(repository: fixture.repository)
        _ = try await service.importFile(request, context: context())
        let initialCategories = try await fixture.repository.sourceCategoryIDs(sourceID: request.sourceID)
        #expect(initialCategories == [preference.id])

        let projectScope = YouziMemoryScopeRecord.project(UUID())
        let personalOnly = context(scopes: [.personal])
        await #expect(throws: YouziMemoryRepositoryError.operationNotPermitted) {
            try await service.classifySource(
                sourceID: request.sourceID, scope: projectScope,
                categoryIDs: [project.id], context: personalOnly,
                at: now.addingTimeInterval(1)
            )
        }
        let broad = context(scopes: [.personal, projectScope])
        let classified = try await service.classifySource(
            sourceID: request.sourceID, scope: projectScope,
            categoryIDs: [project.id], context: broad,
            at: now.addingTimeInterval(2)
        )
        #expect(classified.scope == projectScope)
        let changedCategories = try await fixture.repository.sourceCategoryIDs(sourceID: request.sourceID)
        #expect(changedCategories == [project.id])

        var missingCategory = request
        missingCategory.sourceID = UUID()
        missingCategory.fileID = UUID()
        missingCategory.sha256 = String(repeating: "e", count: 64)
        missingCategory.categoryIDs = [UUID()]
        await #expect(throws: YouziMemoryRepositoryError.recordNotFound) {
            try await service.importFile(missingCategory, context: context())
        }
        let noPartialSource = try await fixture.repository.source(id: missingCategory.sourceID)
        #expect(noPartialSource == nil)
    }

    @Test("Settled conversation queue stores only stable segment references and rejects exclusions atomically")
    func settledConversationAdmission() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let sourceID = UUID()
        let conversationID = UUID()
        let taskID = UUID()
        let workspaceID = UUID()
        let segments = [
            YouziMemoryIngestionSegmentReference(
                id: UUID(), checksum: String(repeating: "1", count: 64), ordinal: 0
            ),
            YouziMemoryIngestionSegmentReference(
                id: UUID(), checksum: String(repeating: "2", count: 64), ordinal: 1
            )
        ]
        let request = YouziMemorySettledConversationRequest(
            sourceID: sourceID, conversationID: conversationID,
            sourceRevision: "conversation-r7", title: "家庭行程",
            taskID: taskID, workspaceID: workspaceID, projectID: nil,
            capturePolicy: .allowed, segments: segments, settledAt: now,
            extractorVersion: "extractor-v1", policyVersion: "policy-v1"
        )
        let service = YouziMemoryBackgroundIngestionService(queue: fixture.repository)
        let first = try await service.enqueueSettledConversation(request)
        let replay = try await service.enqueueSettledConversation(request)
        #expect(first.id == replay.id)
        #expect(try await service.segments(jobID: first.id) == segments)
        let storedSource = try #require(await fixture.repository.source(id: sourceID))
        #expect(storedSource.externalIdentifier == conversationID.uuidString.lowercased())
        #expect(storedSource.taskID == taskID)
        #expect(storedSource.workspaceID == workspaceID)
        #expect(storedSource.scope == .workspace(workspaceID))

        var changedSnapshot = request
        changedSnapshot.segments[1].checksum = String(repeating: "3", count: 64)
        await #expect(throws: YouziMemoryRepositoryError.revisionConflict) {
            try await service.enqueueSettledConversation(changedSnapshot)
        }

        for policy in [
            YouziMemoryConversationCapturePolicy.doNotRemember,
            YouziMemoryConversationCapturePolicy.privateSession
        ] {
            var excluded = request
            excluded.sourceID = UUID()
            excluded.conversationID = UUID()
            excluded.capturePolicy = policy
            await #expect(throws: YouziMemoryRepositoryError.sourceUnauthorized) {
                try await service.enqueueSettledConversation(excluded)
            }
            let excludedSource = try await fixture.repository.source(id: excluded.sourceID)
            #expect(excludedSource == nil)
        }

        var invalid = request
        invalid.sourceID = UUID()
        invalid.conversationID = UUID()
        invalid.segments[0].checksum = "not-a-checksum"
        await #expect(throws: YouziMemoryRepositoryError.invalidInput(.invalidChecksum)) {
            try await service.enqueueSettledConversation(invalid)
        }
        let invalidSource = try await fixture.repository.source(id: invalid.sourceID)
        #expect(invalidSource == nil)
    }

    @Test("Built-in service intersects app scopes and requires injected mutation authority")
    func serviceScopeAndAuthority() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let projectID = UUID()
        let projectScope = YouziMemoryScopeRecord.project(projectID)
        let source = source(scope: projectScope)
        let citation = citation(sourceID: source.id)
        try await fixture.repository.registerSource(source)
        try await fixture.repository.addCitation(citation)
        let node = candidate(
            key: "project preference", content: "项目偏好", citationID: citation.id,
            sensitivity: .sensitive, scope: projectScope
        )
        let proposal = batch(source: source, citationID: citation.id, nodes: [node])
        let service = YouziMemoryMCPService(repository: fixture.repository)

        await #expect(throws: YouziMemoryRepositoryError.operationNotPermitted) {
            try await service.propose(proposal, context: context(scopes: [.personal]))
        }
        let projectContext = context(scopes: [projectScope], sensitive: true)
        _ = try await service.propose(proposal, context: projectContext)
        let hidden = try await service.queryNodes(
            ids: [node.id], context: context(scopes: [projectScope], sensitive: false)
        )
        #expect(hidden.isEmpty)
        let visible = try await service.queryNodes(ids: [node.id], context: projectContext)
        #expect(visible.map(\.id) == [node.id])

        let readOnly = context(scopes: [projectScope], sensitive: true, propose: false, manage: false)
        await #expect(throws: YouziMemoryRepositoryError.operationNotPermitted) {
            try await service.revoke(
                candidateID: node.id, expectedRevision: 1,
                context: readOnly, at: now.addingTimeInterval(1)
            )
        }
    }

    @Test("Merge is revision guarded and undo restores the duplicate without moving evidence")
    func mergeAndUndo() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = source()
        let citation = citation(sourceID: source.id)
        try await fixture.repository.registerSource(source)
        try await fixture.repository.addCitation(citation)
        let first = candidate(key: "prefers tea", content: "喜欢茶", citationID: citation.id)
        let second = candidate(key: "tea habit", content: "常喝茶", citationID: citation.id)
        let edge = YouziMemoryEdgeCandidate(
            id: UUID(), sourceNodeID: first.id, targetNodeID: second.id,
            relation: .conflictsWith, explanation: "待确认是否为同一偏好",
            confidence: 0.8, sensitivity: .ordinary, scope: .personal,
            validFrom: nil, validUntil: nil, citationIDs: [citation.id]
        )
        let service = YouziMemoryMCPService(repository: fixture.repository)
        _ = try await service.propose(
            batch(
                source: source, citationID: citation.id, nodes: [first, second],
                edges: [edge], key: "merge-pair"
            ),
            context: context()
        )
        let proposedRelations = try await service.queryRelations(
            nodeID: first.id, context: context()
        )
        #expect(proposedRelations.map(\.id) == [edge.id])
        let mergeID = try await service.merge(
            primaryID: first.id, duplicateID: second.id,
            expectedPrimaryRevision: 1, expectedDuplicateRevision: 1,
            context: context(), at: now.addingTimeInterval(1)
        )
        let merged = try #require(await fixture.repository.node(id: second.id))
        #expect(merged.state == .superseded)
        #expect(merged.mergedIntoID == first.id)
        await #expect(throws: YouziMemoryRepositoryError.revisionConflict) {
            try await service.merge(
                primaryID: first.id, duplicateID: second.id,
                expectedPrimaryRevision: 1, expectedDuplicateRevision: 1,
                context: context(), at: now.addingTimeInterval(2)
            )
        }
        try await service.undoMerge(mergeID: mergeID, context: context(), at: now.addingTimeInterval(3))
        let restored = try #require(await fixture.repository.node(id: second.id))
        #expect(restored.state == .proposed)
        #expect(restored.mergedIntoID == nil)
        let evidence = try await service.queryCitations(nodeID: second.id, context: context())
        #expect(evidence.map(\.id) == [citation.id])
        let forgotten = try await service.forget(
            nodeID: second.id, expectedRevision: restored.revision,
            context: context(), at: now.addingTimeInterval(4)
        )
        #expect(forgotten.state == .forgotten)
        #expect(forgotten.deletedAt != nil)
        let noLongerSearchable = try await service.search("常喝茶", context: context())
        #expect(noLongerSearchable.isEmpty)
        let forgottenRelations = try await service.queryRelations(
            nodeID: first.id, context: context()
        )
        #expect(forgottenRelations.isEmpty)
    }

    @Test("Legacy JSON and domain graph import once with stable IDs and complete references")
    func legacyMigration() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let citationID = UUID()
        let firstID = UUID()
        let secondID = UUID()
        let edgeID = UUID()
        let domainCitation = YouziMemoryCitation(
            id: citationID, sourceType: .chat, sourceID: UUID().uuidString,
            title: "旧对话", stableLocator: "message-4", excerpt: "用户喜欢徒步",
            contentChecksum: String(repeating: "c", count: 64), createdAt: now, updatedAt: now
        )
        let first = YouziMemoryNode(
            id: firstID, label: "用户", content: "用户本人", kind: .user,
            confidence: 1, scope: .personal, citationIDs: [citationID],
            creationMethod: .userConfirmed, state: .confirmed,
            createdAt: now, updatedAt: now, lastConfirmedAt: now
        )
        let second = YouziMemoryNode(
            id: secondID, label: "徒步", content: "喜欢徒步", kind: .preference,
            confidence: 0.9, scope: .personal, citationIDs: [citationID],
            creationMethod: .extracted, state: .confirmed,
            createdAt: now, updatedAt: now, lastConfirmedAt: now
        )
        let edge = YouziMemoryEdge(
            id: edgeID, sourceNodeID: firstID, targetNodeID: secondID,
            relation: .likes, explanation: "用户明确表达", confidence: 0.9,
            scope: .personal, citationIDs: [citationID], state: .confirmed,
            createdAt: now, updatedAt: now
        )
        let legacyID = UUID()
        let library = MemoryLibrary(
            entries: [MemoryEntry(
                id: legacyID, content: "习惯早起", evidenceCount: 2,
                sourceConversationIDs: [UUID()], createdAt: now, updatedAt: now
            )]
        )
        let imported = try await fixture.repository.migrateLegacy(
            library: library, domainNodes: [first, second], domainEdges: [edge],
            domainCitations: [domainCitation], at: now
        )
        #expect(imported.importedNodes == 3)
        #expect(imported.importedEdges == 1)
        #expect(imported.importedLegacyEntries == 1)
        #expect(try await fixture.repository.node(id: firstID)?.id == firstID)
        #expect(try await fixture.repository.node(id: legacyID)?.state == .awaitingConfirmation)
        let service = YouziMemoryMCPService(repository: fixture.repository)
        let relations = try await service.queryRelations(
            nodeID: firstID, context: context(manage: false)
        )
        #expect(relations.isEmpty)
        let legacyEvidence = try await service.queryCitations(
            nodeID: firstID, context: context(manage: false)
        )
        #expect(legacyEvidence.first?.excerpt == "")
        let replay = try await fixture.repository.migrateLegacy(
            library: library, domainNodes: [first, second], domainEdges: [edge],
            domainCitations: [domainCitation], at: now.addingTimeInterval(1)
        )
        #expect(replay.wasAlreadyApplied)
        try await fixture.repository.integrityCheck()
    }
}
