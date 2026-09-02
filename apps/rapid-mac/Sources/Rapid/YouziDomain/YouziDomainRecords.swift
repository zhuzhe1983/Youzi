import Foundation

// MARK: - Shared values

enum YouziRecordState: String, Codable, Equatable, Sendable {
    case active
    case disabled
    case unavailable
    case archived
}

enum YouziManifestSourceKind: String, Codable, Equatable, Sendable {
    case builtIn
    case userCreated
    case localPackage
    case managedCatalog
}

struct YouziManifestSource: Codable, Equatable, Sendable {
    var kind: YouziManifestSourceKind
    /// Stable source-owned identifier, not a display name or filesystem path.
    var identifier: String
    /// Source package/manifest version, present even for built-in content.
    var version: String
}

enum YouziPermissionKind: String, Codable, Equatable, Sendable {
    case workspaceRead
    case workspaceWrite
    case networkAccess
    case connectorRead
    case connectorWrite
    case externalPublish
    case destructiveLocalAction
    case microphone
    case saveAudio
}

enum YouziPermissionDuration: String, Codable, Equatable, Sendable {
    case once
    case task
    case persistent
}

enum YouziPermissionDecision: String, Codable, Equatable, Sendable {
    case pending
    case allowed
    case denied
    case revoked
}

struct YouziPermissionRecord: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var taskID: UUID?
    var kind: YouziPermissionKind
    /// Connector, workspace, file, or action identifier the decision covers.
    var targetIdentifier: String
    var purpose: String
    var duration: YouziPermissionDuration
    var decision: YouziPermissionDecision
    let requestedAt: Date
    var decidedAt: Date?

    init(
        id: UUID = UUID(),
        taskID: UUID? = nil,
        kind: YouziPermissionKind,
        targetIdentifier: String,
        purpose: String,
        duration: YouziPermissionDuration = .once,
        decision: YouziPermissionDecision = .pending,
        requestedAt: Date = Date(),
        decidedAt: Date? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.kind = kind
        self.targetIdentifier = targetIdentifier
        self.purpose = purpose
        self.duration = duration
        self.decision = decision
        self.requestedAt = requestedAt
        self.decidedAt = decidedAt
    }
}

// MARK: - Tasks, workspaces, and projects

enum YouziTaskStatus: String, Codable, Equatable, Sendable {
    case draft
    case inProgress
    case awaitingConfirmation
    case completed
    case failed
    case archived
}

struct YouziTask: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var title: String
    var request: String
    /// Existing chat history remains the source of truth for messages.
    var conversationID: UUID?
    var workspaceID: UUID?
    var projectID: UUID?
    var helperID: UUID?
    var skillIDs: [UUID]
    var connectionAccountIDs: [UUID]
    var permissionRecordIDs: [UUID]
    /// Stable identities of imported inputs; bytes and access grants live on
    /// the corresponding ``YouziFile`` records.
    var inputFileIDs: [UUID]
    var artifactIDs: [UUID]
    var status: YouziTaskStatus
    var failureSummary: String?
    var isPinned: Bool
    let createdAt: Date
    var updatedAt: Date
    var completedAt: Date?

    init(
        id: UUID = UUID(),
        title: String,
        request: String,
        conversationID: UUID? = nil,
        workspaceID: UUID? = nil,
        projectID: UUID? = nil,
        helperID: UUID? = nil,
        skillIDs: [UUID] = [],
        connectionAccountIDs: [UUID] = [],
        permissionRecordIDs: [UUID] = [],
        inputFileIDs: [UUID] = [],
        artifactIDs: [UUID] = [],
        status: YouziTaskStatus = .draft,
        failureSummary: String? = nil,
        isPinned: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.request = request
        self.conversationID = conversationID
        self.workspaceID = workspaceID
        self.projectID = projectID
        self.helperID = helperID
        self.skillIDs = skillIDs
        self.connectionAccountIDs = connectionAccountIDs
        self.permissionRecordIDs = permissionRecordIDs
        self.inputFileIDs = inputFileIDs
        self.artifactIDs = artifactIDs
        self.status = status
        self.failureSummary = failureSummary
        self.isPinned = isPinned
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
    }
}

