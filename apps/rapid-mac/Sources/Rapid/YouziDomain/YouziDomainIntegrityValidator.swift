import Foundation

enum YouziDomainIntegrityIssueCode: String, Codable, Equatable, Sendable {
    case duplicateRecordID
    case duplicateConversationID
    case duplicateReference
    case danglingReference
    case mismatchedReference
    case invalidRevision
    case invalidState
    case invalidPolicy
    case invalidTimestamp
    case invalidPath
    case invalidDigest
    case invalidCredentialReference
    case invalidPermissionSubject
    case invalidPermissionTarget
    case invalidDisplayText
    case invalidGrant
    case duplicateScheduledOccurrence
    case overlappingAutomationRun
    case duplicateAuditSequence
}

struct YouziDomainIntegrityIssue: Codable, Equatable, Sendable {
    var code: YouziDomainIntegrityIssueCode
    var recordID: UUID?
    var relatedID: UUID?
}

struct YouziDomainIntegrityError: Error, Equatable, Sendable {
    var issues: [YouziDomainIntegrityIssue]
}

extension YouziDomainIntegrityError: LocalizedError {
    var errorDescription: String? {
        let codes = issues.map(\.code.rawValue).sorted().joined(separator: ",")
        return "Youzi domain integrity validation failed: \(codes)."
    }
}

/// Pure validation for the complete persisted graph. Issues contain stable
/// codes and UUIDs only; stored values never enter errors or logs.
enum YouziDomainIntegrityValidator {
    private static let minimumInterval: TimeInterval = 300
    private static let maximumInterval: TimeInterval = 365 * 24 * 60 * 60
    private static let minimumRetryDelay: TimeInterval = 1
    private static let maximumRetryDelay: TimeInterval = 3_600

