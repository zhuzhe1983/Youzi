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

    private enum CodingKeys: String, CodingKey { case kind, identifier, version }
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

/// Stable, non-sensitive recovery categories. Persist codes rather than raw
/// runtime errors so domain JSON and audit records cannot accidentally capture
/// credentials, command lines, paths, or response bodies.
enum YouziRecoveryCode: String, Codable, Equatable, Sendable {
    case packageMissing
    case packageInvalid
    case bookmarkStale
    case dependencyMissing
    case credentialMissing
    case credentialCleanupPending
    case connectorUnconfigured
    case connectorUnavailable
    case permissionRequired
    case grantRevoked
    case automationRevisionChanged
    case scheduleInvalid
    case retryExhausted
    case notificationUnavailable
    case runtimeUnavailable
}

struct YouziPermissionRecord: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var taskID: UUID?
    /// Automation permission requests are scoped to one immutable definition
    /// revision. These fields appear together and never alongside `taskID`.
    var automationID: UUID?
    var automationRevision: Int?
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
        automationID: UUID? = nil,
        automationRevision: Int? = nil,
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
        self.automationID = automationID
        self.automationRevision = automationRevision
        self.kind = kind
        self.targetIdentifier = targetIdentifier
        self.purpose = purpose
        self.duration = duration
        self.decision = decision
        self.requestedAt = requestedAt
        self.decidedAt = decidedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, taskID, automationID, automationRevision, kind, targetIdentifier
        case purpose, duration, decision, requestedAt, decidedAt
    }
}