/// A durable workspace location. User-selected folders persist their sandbox
/// grant; app-managed folders use a relative path below Youzi's managed root.
enum YouziWorkspaceLocation: Codable, Equatable, Sendable {
    case managed(relativePath: String)
    case securityScopedBookmark(data: Data, displayPath: String)
}

struct YouziWorkspace: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var location: YouziWorkspaceLocation
    var state: YouziRecordState
    let createdAt: Date
    var updatedAt: Date
    var lastAccessedAt: Date?

    init(
        id: UUID = UUID(),
        name: String,
        location: YouziWorkspaceLocation,
        state: YouziRecordState = .active,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastAccessedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.location = location
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastAccessedAt = lastAccessedAt
    }
}

struct YouziProject: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var summary: String
    var instructions: String
    var preferences: [String: String]
    var defaultHelperIDs: [UUID]
    var defaultSkillIDs: [UUID]
    var defaultConnectionAccountIDs: [UUID]
    /// Files explicitly attached to the continuing project. A project never
    /// takes ownership of conversation folders or arbitrary exports.
    var resourceFileIDs: [UUID]
    var state: YouziRecordState
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        summary: String = "",
        instructions: String = "",
        preferences: [String: String] = [:],
        defaultHelperIDs: [UUID] = [],
        defaultSkillIDs: [UUID] = [],
        defaultConnectionAccountIDs: [UUID] = [],
        resourceFileIDs: [UUID] = [],
        state: YouziRecordState = .active,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.instructions = instructions
        self.preferences = preferences
        self.defaultHelperIDs = defaultHelperIDs
        self.defaultSkillIDs = defaultSkillIDs
        self.defaultConnectionAccountIDs = defaultConnectionAccountIDs
        self.resourceFileIDs = resourceFileIDs
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Helpers, skills, and connectors

struct YouziHelper: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var summary: String
    var systemInstructions: String
    var methodology: [String]
    var recommendedSkillIDs: [UUID]
    var allowedConnectorIDs: [UUID]
    var preferredOutputTypes: [String]
    var source: YouziManifestSource
    var state: YouziRecordState
    var isFavorite: Bool
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        summary: String,
        systemInstructions: String,
        methodology: [String] = [],
        recommendedSkillIDs: [UUID] = [],
        allowedConnectorIDs: [UUID] = [],
        preferredOutputTypes: [String] = [],
        source: YouziManifestSource,
        state: YouziRecordState = .active,
        isFavorite: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.systemInstructions = systemInstructions
        self.methodology = methodology
        self.recommendedSkillIDs = recommendedSkillIDs
        self.allowedConnectorIDs = allowedConnectorIDs
        self.preferredOutputTypes = preferredOutputTypes
        self.source = source
        self.state = state
        self.isFavorite = isFavorite
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

enum YouziSkillExecutionLocation: String, Codable, Equatable, Sendable {
    case local
    case network
    case hybrid
}

struct YouziSkill: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var summary: String
    var packageVersion: String
    var entrypoint: String
    var resourcePaths: [String]
    var executionLocation: YouziSkillExecutionLocation
    var requestedPermissions: [YouziPermissionKind]
    var connectorDependencyIDs: [UUID]
    var requiresFirstUseConfirmation: Bool
    var source: YouziManifestSource
    var state: YouziRecordState
    var lastUsedAt: Date?
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        summary: String,
        packageVersion: String,
        entrypoint: String = "SKILL.md",
        resourcePaths: [String] = [],
        executionLocation: YouziSkillExecutionLocation = .local,
        requestedPermissions: [YouziPermissionKind] = [],
        connectorDependencyIDs: [UUID] = [],
        requiresFirstUseConfirmation: Bool = false,
        source: YouziManifestSource,
        state: YouziRecordState = .active,
        lastUsedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.packageVersion = packageVersion
        self.entrypoint = entrypoint
        self.resourcePaths = resourcePaths
        self.executionLocation = executionLocation
        self.requestedPermissions = requestedPermissions
        self.connectorDependencyIDs = connectorDependencyIDs
        self.requiresFirstUseConfirmation = requiresFirstUseConfirmation
        self.source = source
        self.state = state
        self.lastUsedAt = lastUsedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

