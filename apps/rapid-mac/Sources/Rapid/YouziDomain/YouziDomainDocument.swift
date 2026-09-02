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
    var connectors: [YouziConnector]
    var connectionAccounts: [YouziConnectionAccount]
    var artifacts: [YouziArtifact]
    var templates: [YouziTemplate]
    var automations: [YouziAutomation]
    var automationRuns: [YouziAutomationRun]
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
        connectors: [YouziConnector] = [],
        connectionAccounts: [YouziConnectionAccount] = [],
        artifacts: [YouziArtifact] = [],
        templates: [YouziTemplate] = [],
        automations: [YouziAutomation] = [],
        automationRuns: [YouziAutomationRun] = [],
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
        self.connectors = connectors
        self.connectionAccounts = connectionAccounts
        self.artifacts = artifacts
        self.templates = templates
        self.automations = automations
        self.automationRuns = automationRuns
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
    mutating func upsert(_ record: YouziConnector) { Self.upsert(record, in: &connectors) }
    mutating func upsert(_ record: YouziConnectionAccount) { Self.upsert(record, in: &connectionAccounts) }
    mutating func upsert(_ record: YouziArtifact) { Self.upsert(record, in: &artifacts) }
    mutating func upsert(_ record: YouziTemplate) { Self.upsert(record, in: &templates) }
    mutating func upsert(_ record: YouziAutomation) { Self.upsert(record, in: &automations) }
    mutating func upsert(_ record: YouziAutomationRun) { Self.upsert(record, in: &automationRuns) }
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
}
