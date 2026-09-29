import Foundation

/// The durable subject whose authority is being evaluated for one execution.
/// App-wide authority is intentionally not represented: an unscoped grant must
/// never become authority for a task or an automation by omission.
enum YouziExecutionPermissionSubject: Equatable, Sendable {
    case interactiveTask(UUID)
    case automation(id: UUID, revision: Int)
}

/// A normalized permission requirement produced before any tool is invoked.
/// Identifiers are stable IDs only; callers must not put paths, arguments, or
/// user-entered prose in this value.
struct YouziExecutionPermissionRequirement: Equatable, Sendable {
    let kind: YouziPermissionKind
    let targetIdentifier: String
    let targetRevision: Int?
    let connectionAccountID: UUID?
    let capabilityIdentifier: String?
    let toolName: String?

    init(
        kind: YouziPermissionKind,
        targetIdentifier: String,
        targetRevision: Int? = nil,
        connectionAccountID: UUID? = nil,
        capabilityIdentifier: String? = nil,
        toolName: String? = nil
    ) {
        self.kind = kind
        self.targetIdentifier = targetIdentifier
        self.targetRevision = targetRevision
        self.connectionAccountID = connectionAccountID
        self.capabilityIdentifier = capabilityIdentifier
        self.toolName = toolName
    }
}

/// The concrete lower-level approval state captured immediately before an
/// execution. The evaluator never infers this state from durable records.
enum YouziExecutionLowLevelApproval: Equatable, Sendable {
    case notRequired
    case approved
    case awaitingUser
    case denied
    case unavailable
}

/// A point-in-time snapshot for the exact requirement being evaluated.
/// Identity fields prevent a snapshot for one tool/account from being reused
/// for another requirement.
struct YouziExecutionPermissionRuntimeGate: Equatable, Sendable {
    let toolName: String?
    let capabilityIdentifier: String?
    let connectionAccountID: UUID?
    let bindingRevision: Int?
    let advertisedForTurn: Bool
    let globallyEnabled: Bool
    let toolEnabled: Bool
    let runtimeAvailable: Bool
    let lowLevelApproval: YouziExecutionLowLevelApproval

    init(
        toolName: String? = nil,
        capabilityIdentifier: String? = nil,
        connectionAccountID: UUID? = nil,
        bindingRevision: Int? = nil,
        advertisedForTurn: Bool,
        globallyEnabled: Bool,
        toolEnabled: Bool,
        runtimeAvailable: Bool,
        lowLevelApproval: YouziExecutionLowLevelApproval
    ) {
        self.toolName = toolName
        self.capabilityIdentifier = capabilityIdentifier
        self.connectionAccountID = connectionAccountID
        self.bindingRevision = bindingRevision
        self.advertisedForTurn = advertisedForTurn
        self.globallyEnabled = globallyEnabled
        self.toolEnabled = toolEnabled
        self.runtimeAvailable = runtimeAvailable
        self.lowLevelApproval = lowLevelApproval
    }
}

enum YouziExecutionPermissionDisabledLayer: Equatable, Sendable {
    case global
    case tool
}

/// The caller must perform this mutation atomically with execution. Returning
/// an intent keeps the evaluator pure and prevents check-then-consume races from
/// being hidden inside authorization logic.
enum YouziExecutionPermissionConsumptionIntent: Equatable, Sendable {
    case consumeOnce(grantID: UUID)
}

struct YouziExecutionPermissionAuthorization: Equatable, Sendable {
    /// Every currently live exact grant, sorted by UUID for stable audit output.
    let matchingGrantIDs: [UUID]
    /// The deterministic grant selected as the authority for this execution.
    let selectedGrantID: UUID
    let permissionRecordID: UUID
    let consumptionIntent: YouziExecutionPermissionConsumptionIntent?
}

enum YouziExecutionPermissionOutcome: Equatable, Sendable {
    case authorized(YouziExecutionPermissionAuthorization)
    case domainPermissionRequired
    case awaitingLowLevelConfirmation
    case denied
    case disabled(YouziExecutionPermissionDisabledLayer)
    case notAdvertised
    case accountUnavailable
    case bindingUnavailable
    case runtimeUnavailable
    case malformedRequirement
}

enum YouziExecutionPermissionRecovery: Equatable, Sendable {
    case none
    case requestDomainPermission
    case presentLowLevelConfirmation
    case reviewDeniedPermission
    case enableGlobalRuntime
    case enableTool
    case advertiseTool
    case reconnectAccount
    case repairConnectorBinding
    case restoreRuntime
    case correctRequirement
}

struct YouziExecutionPermissionEvaluation: Equatable, Sendable {
    let outcome: YouziExecutionPermissionOutcome
    let recovery: YouziExecutionPermissionRecovery
}