/// Authority issued from an allowed permission request. A request/decision is
/// history; only a live, matching grant can authorize execution.
struct YouziPermissionGrant: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let permissionRecordID: UUID
    let taskID: UUID?
    let automationID: UUID?
    let automationRevision: Int?
    let kind: YouziPermissionKind
    let targetIdentifier: String
    let targetRevision: Int?
    let duration: YouziPermissionDuration
    let grantedAt: Date
    var expiresAt: Date?
    var consumedAt: Date?
    var revokedAt: Date?

    init(
        id: UUID = UUID(),
        permissionRecordID: UUID,
        taskID: UUID? = nil,
        automationID: UUID? = nil,
        automationRevision: Int? = nil,
        kind: YouziPermissionKind,
        targetIdentifier: String,
        targetRevision: Int? = nil,
        duration: YouziPermissionDuration,
        grantedAt: Date = Date(),
        expiresAt: Date? = nil,
        consumedAt: Date? = nil,
        revokedAt: Date? = nil
    ) {
        self.id = id
        self.permissionRecordID = permissionRecordID
        self.taskID = taskID
        self.automationID = automationID
        self.automationRevision = automationRevision
        self.kind = kind
        self.targetIdentifier = targetIdentifier
        self.targetRevision = targetRevision
        self.duration = duration
        self.grantedAt = grantedAt
        self.expiresAt = expiresAt
        self.consumedAt = consumedAt
        self.revokedAt = revokedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, permissionRecordID, taskID, automationID, automationRevision
        case kind, targetIdentifier, targetRevision, duration, grantedAt
        case expiresAt, consumedAt, revokedAt
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

/// Persists whether an empty task capability selection inherits its active
/// project's defaults or represents an intentional, explicitly empty choice.
enum YouziTaskSelectionIntent: String, Codable, Equatable, Sendable {
    case inheritProjectDefaults
    case explicit
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
    var helperSelectionIntent: YouziTaskSelectionIntent
    var skillIDs: [UUID]
    var skillSelectionIntent: YouziTaskSelectionIntent
    var connectionAccountIDs: [UUID]
    var connectionAccountSelectionIntent: YouziTaskSelectionIntent
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
        helperSelectionIntent: YouziTaskSelectionIntent = .inheritProjectDefaults,
        skillIDs: [UUID] = [],
        skillSelectionIntent: YouziTaskSelectionIntent = .inheritProjectDefaults,
        connectionAccountIDs: [UUID] = [],
        connectionAccountSelectionIntent: YouziTaskSelectionIntent = .inheritProjectDefaults,
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
        self.helperSelectionIntent = helperSelectionIntent
        self.skillIDs = skillIDs
        self.skillSelectionIntent = skillSelectionIntent
        self.connectionAccountIDs = connectionAccountIDs
        self.connectionAccountSelectionIntent = connectionAccountSelectionIntent
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

    private enum CodingKeys: String, CodingKey {
        case id, title, request, conversationID, workspaceID, projectID, helperID
        case helperSelectionIntent, skillIDs, skillSelectionIntent, connectionAccountIDs
        case connectionAccountSelectionIntent, permissionRecordIDs, inputFileIDs
        case artifactIDs, status, failureSummary, isPinned, createdAt, updatedAt, completedAt
    }
}

/// A durable workspace location. User-selected folders persist their sandbox
/// grant; app-managed folders use a relative path below Youzi's managed root.
enum YouziWorkspaceLocation: Codable, Equatable, Sendable {
    case managed(relativePath: String)
    case securityScopedBookmark(data: Data, displayPath: String)

    private enum CodingKeys: String, CodingKey { case kind, relativePath, data, displayPath }
    private enum Kind: String, Codable { case managed, securityScopedBookmark }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .managed:
            self = .managed(relativePath: try container.decode(String.self, forKey: .relativePath))
        case .securityScopedBookmark:
            self = .securityScopedBookmark(
                data: try container.decode(Data.self, forKey: .data),
                displayPath: try container.decode(String.self, forKey: .displayPath)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .managed(relativePath):
            try container.encode(Kind.managed, forKey: .kind)
            try container.encode(relativePath, forKey: .relativePath)
        case let .securityScopedBookmark(data, displayPath):
            try container.encode(Kind.securityScopedBookmark, forKey: .kind)
            try container.encode(data, forKey: .data)
            try container.encode(displayPath, forKey: .displayPath)
        }
    }
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

    private enum CodingKeys: String, CodingKey {
        case id, name, location, state, createdAt, updatedAt, lastAccessedAt
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

    private enum CodingKeys: String, CodingKey {
        case id, name, summary, instructions, preferences, defaultHelperIDs
        case defaultSkillIDs, defaultConnectionAccountIDs, resourceFileIDs
        case state, createdAt, updatedAt
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

    private enum CodingKeys: String, CodingKey {
        case id, name, summary, systemInstructions, methodology, recommendedSkillIDs
        case allowedConnectorIDs, preferredOutputTypes, source, state, isFavorite
        case createdAt, updatedAt
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

    private enum CodingKeys: String, CodingKey {
        case id, name, summary, packageVersion, entrypoint, resourcePaths
        case executionLocation, requestedPermissions, connectorDependencyIDs
        case requiresFirstUseConfirmation, source, state, lastUsedAt, createdAt, updatedAt
    }
}

/// Durable authority for locating an installed declarative skill package.
/// Filesystem paths are never stored in manifest source identifiers.
enum YouziSkillPackageLocation: Codable, Equatable, Sendable {
    case bundled(resourcePath: String)
    case appManaged(relativePath: String)
    case securityScopedBookmark(data: Data, displayPath: String)

    private enum CodingKeys: String, CodingKey {
        case kind, resourcePath, relativePath, data, displayPath
    }

    private enum Kind: String, Codable { case bundled, appManaged, securityScopedBookmark }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .bundled:
            self = .bundled(resourcePath: try container.decode(String.self, forKey: .resourcePath))
        case .appManaged:
            self = .appManaged(relativePath: try container.decode(String.self, forKey: .relativePath))
        case .securityScopedBookmark:
            self = .securityScopedBookmark(
                data: try container.decode(Data.self, forKey: .data),
                displayPath: try container.decode(String.self, forKey: .displayPath)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .bundled(resourcePath):
            try container.encode(Kind.bundled, forKey: .kind)
            try container.encode(resourcePath, forKey: .resourcePath)
        case let .appManaged(relativePath):
            try container.encode(Kind.appManaged, forKey: .kind)
            try container.encode(relativePath, forKey: .relativePath)
        case let .securityScopedBookmark(data, displayPath):
            try container.encode(Kind.securityScopedBookmark, forKey: .kind)
            try container.encode(data, forKey: .data)
            try container.encode(displayPath, forKey: .displayPath)
        }
    }
}

struct YouziSkillPackageRecord: Identifiable, Codable, Equatable, Sendable {
    /// The package record deliberately shares the skill UUID. Cross-collection
    /// UUID reuse is valid; uniqueness is enforced within each collection.
    let id: UUID
    var location: YouziSkillPackageLocation
    var packageVersion: String
    var contentSHA256: String
    var recoveryCode: YouziRecoveryCode?
    let installedAt: Date
    var verifiedAt: Date?
    var updatedAt: Date

    init(
        id: UUID,
        location: YouziSkillPackageLocation,
        packageVersion: String,
        contentSHA256: String,
        recoveryCode: YouziRecoveryCode? = nil,
        installedAt: Date = Date(),
        verifiedAt: Date? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.location = location
        self.packageVersion = packageVersion
        self.contentSHA256 = contentSHA256
        self.recoveryCode = recoveryCode
        self.installedAt = installedAt
        self.verifiedAt = verifiedAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, location, packageVersion, contentSHA256, recoveryCode
        case installedAt, verifiedAt, updatedAt
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

/// Stable, non-secret mapping from a product account to its runtime adapter.
enum YouziConnectorRuntimeBinding: Codable, Equatable, Sendable {
    case mcp(serverName: String)
    case builtIn(capabilityIdentifier: String)
    case native(adapterIdentifier: String)

    private enum CodingKeys: String, CodingKey {
        case kind, serverName, capabilityIdentifier, adapterIdentifier
    }

    private enum Kind: String, Codable { case mcp, builtIn, native }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .mcp:
            self = .mcp(serverName: try container.decode(String.self, forKey: .serverName))
        case .builtIn:
            self = .builtIn(
                capabilityIdentifier: try container.decode(
                    String.self, forKey: .capabilityIdentifier
                )
            )
        case .native:
            self = .native(
                adapterIdentifier: try container.decode(String.self, forKey: .adapterIdentifier)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .mcp(serverName):
            try container.encode(Kind.mcp, forKey: .kind)
            try container.encode(serverName, forKey: .serverName)
        case let .builtIn(capabilityIdentifier):
            try container.encode(Kind.builtIn, forKey: .kind)
            try container.encode(capabilityIdentifier, forKey: .capabilityIdentifier)
        case let .native(adapterIdentifier):
            try container.encode(Kind.native, forKey: .kind)
            try container.encode(adapterIdentifier, forKey: .adapterIdentifier)
        }
    }
}

struct YouziConnectorBinding: Identifiable, Codable, Equatable, Sendable {
    /// The binding shares the connection-account UUID.
    let id: UUID
    var runtime: YouziConnectorRuntimeBinding
    var configurationRevision: Int
    var recoveryCode: YouziRecoveryCode?
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID,
        runtime: YouziConnectorRuntimeBinding,
        configurationRevision: Int = 1,
        recoveryCode: YouziRecoveryCode? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.runtime = runtime
        self.configurationRevision = configurationRevision
        self.recoveryCode = recoveryCode
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, runtime, configurationRevision, recoveryCode, createdAt, updatedAt
    }
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

    private enum CodingKeys: String, CodingKey {
        case id, name, summary, adapter, authentication, declaredScopes, toolNames
        case source, state, createdAt, updatedAt
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
    var recoveryCode: YouziRecoveryCode?
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
        recoveryCode: YouziRecoveryCode? = nil,
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
        self.recoveryCode = recoveryCode
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, connectorID, displayName, credentialReference, grantedScopes
        case state, lastCheckedAt, lastErrorSummary, recoveryCode, createdAt, updatedAt
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

    private enum CodingKeys: String, CodingKey {
        case id, taskID, projectID, title, kind, previewText, fileID
        case state, createdAt, updatedAt
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

    private enum CodingKeys: String, CodingKey {
        case id, name, category, summary, samplePreview, prefilledRequest
        case recommendedHelperID, recommendedSkillIDs, recommendedConnectorIDs
        case requiredInputs, source, state, isFavorite, createdAt, updatedAt
    }
}

// MARK: - Automations

enum YouziAutomationTrigger: Codable, Equatable, Sendable {
    case manual
    case interval(seconds: TimeInterval, anchorAt: Date)
    case schedule(cronExpression: String, timeZoneIdentifier: String)

    private enum CodingKeys: String, CodingKey {
        case kind, seconds, anchorAt, cronExpression, timeZoneIdentifier
    }

    private enum Kind: String, Codable { case manual, interval, schedule }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .manual:
            self = .manual
        case .interval:
            self = .interval(
                seconds: try container.decode(TimeInterval.self, forKey: .seconds),
                anchorAt: try container.decode(Date.self, forKey: .anchorAt)
            )
        case .schedule:
            self = .schedule(
                cronExpression: try container.decode(String.self, forKey: .cronExpression),
                timeZoneIdentifier: try container.decode(String.self, forKey: .timeZoneIdentifier)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .manual:
            try container.encode(Kind.manual, forKey: .kind)
        case let .interval(seconds, anchorAt):
            try container.encode(Kind.interval, forKey: .kind)
            try container.encode(seconds, forKey: .seconds)
            try container.encode(anchorAt, forKey: .anchorAt)
        case let .schedule(cronExpression, timeZoneIdentifier):
            try container.encode(Kind.schedule, forKey: .kind)
            try container.encode(cronExpression, forKey: .cronExpression)
            try container.encode(timeZoneIdentifier, forKey: .timeZoneIdentifier)
        }
    }
}

struct YouziAutomationAction: Codable, Equatable, Sendable {
    var request: String
    var projectID: UUID?
    var workspaceID: UUID?
    var helperID: UUID?
    var skillIDs: [UUID]
    var connectionAccountIDs: [UUID]

    private enum CodingKeys: String, CodingKey {
        case request, projectID, workspaceID, helperID, skillIDs, connectionAccountIDs
    }
}

enum YouziAutomationState: String, Codable, Equatable, Sendable {
    case draft
    case active
    case paused
    case needsAttention
    case archived
}

enum YouziAutomationMissedRunPolicy: String, Codable, Equatable, Sendable {
    case runOnce
    case skip
}

enum YouziAutomationOverlapPolicy: String, Codable, Equatable, Sendable {
    case skipWhileActive
}

struct YouziAutomationRetryPolicy: Codable, Equatable, Sendable {
    var maximumAttempts: Int
    var baseDelaySeconds: TimeInterval

    init(maximumAttempts: Int = 1, baseDelaySeconds: TimeInterval = 1) {
        self.maximumAttempts = maximumAttempts
        self.baseDelaySeconds = baseDelaySeconds
    }

    private enum CodingKeys: String, CodingKey { case maximumAttempts, baseDelaySeconds }
}

struct YouziAutomation: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    /// Incremented when trigger, action, or long-term permission scope changes.
    var revision: Int
    var trigger: YouziAutomationTrigger
    var action: YouziAutomationAction
    var permissionRecordIDs: [UUID]
    var permissionGrantIDs: [UUID]
    var missedRunPolicy: YouziAutomationMissedRunPolicy
    var overlapPolicy: YouziAutomationOverlapPolicy
    var retryPolicy: YouziAutomationRetryPolicy
    var notificationEnabled: Bool
    var state: YouziAutomationState
    var confirmedAt: Date?
    var nextRunAt: Date?
    var lastRunAt: Date?
    var lastScheduledFor: Date?
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        revision: Int = 1,
        trigger: YouziAutomationTrigger,
        action: YouziAutomationAction,
        permissionRecordIDs: [UUID] = [],
        permissionGrantIDs: [UUID] = [],
        missedRunPolicy: YouziAutomationMissedRunPolicy = .runOnce,
        overlapPolicy: YouziAutomationOverlapPolicy = .skipWhileActive,
        retryPolicy: YouziAutomationRetryPolicy = .init(),
        notificationEnabled: Bool = true,
        state: YouziAutomationState = .active,
        confirmedAt: Date? = nil,
        nextRunAt: Date? = nil,
        lastRunAt: Date? = nil,
        lastScheduledFor: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.revision = revision
        self.trigger = trigger
        self.action = action
        self.permissionRecordIDs = permissionRecordIDs
        self.permissionGrantIDs = permissionGrantIDs
        self.missedRunPolicy = missedRunPolicy
        self.overlapPolicy = overlapPolicy
        self.retryPolicy = retryPolicy
        self.notificationEnabled = notificationEnabled
        self.state = state
        self.confirmedAt = confirmedAt ?? (state == .active ? createdAt : nil)
        self.nextRunAt = nextRunAt
        self.lastRunAt = lastRunAt
        self.lastScheduledFor = lastScheduledFor
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, revision, trigger, action, permissionRecordIDs, permissionGrantIDs
        case missedRunPolicy, overlapPolicy, retryPolicy, notificationEnabled, state
        case confirmedAt, nextRunAt, lastRunAt, lastScheduledFor, createdAt, updatedAt
    }
}

enum YouziAutomationRunStatus: String, Codable, Equatable, Sendable {
    case queued
    case running
    case awaitingConfirmation
    case retryScheduled
    case completed
    case failed
    case cancelled
    case skipped
}

struct YouziAutomationRun: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let automationID: UUID
    let automationRevision: Int
    var taskID: UUID?
    let scheduledFor: Date?
    let permissionGrantIDs: [UUID]
    let retryPolicy: YouziAutomationRetryPolicy
    var attemptCount: Int
    var status: YouziAutomationRunStatus
    var recoveryCode: YouziRecoveryCode?
    var summary: String?
    let createdAt: Date
    var startedAt: Date?
    var nextRetryAt: Date?
    var finishedAt: Date?

    init(
        id: UUID = UUID(),
        automationID: UUID,
        automationRevision: Int = 1,
        taskID: UUID? = nil,
        scheduledFor: Date? = nil,
        permissionGrantIDs: [UUID] = [],
        retryPolicy: YouziAutomationRetryPolicy = .init(),
        attemptCount: Int = 1,
        status: YouziAutomationRunStatus = .running,
        recoveryCode: YouziRecoveryCode? = nil,
        summary: String? = nil,
        createdAt: Date? = nil,
        startedAt: Date? = Date(),
        nextRetryAt: Date? = nil,
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.automationID = automationID
        self.automationRevision = automationRevision
        self.taskID = taskID
        self.scheduledFor = scheduledFor
        self.permissionGrantIDs = permissionGrantIDs
        self.retryPolicy = retryPolicy
        self.attemptCount = attemptCount
        self.status = status
        self.recoveryCode = recoveryCode
        self.summary = summary
        self.createdAt = createdAt ?? startedAt ?? Date()
        self.startedAt = startedAt
        self.nextRetryAt = nextRetryAt
        self.finishedAt = finishedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, automationID, automationRevision, taskID, scheduledFor
        case permissionGrantIDs, retryPolicy, attemptCount, status, recoveryCode
        case summary, createdAt, startedAt, nextRetryAt, finishedAt
    }
}