enum YouziConnectorAdapter: String, Codable, Equatable, Sendable {
    case mcp
    case commandLine
    case native
    case skillBacked
}

enum YouziConnectorAuthentication: String, Codable, Equatable, Sendable {
    case none
    case oauth
    case apiKey
    case localSession
    case custom
}

struct YouziConnector: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var summary: String
    var adapter: YouziConnectorAdapter
    var authentication: YouziConnectorAuthentication
    var declaredScopes: [String]
    var toolNames: [String]
    var source: YouziManifestSource
    var state: YouziRecordState
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        summary: String,
        adapter: YouziConnectorAdapter,
        authentication: YouziConnectorAuthentication,
        declaredScopes: [String] = [],
        toolNames: [String] = [],
        source: YouziManifestSource,
        state: YouziRecordState = .active,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.adapter = adapter
        self.authentication = authentication
        self.declaredScopes = declaredScopes
        self.toolNames = toolNames
        self.source = source
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

enum YouziConnectionState: String, Codable, Equatable, Sendable {
    case notConnected
    case connecting
    case connected
    case needsAttention
    case disabled
}

struct YouziConnectionAccount: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var connectorID: UUID
    var displayName: String
    /// Opaque key for credentials held outside this JSON document.
    var credentialReference: String?
    var grantedScopes: [String]
    var state: YouziConnectionState
    var lastCheckedAt: Date?
    var lastErrorSummary: String?
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        connectorID: UUID,
        displayName: String,
        credentialReference: String? = nil,
        grantedScopes: [String] = [],
        state: YouziConnectionState = .notConnected,
        lastCheckedAt: Date? = nil,
        lastErrorSummary: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.connectorID = connectorID
        self.displayName = displayName
        self.credentialReference = credentialReference
        self.grantedScopes = grantedScopes
        self.state = state
        self.lastCheckedAt = lastCheckedAt
        self.lastErrorSummary = lastErrorSummary
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Artifacts and templates

enum YouziArtifactKind: String, Codable, Equatable, Sendable {
    case document
    case spreadsheet
    case image
    case audio
    case video
    case code
    case archive
    case other
}

struct YouziArtifact: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var taskID: UUID
    var projectID: UUID?
    var title: String
    var kind: YouziArtifactKind
    var previewText: String?
    /// The one authoritative file backing this deliverable. Exported copies
    /// are intentionally not tracked as additional artifact ownership.
    var fileID: UUID
    var state: YouziRecordState
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        taskID: UUID,
        projectID: UUID? = nil,
        title: String,
        kind: YouziArtifactKind,
        previewText: String? = nil,
        fileID: UUID,
        state: YouziRecordState = .active,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.taskID = taskID
        self.projectID = projectID
        self.title = title
        self.kind = kind
        self.previewText = previewText
        self.fileID = fileID
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct YouziTemplate: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var category: String
    var summary: String
    var samplePreview: String?
    var prefilledRequest: String
    var recommendedHelperID: UUID?
    var recommendedSkillIDs: [UUID]
    var recommendedConnectorIDs: [UUID]
    var requiredInputs: [String]
    var source: YouziManifestSource
    var state: YouziRecordState
    var isFavorite: Bool
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        category: String,
        summary: String,
        samplePreview: String? = nil,
        prefilledRequest: String,
        recommendedHelperID: UUID? = nil,
        recommendedSkillIDs: [UUID] = [],
        recommendedConnectorIDs: [UUID] = [],
        requiredInputs: [String] = [],
        source: YouziManifestSource,
        state: YouziRecordState = .active,
        isFavorite: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.summary = summary
        self.samplePreview = samplePreview
        self.prefilledRequest = prefilledRequest
        self.recommendedHelperID = recommendedHelperID
        self.recommendedSkillIDs = recommendedSkillIDs
        self.recommendedConnectorIDs = recommendedConnectorIDs
        self.requiredInputs = requiredInputs
        self.source = source
        self.state = state
        self.isFavorite = isFavorite
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Automations

enum YouziAutomationTrigger: Codable, Equatable, Sendable {
    case manual
    case interval(seconds: TimeInterval)
    case schedule(cronExpression: String, timeZoneIdentifier: String)
}