    static func validate(_ document: YouziDomainDocument) throws {
        var issues: [YouziDomainIntegrityIssue] = []

        checkUnique(document.permissions, into: &issues)
        checkUnique(document.tasks, into: &issues)
        checkUnique(document.workspaces, into: &issues)
        checkUnique(document.projects, into: &issues)
        checkUnique(document.helpers, into: &issues)
        checkUnique(document.skills, into: &issues)
        checkUnique(document.skillPackages, into: &issues)
        checkUnique(document.connectors, into: &issues)
        checkUnique(document.connectionAccounts, into: &issues)
        checkUnique(document.connectorBindings, into: &issues)
        checkUnique(document.permissionGrants, into: &issues)
        checkUnique(document.files, into: &issues)
        checkUnique(document.artifacts, into: &issues)
        checkUnique(document.templates, into: &issues)
        checkUnique(document.automations, into: &issues)
        checkUnique(document.automationRuns, into: &issues)
        checkUnique(document.executionAuditEvents, into: &issues)
        checkUnique(document.memoryNodes, into: &issues)
        checkUnique(document.memoryEdges, into: &issues)
        checkUnique(document.memoryCitations, into: &issues)
        checkUnique(document.voiceSessions, into: &issues)

        let permissionIDs = Set(document.permissions.map(\.id))
        let taskIDs = Set(document.tasks.map(\.id))
        let workspaceIDs = Set(document.workspaces.map(\.id))
        let projectIDs = Set(document.projects.map(\.id))
        let helperIDs = Set(document.helpers.map(\.id))
        let skillIDs = Set(document.skills.map(\.id))
        let packageIDs = Set(document.skillPackages.map(\.id))
        let connectorIDs = Set(document.connectors.map(\.id))
        let accountIDs = Set(document.connectionAccounts.map(\.id))
        let bindingIDs = Set(document.connectorBindings.map(\.id))
        let grantIDs = Set(document.permissionGrants.map(\.id))
        let fileIDs = Set(document.files.map(\.id))
        let artifactIDs = Set(document.artifacts.map(\.id))
        let automationIDs = Set(document.automations.map(\.id))
        let runIDs = Set(document.automationRuns.map(\.id))
        let nodeIDs = Set(document.memoryNodes.map(\.id))
        let citationIDs = Set(document.memoryCitations.map(\.id))

        // Duplicate IDs are validation findings, never process-fatal input.
        // Keep the first record for secondary reference checks after recording
        // the duplicate above.
        let permissionsByID = indexByID(document.permissions)
        let tasksByID = indexByID(document.tasks)
        let skillsByID = indexByID(document.skills)
        let connectorsByID = indexByID(document.connectors)
        let accountsByID = indexByID(document.connectionAccounts)
        let bindingsByID = indexByID(document.connectorBindings)
        let grantsByID = indexByID(document.permissionGrants)
        let automationsByID = indexByID(document.automations)
        let runsByID = indexByID(document.automationRuns)
        let filesByID = indexByID(document.files)

        var taskByConversationID: [UUID: UUID] = [:]
        for task in document.tasks {
            if let conversationID = task.conversationID,
               let existingTaskID = taskByConversationID.updateValue(task.id, forKey: conversationID) {
                issues.append(.init(
                    code: .duplicateConversationID,
                    recordID: task.id,
                    relatedID: existingTaskID
                ))
            }
            require(task.workspaceID, in: workspaceIDs, owner: task.id, issues: &issues)
            require(task.projectID, in: projectIDs, owner: task.id, issues: &issues)
            require(task.helperID, in: helperIDs, owner: task.id, issues: &issues)
            require(task.skillIDs, in: skillIDs, owner: task.id, issues: &issues)
            require(task.connectionAccountIDs, in: accountIDs, owner: task.id, issues: &issues)
            require(task.permissionRecordIDs, in: permissionIDs, owner: task.id, issues: &issues)
            require(task.inputFileIDs, in: fileIDs, owner: task.id, issues: &issues)
            require(task.artifactIDs, in: artifactIDs, owner: task.id, issues: &issues)
            checkNoDuplicates(task.skillIDs, owner: task.id, issues: &issues)
            checkNoDuplicates(task.connectionAccountIDs, owner: task.id, issues: &issues)
            checkNoDuplicates(task.permissionRecordIDs, owner: task.id, issues: &issues)
            checkNoDuplicates(task.inputFileIDs, owner: task.id, issues: &issues)
            checkNoDuplicates(task.artifactIDs, owner: task.id, issues: &issues)
        }

        for project in document.projects {
            require(project.defaultHelperIDs, in: helperIDs, owner: project.id, issues: &issues)
            require(project.defaultSkillIDs, in: skillIDs, owner: project.id, issues: &issues)
            require(project.defaultConnectionAccountIDs, in: accountIDs, owner: project.id, issues: &issues)
            require(project.resourceFileIDs, in: fileIDs, owner: project.id, issues: &issues)
            checkNoDuplicates(project.defaultHelperIDs, owner: project.id, issues: &issues)
            checkNoDuplicates(project.defaultSkillIDs, owner: project.id, issues: &issues)
            checkNoDuplicates(project.defaultConnectionAccountIDs, owner: project.id, issues: &issues)
            checkNoDuplicates(project.resourceFileIDs, owner: project.id, issues: &issues)
        }

        for helper in document.helpers {
            require(helper.recommendedSkillIDs, in: skillIDs, owner: helper.id, issues: &issues)
            require(helper.allowedConnectorIDs, in: connectorIDs, owner: helper.id, issues: &issues)
            checkNoDuplicates(helper.recommendedSkillIDs, owner: helper.id, issues: &issues)
            checkNoDuplicates(helper.allowedConnectorIDs, owner: helper.id, issues: &issues)
        }

        for skill in document.skills {
            require(skill.connectorDependencyIDs, in: connectorIDs, owner: skill.id, issues: &issues)
            checkNoDuplicates(skill.connectorDependencyIDs, owner: skill.id, issues: &issues)
            if skill.state == .active, !packageIDs.contains(skill.id) {
                issues.append(.init(code: .danglingReference, recordID: skill.id, relatedID: skill.id))
            }
        }

        for package in document.skillPackages {
            guard let skill = skillsByID[package.id] else {
                issues.append(.init(code: .danglingReference, recordID: package.id, relatedID: package.id))
                continue
            }
            if package.packageVersion != skill.packageVersion {
                issues.append(.init(code: .mismatchedReference, recordID: package.id, relatedID: skill.id))
            }
            if package.contentSHA256.count != 64
                || package.contentSHA256.contains(where: { !$0.isHexDigit || $0.isUppercase }) {
                issues.append(.init(code: .invalidDigest, recordID: package.id))
            }
            if !isValidPackageLocation(package.location) {
                issues.append(.init(code: .invalidPath, recordID: package.id))
            }
        }

        for account in document.connectionAccounts {
            guard let connector = connectorsByID[account.connectorID] else {
                issues.append(.init(code: .danglingReference, recordID: account.id, relatedID: account.connectorID))
                continue
            }
            if !Set(account.grantedScopes).isSubset(of: Set(connector.declaredScopes)) {
                issues.append(.init(code: .mismatchedReference, recordID: account.id, relatedID: connector.id))
            }
            checkNoDuplicateStrings(account.grantedScopes, owner: account.id, issues: &issues)
            if let reference = account.credentialReference,
               !isValidCredentialReference(reference, accountID: account.id) {
                issues.append(.init(code: .invalidCredentialReference, recordID: account.id))
            }
            if account.state == .connected,
               connector.authentication != .none,
               connector.authentication != .localSession,
               account.credentialReference == nil {
                issues.append(.init(code: .invalidState, recordID: account.id))
            }
            if account.state == .connected, account.recoveryCode != nil {
                issues.append(.init(code: .invalidState, recordID: account.id))
            }
        }

        for connector in document.connectors {
            checkNoDuplicateStrings(connector.declaredScopes, owner: connector.id, issues: &issues)
            checkNoDuplicateStrings(connector.toolNames, owner: connector.id, issues: &issues)
        }

        for binding in document.connectorBindings {
            guard let account = accountsByID[binding.id],
                  let connector = connectorsByID[account.connectorID] else {
                issues.append(.init(code: .danglingReference, recordID: binding.id, relatedID: binding.id))
                continue
            }
            if binding.configurationRevision < 1 {
                issues.append(.init(code: .invalidRevision, recordID: binding.id))
            }
            switch binding.runtime {
            case let .mcp(serverName):
                if connector.adapter != .mcp || !isValidStableIdentifier(serverName) {
                    issues.append(.init(code: .mismatchedReference, recordID: binding.id, relatedID: connector.id))
                }
            case let .builtIn(capabilityIdentifier):
                if connector.adapter != .native || !isValidStableIdentifier(capabilityIdentifier) {
                    issues.append(.init(code: .mismatchedReference, recordID: binding.id, relatedID: connector.id))
                }
            case let .native(adapterIdentifier):
                if (connector.adapter != .native && connector.adapter != .skillBacked)
                    || !isValidStableIdentifier(adapterIdentifier) {
                    issues.append(.init(code: .mismatchedReference, recordID: binding.id, relatedID: connector.id))
                }
            }
        }

        for permission in document.permissions {
            let hasTask = permission.taskID != nil
            let hasAutomation = permission.automationID != nil || permission.automationRevision != nil
            if hasTask && hasAutomation
                || ((permission.automationID == nil) != (permission.automationRevision == nil)) {
                issues.append(.init(code: .invalidPermissionSubject, recordID: permission.id))
            }
            require(permission.taskID, in: taskIDs, owner: permission.id, issues: &issues)
            if let automationID = permission.automationID {
                require(automationID, in: automationIDs, owner: permission.id, issues: &issues)
                if let revision = permission.automationRevision,
                   revision < 1 || revision > (automationsByID[automationID]?.revision ?? 0) {
                    issues.append(.init(code: .invalidRevision, recordID: permission.id, relatedID: automationID))
                }
            }
            validatePermissionTarget(permission.kind, permission.targetIdentifier,
                                     workspaces: workspaceIDs, accounts: accountIDs,
                                     owner: permission.id, issues: &issues)
            if permission.purpose.isEmpty || permission.purpose.count > 240
                || permission.purpose.unicodeScalars.contains(where: {
                    CharacterSet.controlCharacters.contains($0)
                }) {
                issues.append(.init(code: .invalidDisplayText, recordID: permission.id))
            }
            if permission.decision == .pending && permission.decidedAt != nil
                || permission.decision != .pending && permission.decidedAt == nil {
                issues.append(.init(code: .invalidTimestamp, recordID: permission.id))
            }
        }

        for grant in document.permissionGrants {
            guard let request = permissionsByID[grant.permissionRecordID] else {
                issues.append(.init(code: .danglingReference, recordID: grant.id,
                                    relatedID: grant.permissionRecordID))
                continue
            }
            require(grant.taskID, in: taskIDs, owner: grant.id, issues: &issues)
            require(grant.automationID, in: automationIDs, owner: grant.id, issues: &issues)
            let decisionMatches = request.decision == .allowed
                || (request.decision == .revoked && grant.revokedAt != nil)
            let matches = decisionMatches
                && request.taskID == grant.taskID
                && request.automationID == grant.automationID
                && request.automationRevision == grant.automationRevision
                && request.kind == grant.kind
                && request.targetIdentifier == grant.targetIdentifier
                && request.duration == grant.duration
            if !matches {
                issues.append(.init(code: .invalidGrant, recordID: grant.id,
                                    relatedID: request.id))
            }
            if grant.taskID != nil && grant.automationID != nil
                || ((grant.automationID == nil) != (grant.automationRevision == nil))
                || (grant.automationID != nil && grant.duration != .persistent) {
                issues.append(.init(code: .invalidGrant, recordID: grant.id))
            }
            let targetsConnector = grant.kind == .connectorRead
                || grant.kind == .connectorWrite || grant.kind == .externalPublish
            if targetsConnector != (grant.targetRevision != nil) {
                issues.append(.init(code: .invalidGrant, recordID: grant.id))
            }
            if let automationID = grant.automationID,
               grant.automationRevision != automationsByID[automationID]?.revision {
                // Historical revoked grants may point at older revisions.
                if grant.revokedAt == nil {
                    issues.append(.init(code: .invalidGrant, recordID: grant.id,
                                        relatedID: automationID))
                }
            }
            if let targetRevision = grant.targetRevision {
                guard let accountID = UUID(uuidString: grant.targetIdentifier),
                      bindingIDs.contains(accountID),
                      let currentRevision = bindingsByID[accountID]?.configurationRevision,
                      targetRevision >= 1,
                      targetRevision <= currentRevision,
                      grant.revokedAt != nil || targetRevision == currentRevision else {
                    issues.append(.init(code: .invalidGrant, recordID: grant.id))
                    continue
                }
            }
            if let expiresAt = grant.expiresAt, expiresAt < grant.grantedAt
                || grant.consumedAt.map({ $0 < grant.grantedAt }) == true
                || grant.revokedAt.map({ $0 < grant.grantedAt }) == true {
                issues.append(.init(code: .invalidTimestamp, recordID: grant.id))
            }
        }

        for file in document.files {
            require(file.originTaskID, in: taskIDs, owner: file.id, issues: &issues)
            require(file.projectID, in: projectIDs, owner: file.id, issues: &issues)
        }

        for artifact in document.artifacts {
            require(artifact.taskID, in: taskIDs, owner: artifact.id, issues: &issues)
            require(artifact.projectID, in: projectIDs, owner: artifact.id, issues: &issues)
            require(artifact.fileID, in: fileIDs, owner: artifact.id, issues: &issues)
            if let task = tasksByID[artifact.taskID], task.projectID != artifact.projectID {
                issues.append(.init(code: .mismatchedReference, recordID: artifact.id,
                                    relatedID: artifact.taskID))
            }
            if let file = filesByID[artifact.fileID],
               file.role != .artifact || file.originTaskID != artifact.taskID {
                issues.append(.init(code: .mismatchedReference, recordID: artifact.id,
                                    relatedID: file.id))
            }
        }

        for template in document.templates {
            require(template.recommendedHelperID, in: helperIDs, owner: template.id, issues: &issues)
            require(template.recommendedSkillIDs, in: skillIDs, owner: template.id, issues: &issues)
            require(template.recommendedConnectorIDs, in: connectorIDs, owner: template.id, issues: &issues)
            checkNoDuplicates(template.recommendedSkillIDs, owner: template.id, issues: &issues)
            checkNoDuplicates(template.recommendedConnectorIDs, owner: template.id, issues: &issues)
        }

        var occurrenceOwners: [ScheduledOccurrence: UUID] = [:]
        var activeRunByAutomation: [UUID: UUID] = [:]
        for automation in document.automations {
            if automation.revision < 1 {
                issues.append(.init(code: .invalidRevision, recordID: automation.id))
            }
            validate(automation.trigger, owner: automation.id, issues: &issues)
            validate(automation.retryPolicy, owner: automation.id, issues: &issues)
            require(automation.action.projectID, in: projectIDs, owner: automation.id, issues: &issues)
            require(automation.action.workspaceID, in: workspaceIDs, owner: automation.id, issues: &issues)
            require(automation.action.helperID, in: helperIDs, owner: automation.id, issues: &issues)
            require(automation.action.skillIDs, in: skillIDs, owner: automation.id, issues: &issues)
            require(automation.action.connectionAccountIDs, in: accountIDs, owner: automation.id, issues: &issues)
            require(automation.permissionRecordIDs, in: permissionIDs, owner: automation.id, issues: &issues)
            require(automation.permissionGrantIDs, in: grantIDs, owner: automation.id, issues: &issues)
            checkNoDuplicates(automation.action.skillIDs, owner: automation.id, issues: &issues)
            checkNoDuplicates(automation.action.connectionAccountIDs, owner: automation.id, issues: &issues)
            checkNoDuplicates(automation.permissionRecordIDs, owner: automation.id, issues: &issues)
            checkNoDuplicates(automation.permissionGrantIDs, owner: automation.id, issues: &issues)
            if automation.state == .active && automation.confirmedAt == nil {
                issues.append(.init(code: .invalidState, recordID: automation.id))
            }
            for grantID in automation.permissionGrantIDs {
                guard let grant = grantsByID[grantID], grant.automationID == automation.id,
                      grant.automationRevision == automation.revision,
                      grant.revokedAt == nil else {
                    issues.append(.init(code: .invalidGrant, recordID: automation.id,
                                        relatedID: grantID))
                    continue
                }
            }
        }

        for run in document.automationRuns {
            guard let automation = automationsByID[run.automationID] else {
                issues.append(.init(code: .danglingReference, recordID: run.id,
                                    relatedID: run.automationID))
                continue
            }
            if run.automationRevision < 1 || run.automationRevision > automation.revision {
                issues.append(.init(code: .invalidRevision, recordID: run.id,
                                    relatedID: automation.id))
            }
            require(run.taskID, in: taskIDs, owner: run.id, issues: &issues)
            require(run.permissionGrantIDs, in: grantIDs, owner: run.id, issues: &issues)
            checkNoDuplicates(run.permissionGrantIDs, owner: run.id, issues: &issues)
            for grantID in run.permissionGrantIDs {
                guard let grant = grantsByID[grantID],
                      grant.automationID == run.automationID,
                      grant.automationRevision == run.automationRevision else {
                    issues.append(.init(code: .invalidGrant, recordID: run.id,
                                        relatedID: grantID))
                    continue
                }
            }
            validate(run.retryPolicy, owner: run.id, issues: &issues)
            if let summary = run.summary,
               summary.count > 500 || summary.unicodeScalars.contains(where: {
                   CharacterSet.controlCharacters.contains($0)
               }) {
                issues.append(.init(code: .invalidDisplayText, recordID: run.id))
            }
            if run.attemptCount < 0 || run.attemptCount > run.retryPolicy.maximumAttempts {
                issues.append(.init(code: .invalidPolicy, recordID: run.id))
            }
            if let startedAt = run.startedAt, startedAt < run.createdAt
                || run.nextRetryAt.map({ $0 < run.createdAt }) == true
                || run.finishedAt.map({ $0 < run.createdAt }) == true {
                issues.append(.init(code: .invalidTimestamp, recordID: run.id))
            }
            switch run.status {
            case .queued:
                if run.attemptCount != 0 || run.startedAt != nil
                    || run.nextRetryAt != nil || run.finishedAt != nil {
                    issues.append(.init(code: .invalidState, recordID: run.id))
                }
            case .running:
                if run.attemptCount < 1 || run.startedAt == nil
                    || run.nextRetryAt != nil || run.finishedAt != nil {
                    issues.append(.init(code: .invalidState, recordID: run.id))
                }
            case .awaitingConfirmation:
                if run.finishedAt != nil || run.nextRetryAt != nil {
                    issues.append(.init(code: .invalidState, recordID: run.id))
                }
            case .retryScheduled:
                if run.attemptCount < 1 || run.startedAt == nil
                    || run.nextRetryAt == nil || run.finishedAt != nil {
                    issues.append(.init(code: .invalidState, recordID: run.id))
                }
            case .completed:
                if run.attemptCount < 1 || run.startedAt == nil
                    || run.finishedAt == nil {
                    issues.append(.init(code: .invalidState, recordID: run.id))
                }
            case .failed, .cancelled:
                if run.finishedAt == nil {
                    issues.append(.init(code: .invalidState, recordID: run.id))
                }
            case .skipped:
                if run.attemptCount != 0 || run.startedAt != nil || run.finishedAt == nil {
                    issues.append(.init(code: .invalidState, recordID: run.id))
                }
            }
            if let scheduledFor = run.scheduledFor {
                let key = ScheduledOccurrence(
                    automationID: run.automationID,
                    revision: run.automationRevision,
                    scheduledFor: scheduledFor
                )
                if let existing = occurrenceOwners.updateValue(run.id, forKey: key) {
                    issues.append(.init(code: .duplicateScheduledOccurrence,
                                        recordID: run.id, relatedID: existing))
                }
            }
            if run.status.isActive {
                if let existing = activeRunByAutomation.updateValue(run.id, forKey: run.automationID) {
                    issues.append(.init(code: .overlappingAutomationRun,
                                        recordID: run.id, relatedID: existing))
                }
            }
        }

        var auditSequences: [AuditSequence: UUID] = [:]
        var auditStreams: [AuditStream: [(sequence: Int, date: Date, id: UUID)]] = [:]
        for event in document.executionAuditEvents {
            require(event.taskID, in: taskIDs, owner: event.id, issues: &issues)
            require(event.automationRunID, in: runIDs, owner: event.id, issues: &issues)
            require(event.permissionRecordID, in: permissionIDs, owner: event.id, issues: &issues)
            require(event.permissionGrantID, in: grantIDs, owner: event.id, issues: &issues)
            require(event.connectionAccountID, in: accountIDs, owner: event.id, issues: &issues)
            if let capability = event.capabilityIdentifier,
               !isValidStableIdentifier(capability) {
                issues.append(.init(code: .invalidDisplayText, recordID: event.id))
            }
            if event.sequence < 1 {
                issues.append(.init(code: .invalidRevision, recordID: event.id))
            }
            if let runID = event.automationRunID,
               runsByID[runID]?.taskID != event.taskID {
                issues.append(.init(code: .mismatchedReference, recordID: event.id,
                                    relatedID: runID))
            }
            let key = AuditSequence(taskID: event.taskID,
                                    automationRunID: event.automationRunID,
                                    sequence: event.sequence)
            if let existing = auditSequences.updateValue(event.id, forKey: key) {
                issues.append(.init(code: .duplicateAuditSequence,
                                    recordID: event.id, relatedID: existing))
            }
            let stream = AuditStream(
                taskID: event.taskID,
                automationRunID: event.automationRunID
            )
            auditStreams[stream, default: []].append(
                (event.sequence, event.occurredAt, event.id)
            )
        }
        for events in auditStreams.values {
            let ordered = events.sorted { $0.sequence < $1.sequence }
            for (index, event) in ordered.enumerated() {
                if event.sequence != index + 1 {
                    issues.append(.init(code: .invalidRevision, recordID: event.id))
                }
                if index > 0, event.date < ordered[index - 1].date {
                    issues.append(.init(code: .invalidTimestamp, recordID: event.id))
                }
            }
        }

        for node in document.memoryNodes {
            require(node.citationIDs, in: citationIDs, owner: node.id, issues: &issues)
            checkNoDuplicates(node.citationIDs, owner: node.id, issues: &issues)
            validate(node.scope, owner: node.id, projects: projectIDs,
                     workspaces: workspaceIDs, issues: &issues)
        }
        for edge in document.memoryEdges {
            require(edge.sourceNodeID, in: nodeIDs, owner: edge.id, issues: &issues)
            require(edge.targetNodeID, in: nodeIDs, owner: edge.id, issues: &issues)
            require(edge.citationIDs, in: citationIDs, owner: edge.id, issues: &issues)
            checkNoDuplicates(edge.citationIDs, owner: edge.id, issues: &issues)
            validate(edge.scope, owner: edge.id, projects: projectIDs,
                     workspaces: workspaceIDs, issues: &issues)
        }
        for voice in document.voiceSessions {
            require(voice.taskID, in: taskIDs, owner: voice.id, issues: &issues)
            require(voice.helperID, in: helperIDs, owner: voice.id, issues: &issues)
            require(voice.permissionRecordIDs, in: permissionIDs, owner: voice.id, issues: &issues)
            checkNoDuplicates(voice.permissionRecordIDs, owner: voice.id, issues: &issues)
        }

        if !issues.isEmpty {
            throw YouziDomainIntegrityError(issues: issues.sorted(by: ordersIssues))
        }
    }