enum YouziExecutionAuditKind: String, Codable, Equatable, Sendable {
    case executionStarted
    case permissionChecked
    case toolRequested
    case toolCompleted
    case externalAction
    case executionCompleted
    case executionFailed
    case executionCancelled
}

enum YouziExecutionAuditOutcome: String, Codable, Equatable, Sendable {
    case allowed
    case denied
    case succeeded
    case failed
    case cancelled
    case unavailable
}

struct YouziExecutionAuditEvent: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let sequence: Int
    let taskID: UUID
    let automationRunID: UUID?
    let permissionRecordID: UUID?
    let permissionGrantID: UUID?
    let connectionAccountID: UUID?
    let capabilityIdentifier: String?
    let kind: YouziExecutionAuditKind
    let outcome: YouziExecutionAuditOutcome
    let recoveryCode: YouziRecoveryCode?
    let occurredAt: Date

    init(
        id: UUID = UUID(),
        sequence: Int,
        taskID: UUID,
        automationRunID: UUID? = nil,
        permissionRecordID: UUID? = nil,
        permissionGrantID: UUID? = nil,
        connectionAccountID: UUID? = nil,
        capabilityIdentifier: String? = nil,
        kind: YouziExecutionAuditKind,
        outcome: YouziExecutionAuditOutcome,
        recoveryCode: YouziRecoveryCode? = nil,
        occurredAt: Date = Date()
    ) {
        self.id = id
        self.sequence = sequence
        self.taskID = taskID
        self.automationRunID = automationRunID
        self.permissionRecordID = permissionRecordID
        self.permissionGrantID = permissionGrantID
        self.connectionAccountID = connectionAccountID
        self.capabilityIdentifier = capabilityIdentifier
        self.kind = kind
        self.outcome = outcome
        self.recoveryCode = recoveryCode
        self.occurredAt = occurredAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, sequence, taskID, automationRunID, permissionRecordID
        case permissionGrantID, connectionAccountID, capabilityIdentifier
        case kind, outcome, recoveryCode, occurredAt
    }
}