struct YouziAutomationAction: Codable, Equatable, Sendable {
    var request: String
    var projectID: UUID?
    var workspaceID: UUID?
    var helperID: UUID?
    var skillIDs: [UUID]
    var connectionAccountIDs: [UUID]
}

enum YouziAutomationState: String, Codable, Equatable, Sendable {
    case active
    case paused
    case needsAttention
    case archived
}

struct YouziAutomation: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    /// Incremented when trigger, action, or long-term permission scope changes.
    var revision: Int
    var trigger: YouziAutomationTrigger
    var action: YouziAutomationAction
    var permissionRecordIDs: [UUID]
    var notificationEnabled: Bool
    var state: YouziAutomationState
    var nextRunAt: Date?
    var lastRunAt: Date?
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        revision: Int = 1,
        trigger: YouziAutomationTrigger,
        action: YouziAutomationAction,
        permissionRecordIDs: [UUID] = [],
        notificationEnabled: Bool = true,
        state: YouziAutomationState = .active,
        nextRunAt: Date? = nil,
        lastRunAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.revision = revision
        self.trigger = trigger
        self.action = action
        self.permissionRecordIDs = permissionRecordIDs
        self.notificationEnabled = notificationEnabled
        self.state = state
        self.nextRunAt = nextRunAt
        self.lastRunAt = lastRunAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

enum YouziAutomationRunStatus: String, Codable, Equatable, Sendable {
    case running
    case awaitingConfirmation
    case completed
    case failed
    case cancelled
}

struct YouziAutomationRun: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var automationID: UUID
    var taskID: UUID?
    var status: YouziAutomationRunStatus
    var summary: String?
    let startedAt: Date
    var finishedAt: Date?

    init(
        id: UUID = UUID(),
        automationID: UUID,
        taskID: UUID? = nil,
        status: YouziAutomationRunStatus = .running,
        summary: String? = nil,
        startedAt: Date = Date(),
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.automationID = automationID
        self.taskID = taskID
        self.status = status
        self.summary = summary
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}

// MARK: - Memory graph

enum YouziMemoryScope: Codable, Equatable, Sendable {
    case personal
    case project(UUID)
    case workspace(UUID)
    case sensitiveSealed
}

enum YouziMemoryNodeKind: String, Codable, Equatable, Sendable {
    case user
    case person
    case organization
    case location
    case project
    case topic
    case preference
    case goal
    case habit
    case event
    case file
    case artifact
}

enum YouziMemoryCreationMethod: String, Codable, Equatable, Sendable {
    case extracted
    case manual
    case imported
    case userConfirmed
}

enum YouziMemoryState: String, Codable, Equatable, Sendable {
    case proposed
    case awaitingConfirmation
    case confirmed
    case superseded
    case forgotten
}

struct YouziMemoryNode: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var label: String
    var content: String
    var kind: YouziMemoryNodeKind
    var confidence: Double
    var scope: YouziMemoryScope
    var citationIDs: [UUID]
    var creationMethod: YouziMemoryCreationMethod
    var state: YouziMemoryState
    var validFrom: Date?
    var validUntil: Date?
    let createdAt: Date
    var updatedAt: Date
    var lastConfirmedAt: Date?

    init(
        id: UUID = UUID(),
        label: String,
        content: String,
        kind: YouziMemoryNodeKind,
        confidence: Double,
        scope: YouziMemoryScope,
        citationIDs: [UUID] = [],
        creationMethod: YouziMemoryCreationMethod,
        state: YouziMemoryState = .proposed,
        validFrom: Date? = nil,
        validUntil: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastConfirmedAt: Date? = nil
    ) {
        self.id = id
        self.label = label
        self.content = content
        self.kind = kind
        self.confidence = confidence
        self.scope = scope
        self.citationIDs = citationIDs
        self.creationMethod = creationMethod
        self.state = state
        self.validFrom = validFrom
        self.validUntil = validUntil
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastConfirmedAt = lastConfirmedAt
    }
}

