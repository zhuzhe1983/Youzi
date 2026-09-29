import Foundation

/// Trusted, in-process memory capability. It has no URL, connector, catalog,
/// transport, or secret dependency and can operate only on the authoritative
/// SQLite repository supplied at construction.
struct YouziMemoryMCPService: Sendable {
    private let repository: YouziMemoryRepository

    init(repository: YouziMemoryRepository) {
        self.repository = repository
    }

    var methods: [YouziMemoryMCPMethod] { YouziMemoryMCPMethod.allCases }

    func search(
        _ query: String,
        context: YouziMemoryAccessContext
    ) async throws -> [YouziMemorySearchHit] {
        try await repository.search(query: query, context: context)
    }

    func queryNodes(
        ids: [UUID],
        context: YouziMemoryAccessContext
    ) async throws -> [YouziMemoryNodeRecord] {
        try await repository.nodes(ids: ids, context: context)
    }

    func queryRelations(
        nodeID: UUID,
        context: YouziMemoryAccessContext
    ) async throws -> [YouziMemoryEdgeRecord] {
        try await repository.relations(nodeID: nodeID, context: context)
    }

    func queryCitations(
        nodeID: UUID,
        context: YouziMemoryAccessContext
    ) async throws -> [YouziMemoryCitationRecord] {
        try await repository.citations(nodeID: nodeID, context: context)
    }

    func workbenchSnapshot(
        context: YouziMemoryAccessContext,
        maximumNodes: Int = 120
    ) async throws -> YouziMemoryWorkbenchSnapshot {
        try await repository.workbenchSnapshot(
            context: context, maximumNodes: maximumNodes
        )
    }

    func propose(
        _ batch: YouziMemoryCandidateBatch,
        context: YouziMemoryAccessContext
    ) async throws -> YouziMemoryProposalResult {
        guard context.mayPropose,
              batch.nodes.allSatisfy({ context.allowedScopes.contains($0.scope) }),
              batch.edges.allSatisfy({ context.allowedScopes.contains($0.scope) })
        else { throw YouziMemoryRepositoryError.operationNotPermitted }
        guard let source = try await repository.source(id: batch.sourceID),
              context.allowedScopes.contains(source.scope)
        else { throw YouziMemoryRepositoryError.sourceUnauthorized }
        return try await repository.propose(batch)
    }

    func confirm(
        nodeID: UUID,
        expectedRevision: Int,
        context: YouziMemoryAccessContext,
        at: Date
    ) async throws -> YouziMemoryNodeRecord {
        try requireManage(context)
        guard try await repository.nodes(ids: [nodeID], context: context).count == 1 else {
            throw YouziMemoryRepositoryError.recordNotFound
        }
        return try await repository.confirmNode(
            id: nodeID,
            expectedRevision: expectedRevision,
            requestID: context.requestID,
            at: at
        )
    }

    func merge(
        primaryID: UUID,
        duplicateID: UUID,
        expectedPrimaryRevision: Int,
        expectedDuplicateRevision: Int,
        context: YouziMemoryAccessContext,
        at: Date
    ) async throws -> UUID {
        try requireManage(context)
        let visible = try await repository.nodes(ids: [primaryID, duplicateID], context: context)
        guard visible.count == 2 else { throw YouziMemoryRepositoryError.recordNotFound }
        return try await repository.mergeNodes(
            primaryID: primaryID,
            duplicateID: duplicateID,
            expectedPrimaryRevision: expectedPrimaryRevision,
            expectedDuplicateRevision: expectedDuplicateRevision,
            requestID: context.requestID,
            at: at
        )
    }

    func undoMerge(
        mergeID: UUID,
        context: YouziMemoryAccessContext,
        at: Date
    ) async throws {
        try requireManage(context)
        try await repository.undoMerge(mergeID: mergeID, requestID: context.requestID, at: at)
    }

    func revoke(
        candidateID: UUID,
        expectedRevision: Int,
        context: YouziMemoryAccessContext,
        at: Date
    ) async throws -> YouziMemoryNodeRecord {
        try requireManage(context)
        return try await repository.revokeCandidate(
            id: candidateID,
            expectedRevision: expectedRevision,
            requestID: context.requestID,
            at: at
        )
    }

    /// Soft-deletes derived memory and its connected relations. Source bytes
    /// are intentionally outside this operation and remain owned by their
    /// chat/file store.
    func forget(
        nodeID: UUID,
        expectedRevision: Int,
        context: YouziMemoryAccessContext,
        at: Date
    ) async throws -> YouziMemoryNodeRecord {
        try requireManage(context)
        guard try await repository.nodes(ids: [nodeID], context: context).count == 1 else {
            throw YouziMemoryRepositoryError.recordNotFound
        }
        return try await repository.forgetNode(
            id: nodeID, expectedRevision: expectedRevision,
            requestID: context.requestID, at: at
        )
    }

    func importFile(
        _ request: YouziMemoryFileImportRequest,
        context: YouziMemoryAccessContext
    ) async throws -> YouziMemoryFileImportReceipt {
        try requireManage(context)
        guard context.allowedScopes.contains(request.scope) else {
            throw YouziMemoryRepositoryError.operationNotPermitted
        }
        return try await repository.importFile(request)
    }

    func listCategories(
        context: YouziMemoryAccessContext
    ) async throws -> [YouziMemoryCategoryRecord] {
        guard !context.allowedScopes.isEmpty else {
            throw YouziMemoryRepositoryError.operationNotPermitted
        }
        return try await repository.categories()
    }

    func classifySource(
        sourceID: UUID,
        scope: YouziMemoryScopeRecord,
        categoryIDs: [UUID],
        context: YouziMemoryAccessContext,
        at: Date
    ) async throws -> YouziMemorySourceRecord {
        try requireManage(context)
        guard context.allowedScopes.contains(scope),
              let source = try await repository.source(id: sourceID),
              context.allowedScopes.contains(source.scope)
        else { throw YouziMemoryRepositoryError.operationNotPermitted }
        return try await repository.classifySource(
            id: sourceID, scope: scope, categoryIDs: categoryIDs, at: at
        )
    }

    func classifyNode(
        nodeID: UUID,
        expectedRevision: Int,
        categoryIDs: [UUID],
        context: YouziMemoryAccessContext,
        at: Date
    ) async throws -> YouziMemoryNodeRecord {
        try requireManage(context)
        guard try await repository.nodes(ids: [nodeID], context: context).count == 1 else {
            throw YouziMemoryRepositoryError.recordNotFound
        }
        return try await repository.classifyNode(
            id: nodeID,
            expectedRevision: expectedRevision,
            categoryIDs: categoryIDs,
            requestID: context.requestID,
            at: at
        )
    }

    private func requireManage(_ context: YouziMemoryAccessContext) throws {
        guard context.mayManageCandidates else {
            throw YouziMemoryRepositoryError.operationNotPermitted
        }
    }
}

/// Composition-neutral boundary used by a later idle scheduler. It accepts no
/// transcript text and delegates every durable decision to the same repository
/// that serves Memory MCP queries.
struct YouziMemoryBackgroundIngestionService: Sendable {
    private let queue: any YouziMemoryIdleIngestionService

    init(queue: any YouziMemoryIdleIngestionService) {
        self.queue = queue
    }

    func enqueueSettledConversation(
        _ request: YouziMemorySettledConversationRequest
    ) async throws -> YouziMemoryIngestionJob {
        try await queue.enqueueSettledConversation(request)
    }

    func segments(jobID: UUID) async throws -> [YouziMemoryIngestionSegmentReference] {
        try await queue.ingestionSegments(jobID: jobID)
    }
}