/// Pure, fail-closed evaluator used by foreground tasks and scheduled
/// automation. Durable domain authority and the supplied live runtime gate must
/// independently pass before the result is authorized.
struct YouziExecutionPermissionEvaluator: Sendable {
    func evaluate(
        subject: YouziExecutionPermissionSubject,
        requirement: YouziExecutionPermissionRequirement,
        permissionRecords: [YouziPermissionRecord],
        grants: [YouziPermissionGrant],
        connectionAccounts: [YouziConnectionAccount] = [],
        connectorBindings: [YouziConnectorBinding] = [],
        runtime: YouziExecutionPermissionRuntimeGate,
        now: Date
    ) -> YouziExecutionPermissionEvaluation {
        guard isValid(subject), isValid(requirement) else {
            return evaluation(.malformedRequirement)
        }

        let recordsByID = Dictionary(grouping: permissionRecords, by: \.id)
        let duplicateGrantIDs = Set(
            Dictionary(grouping: grants, by: \.id)
                .filter { $0.value.count != 1 }
                .map(\.key)
        )

        let matchingGrants = grants.filter { grant in
            guard !duplicateGrantIDs.contains(grant.id),
                  let records = recordsByID[grant.permissionRecordID],
                  records.count == 1,
                  let record = records.first
            else {
                return false
            }
            return isLiveExactGrant(
                grant,
                from: record,
                for: subject,
                requirement: requirement,
                now: now
            )
        }

        guard !matchingGrants.isEmpty else {
            if hasExactDeniedRequest(
                permissionRecords,
                subject: subject,
                requirement: requirement,
                now: now
            ) {
                return evaluation(.denied)
            }
            return evaluation(.domainPermissionRequired)
        }

        if let accountID = requirement.connectionAccountID {
            let accounts = connectionAccounts.filter { $0.id == accountID }
            guard accounts.count == 1,
                  accounts[0].state == .connected,
                  accounts[0].recoveryCode == nil,
                  runtime.connectionAccountID == accountID
            else {
                return evaluation(.accountUnavailable)
            }

            let bindings = connectorBindings.filter { $0.id == accountID }
            guard bindings.count == 1,
                  bindings[0].configurationRevision > 0,
                  bindings[0].configurationRevision == requirement.targetRevision,
                  bindings[0].recoveryCode == nil,
                  runtime.bindingRevision == bindings[0].configurationRevision
            else {
                return evaluation(.bindingUnavailable)
            }
        }

        guard runtime.toolName == requirement.toolName,
              runtime.capabilityIdentifier == requirement.capabilityIdentifier,
              runtime.runtimeAvailable,
              requirement.connectionAccountID != nil ||
                  (runtime.connectionAccountID == nil && runtime.bindingRevision == nil)
        else {
            return evaluation(.runtimeUnavailable)
        }
        guard runtime.advertisedForTurn else {
            return evaluation(.notAdvertised)
        }
        guard runtime.globallyEnabled else {
            return evaluation(.disabled(.global))
        }
        guard runtime.toolEnabled else {
            return evaluation(.disabled(.tool))
        }

        switch runtime.lowLevelApproval {
        case .awaitingUser:
            return evaluation(.awaitingLowLevelConfirmation)
        case .denied:
            return evaluation(.denied)
        case .unavailable:
            return evaluation(.runtimeUnavailable)
        case .notRequired, .approved:
            break
        }

        let stableMatches = matchingGrants.sorted { lhs, rhs in
            lhs.id.uuidString < rhs.id.uuidString
        }
        let selected = matchingGrants.sorted { lhs, rhs in
            let lhsRank = selectionRank(lhs.duration)
            let rhsRank = selectionRank(rhs.duration)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.id.uuidString < rhs.id.uuidString
        }[0]
        let consumptionIntent: YouziExecutionPermissionConsumptionIntent? =
            selected.duration == .once ? .consumeOnce(grantID: selected.id) : nil

        return evaluation(.authorized(.init(
            matchingGrantIDs: stableMatches.map(\.id),
            selectedGrantID: selected.id,
            permissionRecordID: selected.permissionRecordID,
            consumptionIntent: consumptionIntent
        )))
    }

    private func isValid(_ subject: YouziExecutionPermissionSubject) -> Bool {
        switch subject {
        case .interactiveTask:
            return true
        case let .automation(_, revision):
            return revision > 0
        }
    }

    private func isValid(_ requirement: YouziExecutionPermissionRequirement) -> Bool {
        guard isCanonicalStableIdentifier(requirement.targetIdentifier),
              requirement.targetRevision.map({ $0 > 0 }) ?? true,
              isOptionalCanonicalName(requirement.capabilityIdentifier),
              isOptionalCanonicalName(requirement.toolName)
        else {
            return false
        }

        if let accountID = requirement.connectionAccountID {
            guard requirement.kind == .connectorRead ||
                    requirement.kind == .connectorWrite ||
                    requirement.kind == .externalPublish,
                  requirement.capabilityIdentifier == nil,
                  requirement.targetIdentifier == canonical(accountID),
                  requirement.targetRevision != nil
            else {
                return false
            }
            return true
        }

        switch requirement.kind {
        case .workspaceRead, .workspaceWrite:
            return requirement.targetRevision == nil &&
                requirement.capabilityIdentifier == nil &&
                UUID(uuidString: requirement.targetIdentifier).map { canonical($0) } ==
                    requirement.targetIdentifier
        case .connectorRead, .connectorWrite:
            return false
        case .networkAccess:
            return requirement.targetRevision == nil &&
                requirement.capabilityIdentifier == requirement.targetIdentifier
        case .externalPublish:
            return requirement.targetRevision == nil &&
                requirement.capabilityIdentifier == requirement.targetIdentifier
        case .destructiveLocalAction, .microphone, .saveAudio:
            return requirement.targetRevision == nil &&
                (requirement.capabilityIdentifier == nil ||
                    requirement.capabilityIdentifier == requirement.targetIdentifier)
        }
    }