    private static func checkUnique<Record: Identifiable>(
        _ records: [Record], into issues: inout [YouziDomainIntegrityIssue]
    ) where Record.ID == UUID {
        var seen = Set<UUID>()
        for record in records where !seen.insert(record.id).inserted {
            issues.append(.init(code: .duplicateRecordID, recordID: record.id))
        }
    }

    private static func indexByID<Record: Identifiable>(_ records: [Record]) -> [UUID: Record]
    where Record.ID == UUID {
        var result: [UUID: Record] = [:]
        for record in records where result[record.id] == nil {
            result[record.id] = record
        }
        return result
    }

    private static func checkNoDuplicates(
        _ ids: [UUID], owner: UUID, issues: inout [YouziDomainIntegrityIssue]
    ) {
        var seen = Set<UUID>()
        for id in ids where !seen.insert(id).inserted {
            issues.append(.init(code: .duplicateReference, recordID: owner, relatedID: id))
        }
    }

    private static func checkNoDuplicateStrings(
        _ values: [String], owner: UUID, issues: inout [YouziDomainIntegrityIssue]
    ) {
        var seen = Set<String>()
        if values.contains(where: { !seen.insert($0).inserted }) {
            issues.append(.init(code: .duplicateReference, recordID: owner))
        }
    }

