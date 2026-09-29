import Foundation

// MARK: - Durable record vocabulary

enum YouziMemoryRepositoryError: Error, Equatable, LocalizedError, Sendable {
    case databaseUnavailable
    case unsupportedSchemaVersion(Int)
    case migrationFailed
    case integrityViolation
    case fullTextSearchUnavailable
    case invalidInput(YouziMemoryInputIssue)
    case recordNotFound
    case revisionConflict
    case duplicateRecord
    case sourceUnauthorized
    case sourceRevisionChanged
    case operationNotPermitted

    var errorDescription: String? {
        switch self {
        case .databaseUnavailable: "知我数据库暂时不可用。"
        case let .unsupportedSchemaVersion(version): "知我数据库版本不受支持（\(version)）。"
        case .migrationFailed: "知我数据库迁移失败。"
        case .integrityViolation: "知我数据库完整性检查失败。"
        case .fullTextSearchUnavailable: "本机全文检索能力不可用。"
        case .invalidInput: "知我请求包含无效或超出限制的内容。"
        case .recordNotFound: "未找到指定的知我记录。"
        case .revisionConflict: "知我记录已被其他操作更新。"
        case .duplicateRecord: "知我记录已存在。"
        case .sourceUnauthorized: "该记忆来源当前未获授权。"
        case .sourceRevisionChanged: "该记忆来源已经发生变化。"
        case .operationNotPermitted: "当前上下文不允许这个知我操作。"
        }
    }
}

enum YouziMemoryInputIssue: String, Equatable, Sendable {
    case emptyValue
    case valueTooLong
    case invalidConfidence
    case invalidRevision
    case invalidChecksum
    case invalidScope
    case invalidLease
    case invalidLimit
    case unsupportedFile
}

enum YouziMemorySourceKind: String, Codable, CaseIterable, Sendable {
    case chat
    case workspaceFile
    case projectFile
    case manualFile
    case connector
    case artifact
    case legacyMemory
}

enum YouziMemorySourceAuthorization: String, Codable, Sendable {
    case authorized
    case revoked
    case unavailable
    case deleted
}

enum YouziMemoryImportMode: String, Codable, Sendable {
    case managedCopy
    case securityScopedReference
}

enum YouziMemorySensitivity: String, Codable, CaseIterable, Sendable {
    case ordinary
    case personal
    case sensitive
    case sealed
}

enum YouziMemoryRecordState: String, Codable, Sendable {
    case proposed
    case awaitingConfirmation
    case confirmed
    case superseded
    case forgotten
}

enum YouziMemoryRecordKind: String, Codable, CaseIterable, Sendable {
    case user
    case person
    case organization
    case location
    case project
    case workspace
    case conversation
    case document
    case topic
    case preference
    case goal
    case habit
    case event
    case decision
    case file
    case artifact
}

enum YouziMemoryRelationKind: String, Codable, CaseIterable, Sendable {
    case knows
    case belongsTo
    case likes
    case avoids
    case responsibleFor
    case participatesIn
    case dependsOn
    case happenedAt
    case sourcedFrom
    case replaces
    case conflictsWith
}

enum YouziMemoryScopeKind: String, Codable, Sendable {
    case personal
    case project
    case workspace
}

struct YouziMemoryScopeRecord: Codable, Equatable, Hashable, Sendable {
    var kind: YouziMemoryScopeKind
    var identifier: UUID?

    static let personal = Self(kind: .personal, identifier: nil)

    static func project(_ id: UUID) -> Self { Self(kind: .project, identifier: id) }
    static func workspace(_ id: UUID) -> Self { Self(kind: .workspace, identifier: id) }

    var isValid: Bool {
        switch kind {
        case .personal: identifier == nil
        case .project, .workspace: identifier != nil
        }
    }
}

enum YouziMemoryLocatorKind: String, Codable, Sendable {
    case message
    case page
    case sheetRange
    case slide
    case heading
    case paragraph
    case block
    case object
    case legacy
}

