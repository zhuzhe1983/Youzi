import Foundation

/// The complete persisted Youzi metadata graph. Arrays contain records; links
/// between them are stable UUIDs so updating one record never embeds stale
/// copies into its dependents.
struct YouziDomainDocument: Codable, Equatable, Sendable {
    var permissions: [YouziPermissionRecord]
    var tasks: [YouziTask]
    var workspaces: [YouziWorkspace]
    var projects: [YouziProject]
    var helpers: [YouziHelper]
    var skills: [YouziSkill]
    var skillPackages: [YouziSkillPackageRecord]
    var connectors: [YouziConnector]
    var connectionAccounts: [YouziConnectionAccount]
    var connectorBindings: [YouziConnectorBinding]
    var permissionGrants: [YouziPermissionGrant]
    var files: [YouziFile]
    var artifacts: [YouziArtifact]
    var templates: [YouziTemplate]
    var automations: [YouziAutomation]
    var automationRuns: [YouziAutomationRun]
    var executionAuditEvents: [YouziExecutionAuditEvent]
    var memoryNodes: [YouziMemoryNode]
    var memoryEdges: [YouziMemoryEdge]
    var memoryCitations: [YouziMemoryCitation]
    var voiceSessions: [YouziVoiceSession]

    init(
        permissions: [YouziPermissionRecord] = [],
        tasks: [YouziTask] = [],
        workspaces: [YouziWorkspace] = [],
        projects: [YouziProject] = [],
        helpers: [YouziHelper] = [],
        skills: [YouziSkill] = [],
        skillPackages: [YouziSkillPackageRecord] = [],
        connectors: [YouziConnector] = [],
        connectionAccounts: [YouziConnectionAccount] = [],
        connectorBindings: [YouziConnectorBinding] = [],
        permissionGrants: [YouziPermissionGrant] = [],
        files: [YouziFile] = [],
        artifacts: [YouziArtifact] = [],
        templates: [YouziTemplate] = [],
        automations: [YouziAutomation] = [],
        automationRuns: [YouziAutomationRun] = [],
        executionAuditEvents: [YouziExecutionAuditEvent] = [],
        memoryNodes: [YouziMemoryNode] = [],
        memoryEdges: [YouziMemoryEdge] = [],
        memoryCitations: [YouziMemoryCitation] = [],
        voiceSessions: [YouziVoiceSession] = []
    ) {
        self.permissions = permissions
        self.tasks = tasks
        self.workspaces = workspaces
        self.projects = projects
        self.helpers = helpers
        self.skills = skills
        self.skillPackages = skillPackages
        self.connectors = connectors
        self.connectionAccounts = connectionAccounts
        self.connectorBindings = connectorBindings
        self.permissionGrants = permissionGrants
        self.files = files
        self.artifacts = artifacts
        self.templates = templates
        self.automations = automations
        self.automationRuns = automationRuns
        self.executionAuditEvents = executionAuditEvents
        self.memoryNodes = memoryNodes
        self.memoryEdges = memoryEdges
        self.memoryCitations = memoryCitations
        self.voiceSessions = voiceSessions
    }

    static let empty = YouziDomainDocument()

    mutating func upsert(_ record: YouziPermissionRecord) { Self.upsert(record, in: &permissions) }
    mutating func upsert(_ record: YouziTask) { Self.upsert(record, in: &tasks) }
    mutating func upsert(_ record: YouziWorkspace) { Self.upsert(record, in: &workspaces) }
    mutating func upsert(_ record: YouziProject) { Self.upsert(record, in: &projects) }
    mutating func upsert(_ record: YouziHelper) { Self.upsert(record, in: &helpers) }
    mutating func upsert(_ record: YouziSkill) { Self.upsert(record, in: &skills) }
    mutating func upsert(_ record: YouziSkillPackageRecord) { Self.upsert(record, in: &skillPackages) }
    mutating func upsert(_ record: YouziConnector) { Self.upsert(record, in: &connectors) }
    mutating func upsert(_ record: YouziConnectionAccount) { Self.upsert(record, in: &connectionAccounts) }
    mutating func upsert(_ record: YouziConnectorBinding) { Self.upsert(record, in: &connectorBindings) }
    mutating func upsert(_ record: YouziPermissionGrant) { Self.upsert(record, in: &permissionGrants) }
    mutating func upsert(_ record: YouziFile) { Self.upsert(record, in: &files) }
    mutating func upsert(_ record: YouziArtifact) { Self.upsert(record, in: &artifacts) }
    mutating func upsert(_ record: YouziTemplate) { Self.upsert(record, in: &templates) }
    mutating func upsert(_ record: YouziAutomation) { Self.upsert(record, in: &automations) }
    mutating func upsert(_ record: YouziAutomationRun) { Self.upsert(record, in: &automationRuns) }
    mutating func upsert(_ record: YouziExecutionAuditEvent) { Self.upsert(record, in: &executionAuditEvents) }
    mutating func upsert(_ record: YouziMemoryNode) { Self.upsert(record, in: &memoryNodes) }
    mutating func upsert(_ record: YouziMemoryEdge) { Self.upsert(record, in: &memoryEdges) }
    mutating func upsert(_ record: YouziMemoryCitation) { Self.upsert(record, in: &memoryCitations) }
    mutating func upsert(_ record: YouziVoiceSession) { Self.upsert(record, in: &voiceSessions) }

    private static func upsert<Record: Identifiable>(_ record: Record, in records: inout [Record])
    where Record.ID == UUID {
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
    }

    /// Canonical record ordering makes logically identical transactions encode
    /// to stable bytes. Ordered user-authored arrays remain untouched.
    mutating func canonicalizeRecordOrder() {
        permissions.sort(by: Self.ordersByUUID)
        tasks.sort(by: Self.ordersByUUID)
        workspaces.sort(by: Self.ordersByUUID)
        projects.sort(by: Self.ordersByUUID)
        helpers.sort(by: Self.ordersByUUID)
        skills.sort(by: Self.ordersByUUID)
        skillPackages.sort(by: Self.ordersByUUID)
        connectors.sort(by: Self.ordersByUUID)
        connectionAccounts.sort(by: Self.ordersByUUID)
        connectorBindings.sort(by: Self.ordersByUUID)
        permissionGrants.sort(by: Self.ordersByUUID)
        files.sort(by: Self.ordersByUUID)
        artifacts.sort(by: Self.ordersByUUID)
        templates.sort(by: Self.ordersByUUID)
        automations.sort(by: Self.ordersByUUID)
        automationRuns.sort(by: Self.ordersByUUID)
        executionAuditEvents.sort(by: Self.ordersByUUID)
        memoryNodes.sort(by: Self.ordersByUUID)
        memoryEdges.sort(by: Self.ordersByUUID)
        memoryCitations.sort(by: Self.ordersByUUID)
        voiceSessions.sort(by: Self.ordersByUUID)
    }

    private static func ordersByUUID<Record: Identifiable>(_ lhs: Record, _ rhs: Record) -> Bool
    where Record.ID == UUID {
        lhs.id.uuidString.lowercased() < rhs.id.uuidString.lowercased()
    }

    private enum CodingKeys: String, CodingKey {
        case permissions, tasks, workspaces, projects, helpers, skills, skillPackages
        case connectors, connectionAccounts, connectorBindings, permissionGrants
        case files, artifacts, templates, automations, automationRuns
        case executionAuditEvents, memoryNodes, memoryEdges, memoryCitations, voiceSessions
    }
}