    private func isOptionalCanonicalName(_ value: String?) -> Bool {
        guard let value else { return true }
        return isCanonicalStableIdentifier(value)
    }

    private func isCanonicalStableIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 256 else { return false }
        return value.utf8.allSatisfy { byte in
            (97...122).contains(byte) ||
                (48...57).contains(byte) ||
                byte == 45 || byte == 46 || byte == 58 || byte == 95
        }
    }

    private func canonical(_ id: UUID) -> String {
        id.uuidString.lowercased()
    }

    private func isLiveExactGrant(
        _ grant: YouziPermissionGrant,
        from record: YouziPermissionRecord,
        for subject: YouziExecutionPermissionSubject,
        requirement: YouziExecutionPermissionRequirement,
        now: Date
    ) -> Bool {
        guard record.id == grant.permissionRecordID,
              record.decision == .allowed,
              record.kind == grant.kind,
              record.targetIdentifier == grant.targetIdentifier,
              record.duration == grant.duration,
              record.kind == requirement.kind,
              record.targetIdentifier == requirement.targetIdentifier,
              grant.targetRevision == requirement.targetRevision,
              record.requestedAt <= now,
              let decidedAt = record.decidedAt,
              record.requestedAt <= decidedAt,
              decidedAt <= grant.grantedAt,
              grant.grantedAt <= now,
              grant.expiresAt.map({ $0 > now && $0 >= grant.grantedAt }) ?? true,
              grant.revokedAt == nil,
              grant.consumedAt == nil,
              isCoherent(record, for: subject),
              isCoherent(grant, for: subject)
        else {
            return false
        }
        return true
    }

    private func isCoherent(
        _ record: YouziPermissionRecord,
        for subject: YouziExecutionPermissionSubject
    ) -> Bool {
        switch subject {
        case let .interactiveTask(taskID):
            return record.taskID == taskID &&
                record.automationID == nil &&
                record.automationRevision == nil &&
                (record.duration == .once || record.duration == .task)
        case let .automation(automationID, revision):
            return record.taskID == nil &&
                record.automationID == automationID &&
                record.automationRevision == revision &&
                record.duration == .persistent
        }
    }

    private func isCoherent(
        _ grant: YouziPermissionGrant,
        for subject: YouziExecutionPermissionSubject
    ) -> Bool {
        switch subject {
        case let .interactiveTask(taskID):
            return grant.taskID == taskID &&
                grant.automationID == nil &&
                grant.automationRevision == nil &&
                (grant.duration == .once || grant.duration == .task)
        case let .automation(automationID, revision):
            return grant.taskID == nil &&
                grant.automationID == automationID &&
                grant.automationRevision == revision &&
                grant.duration == .persistent
        }
    }

    private func hasExactDeniedRequest(
        _ records: [YouziPermissionRecord],
        subject: YouziExecutionPermissionSubject,
        requirement: YouziExecutionPermissionRequirement,
        now: Date
    ) -> Bool {
        records.contains { record in
            (record.decision == .denied || record.decision == .revoked) &&
                record.kind == requirement.kind &&
                record.targetIdentifier == requirement.targetIdentifier &&
                record.requestedAt <= now &&
                record.decidedAt.map({ $0 >= record.requestedAt && $0 <= now }) == true &&
                isCoherent(record, for: subject)
        }
    }

    private func selectionRank(_ duration: YouziPermissionDuration) -> Int {
        switch duration {
        case .task, .persistent: 0
        case .once: 1
        }
    }

    private func evaluation(
        _ outcome: YouziExecutionPermissionOutcome
    ) -> YouziExecutionPermissionEvaluation {
        let recovery: YouziExecutionPermissionRecovery
        switch outcome {
        case .authorized:
            recovery = .none
        case .domainPermissionRequired:
            recovery = .requestDomainPermission
        case .awaitingLowLevelConfirmation:
            recovery = .presentLowLevelConfirmation
        case .denied:
            recovery = .reviewDeniedPermission
        case .disabled(.global):
            recovery = .enableGlobalRuntime
        case .disabled(.tool):
            recovery = .enableTool
        case .notAdvertised:
            recovery = .advertiseTool
        case .accountUnavailable:
            recovery = .reconnectAccount
        case .bindingUnavailable:
            recovery = .repairConnectorBinding
        case .runtimeUnavailable:
            recovery = .restoreRuntime
        case .malformedRequirement:
            recovery = .correctRequirement
        }
        return .init(outcome: outcome, recovery: recovery)
    }
}