enum YouziMemoryRelation: String, Codable, Equatable, Sendable {
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

struct YouziMemoryEdge: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var sourceNodeID: UUID
    var targetNodeID: UUID
    var relation: YouziMemoryRelation
    var explanation: String
    var confidence: Double
    var scope: YouziMemoryScope
    var citationIDs: [UUID]
    var state: YouziMemoryState
    var validFrom: Date?
    var validUntil: Date?
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        sourceNodeID: UUID,
        targetNodeID: UUID,
        relation: YouziMemoryRelation,
        explanation: String,
        confidence: Double,
        scope: YouziMemoryScope,
        citationIDs: [UUID] = [],
        state: YouziMemoryState = .proposed,
        validFrom: Date? = nil,
        validUntil: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.sourceNodeID = sourceNodeID
        self.targetNodeID = targetNodeID
        self.relation = relation
        self.explanation = explanation
        self.confidence = confidence
        self.scope = scope
        self.citationIDs = citationIDs
        self.state = state
        self.validFrom = validFrom
        self.validUntil = validUntil
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

enum YouziCitationSourceType: String, Codable, Equatable, Sendable {
    case chat
    case workspaceFile
    case projectFile
    case manualImport
    case connector
    case artifact
}

enum YouziCitationAuthorizationState: String, Codable, Equatable, Sendable {
    case authorized
    case revoked
    case sourceUnavailable
    case deleted
}

struct YouziMemoryCitation: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var sourceType: YouziCitationSourceType
    /// Source-owned stable identifier: message, file, or connector object ID.
    var sourceID: String
    var scopeID: UUID?
    var title: String
    /// Message ID, relative path plus section, page, sheet, slide, or object URL.
    var stableLocator: String
    var sourceTimestamp: Date?
    var excerpt: String
    var contentChecksum: String
    var authorizationState: YouziCitationAuthorizationState
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        sourceType: YouziCitationSourceType,
        sourceID: String,
        scopeID: UUID? = nil,
        title: String,
        stableLocator: String,
        sourceTimestamp: Date? = nil,
        excerpt: String,
        contentChecksum: String,
        authorizationState: YouziCitationAuthorizationState = .authorized,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.sourceType = sourceType
        self.sourceID = sourceID
        self.scopeID = scopeID
        self.title = title
        self.stableLocator = stableLocator
        self.sourceTimestamp = sourceTimestamp
        self.excerpt = excerpt
        self.contentChecksum = contentChecksum
        self.authorizationState = authorizationState
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Realtime voice sessions

enum YouziVoiceDimension: String, Codable, Equatable, Sendable {
    case global
    case helper
}

enum YouziVoiceSessionState: String, Codable, Equatable, Sendable {
    case notStarted
    case listening
    case transcribing
    case thinking
    case executing
    case speaking
    case awaitingConfirmation
    case muted
    case recoverableError
    case ended
}

struct YouziVoiceSession: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var dimension: YouziVoiceDimension
    var taskID: UUID?
    var conversationID: UUID?
    var helperID: UUID?
    /// IDs of final messages in the shared conversation store; no transcript copy.
    var transcriptMessageIDs: [UUID]
    var permissionRecordIDs: [UUID]
    var state: YouziVoiceSessionState
    var localeIdentifier: String
    var inputDeviceID: String?
    var outputDeviceID: String?
    var audioWasPersisted: Bool
    let startedAt: Date
    var endedAt: Date?
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        dimension: YouziVoiceDimension,
        taskID: UUID? = nil,
        conversationID: UUID? = nil,
        helperID: UUID? = nil,
        transcriptMessageIDs: [UUID] = [],
        permissionRecordIDs: [UUID] = [],
        state: YouziVoiceSessionState = .notStarted,
        localeIdentifier: String,
        inputDeviceID: String? = nil,
        outputDeviceID: String? = nil,
        audioWasPersisted: Bool = false,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.dimension = dimension
        self.taskID = taskID
        self.conversationID = conversationID
        self.helperID = helperID
        self.transcriptMessageIDs = transcriptMessageIDs
        self.permissionRecordIDs = permissionRecordIDs
        self.state = state
        self.localeIdentifier = localeIdentifier
        self.inputDeviceID = inputDeviceID
        self.outputDeviceID = outputDeviceID
        self.audioWasPersisted = audioWasPersisted
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.updatedAt = updatedAt
    }
}