/// A structured, bounded source locator. Display paths and excerpts are never
/// used as identity; `key` is stable only within the exact source revision.
struct YouziMemorySourceLocator: Codable, Equatable, Sendable {
    var kind: YouziMemoryLocatorKind
    var key: String
    var detail: String?
    var ordinal: Int?
}

struct YouziMemorySourceRecord: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var kind: YouziMemorySourceKind
    var externalIdentifier: String
    var revision: String
    var title: String
    var scope: YouziMemoryScopeRecord
    var taskID: UUID? = nil
    var workspaceID: UUID? = nil
    var projectID: UUID? = nil
    var permissionID: UUID?
    var importMode: YouziMemoryImportMode?
    var authorization: YouziMemorySourceAuthorization
    var contentChecksum: String?
    var importedAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    init(
        id: UUID,
        kind: YouziMemorySourceKind,
        externalIdentifier: String,
        revision: String,
        title: String,
        scope: YouziMemoryScopeRecord,
        taskID: UUID? = nil,
        workspaceID: UUID? = nil,
        projectID: UUID? = nil,
        permissionID: UUID?,
        importMode: YouziMemoryImportMode?,
        authorization: YouziMemorySourceAuthorization,
        contentChecksum: String?,
        importedAt: Date,
        updatedAt: Date,
        deletedAt: Date?
    ) {
        self.id = id
        self.kind = kind
        self.externalIdentifier = externalIdentifier
        self.revision = revision
        self.title = title
        self.scope = scope
        self.taskID = taskID
        self.workspaceID = workspaceID
        self.projectID = projectID
        self.permissionID = permissionID
        self.importMode = importMode
        self.authorization = authorization
        self.contentChecksum = contentChecksum
        self.importedAt = importedAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

struct YouziMemoryCitationRecord: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var sourceID: UUID
    var sourceRevision: String
    var locator: YouziMemorySourceLocator
    var sourceTimestamp: Date?
    var excerpt: String
    var contentChecksum: String
    var createdAt: Date
}

struct YouziMemoryNodeRecord: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var canonicalKey: String
    var label: String
    var content: String
    var kind: YouziMemoryRecordKind
    var confidence: Double
    var sensitivity: YouziMemorySensitivity
    var scope: YouziMemoryScopeRecord
    var state: YouziMemoryRecordState
    var revision: Int
    var validFrom: Date?
    var validUntil: Date?
    var createdAt: Date
    var updatedAt: Date
    var lastConfirmedAt: Date?
    var deletedAt: Date?
    var mergedIntoID: UUID?
}

struct YouziMemoryEdgeRecord: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var sourceNodeID: UUID
    var targetNodeID: UUID
    var relation: YouziMemoryRelationKind
    var explanation: String
    var confidence: Double
    var sensitivity: YouziMemorySensitivity
    var scope: YouziMemoryScopeRecord
    var state: YouziMemoryRecordState
    var revision: Int
    var validFrom: Date?
    var validUntil: Date?
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
}

struct YouziMemoryCategoryRecord: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var isSystem: Bool
    var isHidden: Bool
    var sortOrder: Int
    var createdAt: Date
    var updatedAt: Date
}

struct YouziMemoryNodeCandidate: Codable, Equatable, Sendable {
    let id: UUID
    var canonicalKey: String
    var label: String
    var content: String
    var kind: YouziMemoryRecordKind
    var confidence: Double
    var sensitivity: YouziMemorySensitivity
    var scope: YouziMemoryScopeRecord
    var validFrom: Date?
    var validUntil: Date?
    var citationIDs: [UUID]
    var categoryIDs: [UUID]
}

struct YouziMemoryEdgeCandidate: Codable, Equatable, Sendable {
    let id: UUID
    var sourceNodeID: UUID
    var targetNodeID: UUID
    var relation: YouziMemoryRelationKind
    var explanation: String
    var confidence: Double
    var sensitivity: YouziMemorySensitivity
    var scope: YouziMemoryScopeRecord
    var validFrom: Date?
    var validUntil: Date?
    var citationIDs: [UUID]
}