    private static func require(
        _ id: UUID?, in valid: Set<UUID>, owner: UUID,
        issues: inout [YouziDomainIntegrityIssue]
    ) {
        if let id, !valid.contains(id) {
            issues.append(.init(code: .danglingReference, recordID: owner, relatedID: id))
        }
    }

    private static func require(
        _ ids: [UUID], in valid: Set<UUID>, owner: UUID,
        issues: inout [YouziDomainIntegrityIssue]
    ) {
        for id in ids { require(id, in: valid, owner: owner, issues: &issues) }
    }

    private static func validatePermissionTarget(
        _ kind: YouziPermissionKind,
        _ target: String,
        workspaces: Set<UUID>,
        accounts: Set<UUID>,
        owner: UUID,
        issues: inout [YouziDomainIntegrityIssue]
    ) {
        switch kind {
        case .workspaceRead, .workspaceWrite:
            guard let id = UUID(uuidString: target), workspaces.contains(id),
                  target == id.uuidString.lowercased() else {
                issues.append(.init(code: .invalidPermissionTarget, recordID: owner))
                return
            }
        case .connectorRead, .connectorWrite, .externalPublish:
            guard let id = UUID(uuidString: target), accounts.contains(id),
                  target == id.uuidString.lowercased() else {
                issues.append(.init(code: .invalidPermissionTarget, recordID: owner))
                return
            }
        case .networkAccess:
            if target.isEmpty || target.count > 128 {
                issues.append(.init(code: .invalidPermissionTarget, recordID: owner))
            }
        case .destructiveLocalAction, .microphone, .saveAudio:
            if target.isEmpty || target.count > 128 || target.contains("/") {
                issues.append(.init(code: .invalidPermissionTarget, recordID: owner))
            }
        }
    }