// MARK: - Memory graph

enum YouziMemoryScope: Codable, Equatable, Sendable {
    case personal
    case project(UUID)
    case workspace(UUID)
    case sensitiveSealed

    private enum CodingKeys: String, CodingKey { case kind, projectID, workspaceID }
    private enum Kind: String, Codable { case personal, project, workspace, sensitiveSealed }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .personal: self = .personal
        case .project:
            self = .project(try container.decode(UUID.self, forKey: .projectID))
        case .workspace:
            self = .workspace(try container.decode(UUID.self, forKey: .workspaceID))
        case .sensitiveSealed: self = .sensitiveSealed
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .personal:
            try container.encode(Kind.personal, forKey: .kind)
        case let .project(id):
            try container.encode(Kind.project, forKey: .kind)
            try container.encode(id, forKey: .projectID)
        case let .workspace(id):
            try container.encode(Kind.workspace, forKey: .kind)
            try container.encode(id, forKey: .workspaceID)
        case .sensitiveSealed:
            try container.encode(Kind.sensitiveSealed, forKey: .kind)
        }
    }
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

    private enum CodingKeys: String, CodingKey {
        case id, label, content, kind, confidence, scope, citationIDs, creationMethod
        case state, validFrom, validUntil, createdAt, updatedAt, lastConfirmedAt
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

    private enum CodingKeys: String, CodingKey {
        case id, sourceNodeID, targetNodeID, relation, explanation, confidence
        case scope, citationIDs, state, validFrom, validUntil, createdAt, updatedAt
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

    private enum CodingKeys: String, CodingKey {
        case id, sourceType, sourceID, scopeID, title, stableLocator, sourceTimestamp
        case excerpt, contentChecksum, authorizationState, createdAt, updatedAt
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

    private enum CodingKeys: String, CodingKey {
        case id, dimension, taskID, conversationID, helperID, transcriptMessageIDs
        case permissionRecordIDs, state, localeIdentifier, inputDeviceID, outputDeviceID
        case audioWasPersisted, startedAt, endedAt, updatedAt
    }
}