struct YouziMemoryCandidateBatch: Codable, Equatable, Sendable {
    var idempotencyKey: String
    var sourceID: UUID
    var sourceRevision: String
    var policyVersion: String
    var nodes: [YouziMemoryNodeCandidate]
    var edges: [YouziMemoryEdgeCandidate]
    var submittedAt: Date
}

struct YouziMemoryProposalResult: Codable, Equatable, Sendable {
    var nodeIDs: [UUID]
    var edgeIDs: [UUID]
    var wasReplay: Bool
}

struct YouziMemorySearchHit: Codable, Equatable, Sendable {
    var node: YouziMemoryNodeRecord
    var rank: Double
    var citationIDs: [UUID]
}

struct YouziMemoryWorkbenchSnapshot: Codable, Equatable, Sendable {
    var nodes: [YouziMemoryNodeRecord]
    var edges: [YouziMemoryEdgeRecord]
    var categories: [YouziMemoryCategoryRecord]
    var nodeCategoryIDs: [UUID: [UUID]]
    var citationCountByNodeID: [UUID: Int]
    var hasMoreNodes: Bool
}

struct YouziMemoryAccessContext: Equatable, Sendable {
    var requestID: UUID
    var allowedScopes: Set<YouziMemoryScopeRecord>
    var mayReadSensitive: Bool
    var mayPropose: Bool
    var mayManageCandidates: Bool
    var maximumResults: Int

    init(
        requestID: UUID,
        allowedScopes: Set<YouziMemoryScopeRecord> = [.personal],
        mayReadSensitive: Bool = false,
        mayPropose: Bool = false,
        mayManageCandidates: Bool = false,
        maximumResults: Int = 20
    ) {
        self.requestID = requestID
        self.allowedScopes = allowedScopes
        self.mayReadSensitive = mayReadSensitive
        self.mayPropose = mayPropose
        self.mayManageCandidates = mayManageCandidates
        self.maximumResults = maximumResults
    }
}

enum YouziMemoryIngestionJobState: String, Codable, Sendable {
    case queued
    case running
    case retryScheduled
    case completed
    case failed
    case cancelled
}

struct YouziMemoryIngestionJob: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var sourceID: UUID
    var sourceRevision: String
    var extractorVersion: String
    var policyVersion: String
    var priority: Int
    var state: YouziMemoryIngestionJobState
    var attemptCount: Int
    var nextAttemptAt: Date?
    var leaseOwner: String?
    var leaseExpiresAt: Date?
    var recoveryCode: String?
    var createdAt: Date
    var updatedAt: Date
}

struct YouziMemoryFileImportRequest: Equatable, Sendable {
    var sourceID: UUID
    var fileID: UUID
    var displayName: String
    var uniformTypeIdentifier: String
    var byteCount: Int64
    var sha256: String
    var mode: YouziMemoryImportMode
    var scope: YouziMemoryScopeRecord
    var permissionID: UUID
    var categoryIDs: [UUID] = []
    var importedAt: Date
    var extractorVersion: String
    var policyVersion: String

    init(
        sourceID: UUID,
        fileID: UUID,
        displayName: String,
        uniformTypeIdentifier: String,
        byteCount: Int64,
        sha256: String,
        mode: YouziMemoryImportMode,
        scope: YouziMemoryScopeRecord,
        permissionID: UUID,
        categoryIDs: [UUID] = [],
        importedAt: Date,
        extractorVersion: String,
        policyVersion: String
    ) {
        self.sourceID = sourceID
        self.fileID = fileID
        self.displayName = displayName
        self.uniformTypeIdentifier = uniformTypeIdentifier
        self.byteCount = byteCount
        self.sha256 = sha256
        self.mode = mode
        self.scope = scope
        self.permissionID = permissionID
        self.categoryIDs = categoryIDs
        self.importedAt = importedAt
        self.extractorVersion = extractorVersion
        self.policyVersion = policyVersion
    }
}