    private static func validate(
        _ trigger: YouziAutomationTrigger,
        owner: UUID,
        issues: inout [YouziDomainIntegrityIssue]
    ) {
        switch trigger {
        case .manual:
            break
        case let .interval(seconds, _):
            if !seconds.isFinite || !(minimumInterval...maximumInterval).contains(seconds) {
                issues.append(.init(code: .invalidPolicy, recordID: owner))
            }
        case let .schedule(expression, timeZoneIdentifier):
            if expression.split(whereSeparator: \Character.isWhitespace).count != 5
                || TimeZone(identifier: timeZoneIdentifier) == nil {
                issues.append(.init(code: .invalidPolicy, recordID: owner))
            }
        }
    }

    private static func validate(
        _ policy: YouziAutomationRetryPolicy,
        owner: UUID,
        issues: inout [YouziDomainIntegrityIssue]
    ) {
        if !(1...4).contains(policy.maximumAttempts)
            || !policy.baseDelaySeconds.isFinite
            || !(minimumRetryDelay...maximumRetryDelay).contains(policy.baseDelaySeconds) {
            issues.append(.init(code: .invalidPolicy, recordID: owner))
        }
    }

    private static func validate(
        _ scope: YouziMemoryScope,
        owner: UUID,
        projects: Set<UUID>,
        workspaces: Set<UUID>,
        issues: inout [YouziDomainIntegrityIssue]
    ) {
        switch scope {
        case .personal, .sensitiveSealed: break
        case let .project(id): require(id, in: projects, owner: owner, issues: &issues)
        case let .workspace(id): require(id, in: workspaces, owner: owner, issues: &issues)
        }
    }