enum YouziMemoryConversationCapturePolicy: String, Codable, Sendable {
    case allowed
    case doNotRemember
    case privateSession
}

struct YouziMemoryIngestionSegmentReference: Codable, Equatable, Sendable {
    var id: UUID
    var checksum: String
    var ordinal: Int
}

/// Stable metadata snapshot for the later idle analyzer. It intentionally has
/// no message text; the analyzer resolves authorized messages by ID and writes
/// only bounded evidence segments through the citation API.
struct YouziMemorySettledConversationRequest: Equatable, Sendable {
    var sourceID: UUID
    var conversationID: UUID
    var sourceRevision: String
    var title: String
    var taskID: UUID?
    var workspaceID: UUID?
    var projectID: UUID?
    var capturePolicy: YouziMemoryConversationCapturePolicy
    var segments: [YouziMemoryIngestionSegmentReference]
    var settledAt: Date
    var extractorVersion: String
    var policyVersion: String
}

struct YouziMemoryFileImportReceipt: Equatable, Sendable {
    var sourceID: UUID
    var jobID: UUID
    var wasAlreadyImported: Bool
}

/// Metadata-only admission for later chat/file idle analyzers. The source text
/// itself is deliberately absent: parsing writes bounded citation segments
/// through `addCitation`, never an unbounded payload through the queue.
struct YouziMemoryIngestionAdmission: Equatable, Sendable {
    var source: YouziMemorySourceRecord
    var extractorVersion: String
    var policyVersion: String
    var priority: Int
    var captureAllowed: Bool
    var admittedAt: Date
}

struct YouziMemoryMigrationResult: Equatable, Sendable {
    var importedNodes: Int
    var importedEdges: Int
    var importedCitations: Int
    var importedLegacyEntries: Int
    var wasAlreadyApplied: Bool
}

// MARK: - Built-in service contract

enum YouziMemoryMCPMethod: String, CaseIterable, Sendable {
    case search = "memory.search"
    case queryNodes = "memory.query_nodes"
    case queryRelations = "memory.query_relations"
    case queryCitations = "memory.query_citations"
    case propose = "memory.propose"
    case merge = "memory.merge"
    case undoMerge = "memory.undo_merge"
    case revoke = "memory.revoke"
    case forget = "memory.forget"
    case importFile = "memory.import_file"
    case listCategories = "memory.list_categories"
    case classifySource = "memory.classify_source"
    case classifyNode = "memory.classify_node"

    var wireAlias: String { rawValue.replacingOccurrences(of: ".", with: "_") }
}

protocol YouziMemoryIngestionQueue: Sendable {
    func enqueue(
        sourceID: UUID,
        sourceRevision: String,
        extractorVersion: String,
        policyVersion: String,
        priority: Int,
        at: Date
    ) async throws -> YouziMemoryIngestionJob

    func claimNext(
        workerID: String,
        leaseDuration: TimeInterval,
        at: Date
    ) async throws -> YouziMemoryIngestionJob?

    func settle(
        jobID: UUID,
        workerID: String,
        outcome: YouziMemoryIngestionJobState,
        recoveryCode: String?,
        retryAt: Date?,
        at: Date
    ) async throws -> YouziMemoryIngestionJob
}

protocol YouziMemoryIdleIngestionService: Sendable {
    func admit(_ admission: YouziMemoryIngestionAdmission) async throws -> YouziMemoryIngestionJob
    func enqueueSettledConversation(
        _ request: YouziMemorySettledConversationRequest
    ) async throws -> YouziMemoryIngestionJob
    func ingestionSegments(
        jobID: UUID
    ) async throws -> [YouziMemoryIngestionSegmentReference]
}