    private static func isValidPackageLocation(_ location: YouziSkillPackageLocation) -> Bool {
        let path: String
        switch location {
        case let .bundled(resourcePath), let .appManaged(resourcePath): path = resourcePath
        case let .securityScopedBookmark(data, _): return !data.isEmpty
        }
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~"),
              !path.contains("\0") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false)
            .contains(where: { $0 == "." || $0 == ".." || $0.isEmpty })
    }

    static func isValidCredentialReference(_ reference: String, accountID: UUID) -> Bool {
        if reference == "youzi.connector.\(accountID.uuidString.lowercased())" { return true }
        guard reference.hasPrefix("keychain:"), reference.count <= 128 else { return false }
        let suffix = reference.dropFirst("keychain:".count)
        return !suffix.isEmpty && suffix.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-")).contains($0)
        }
    }

    private static func isValidStableIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 256 && !value.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
        }
    }

    private static func ordersIssues(
        _ lhs: YouziDomainIntegrityIssue, _ rhs: YouziDomainIntegrityIssue
    ) -> Bool {
        let left = "\(lhs.code.rawValue)|\(lhs.recordID?.uuidString ?? "")|\(lhs.relatedID?.uuidString ?? "")"
        let right = "\(rhs.code.rawValue)|\(rhs.recordID?.uuidString ?? "")|\(rhs.relatedID?.uuidString ?? "")"
        return left < right
    }

    private struct ScheduledOccurrence: Hashable {
        var automationID: UUID
        var revision: Int
        var scheduledFor: Date
    }

    private struct AuditSequence: Hashable {
        var taskID: UUID
        var automationRunID: UUID?
        var sequence: Int
    }

    private struct AuditStream: Hashable {
        var taskID: UUID
        var automationRunID: UUID?
    }
}

private extension YouziAutomationRunStatus {
    var isActive: Bool {
        switch self {
        case .queued, .running, .awaitingConfirmation, .retryScheduled: true
        case .completed, .failed, .cancelled, .skipped: false
        }
    }
}
