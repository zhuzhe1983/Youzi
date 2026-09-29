import Foundation

enum YouziAutomationRepositoryError: Error, Equatable, Sendable {
    case automationAlreadyExists(UUID)
    case automationNotFound(UUID)
    case runNotFound(UUID)
    case revisionConflict(expected: Int, actual: Int)
    case statusConflict(expected: YouziAutomationRunStatus, actual: YouziAutomationRunStatus)
    case invalidGrant(UUID)
    case incompletePermissionScope(UUID)
    case automationNotConfirmed(UUID)
    case overlappingRun(UUID)
    case invalidTransition
    case summaryTooLong
    case recordIDConflict(UUID)
    case auditSequenceConflict(expected: Int, actual: Int)
}

enum YouziAutomationRunSettlement: Equatable, Sendable {
    case running(taskID: UUID)
    case awaitingConfirmation(taskID: UUID?, recoveryCode: YouziRecoveryCode)
    case retryScheduled(nextRetryAt: Date, recoveryCode: YouziRecoveryCode)
    case completed(taskID: UUID, summary: String?)
    case failed(taskID: UUID?, recoveryCode: YouziRecoveryCode, summary: String?)
    case cancelled(taskID: UUID?)
    case skipped(recoveryCode: YouziRecoveryCode?)
}

final class YouziAutomationRepository: @unchecked Sendable {
    private let store: YouziDomainStore
    private let idGenerator: @Sendable () -> UUID

    init(
        store: YouziDomainStore = YouziDomainStore(),
        idGenerator: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.store = store
        self.idGenerator = idGenerator
    }

    @discardableResult
    func create(_ draft: YouziAutomation, at date: Date) throws -> YouziDomainDocument {
        try store.update { document in
            guard !document.automations.contains(where: { $0.id == draft.id }) else {
                throw YouziAutomationRepositoryError.automationAlreadyExists(draft.id)
            }
            var draft = draft
            draft.revision = max(1, draft.revision)
            draft.permissionGrantIDs = []
            draft.confirmedAt = nil
            draft.state = .draft
            draft.updatedAt = date
            document.upsert(draft)
        }
    }

    @discardableResult
    func revise(
        id: UUID,
        expectedRevision: Int,
        mutation: (inout YouziAutomation) throws -> Void,
        at date: Date
    ) throws -> YouziDomainDocument {
        try store.update { document in
            guard let index = document.automations.firstIndex(where: { $0.id == id }) else {
                throw YouziAutomationRepositoryError.automationNotFound(id)
            }
            let old = document.automations[index]
            guard old.revision == expectedRevision else {
                throw YouziAutomationRepositoryError.revisionConflict(
                    expected: expectedRevision, actual: old.revision
                )
            }
            var revised = old
            try mutation(&revised)
            revised.revision = old.revision
            let authorityChanged = revised.trigger != old.trigger
                || revised.action != old.action
                || revised.permissionRecordIDs != old.permissionRecordIDs
                || revised.permissionGrantIDs != old.permissionGrantIDs
                || revised.missedRunPolicy != old.missedRunPolicy
                || revised.overlapPolicy != old.overlapPolicy
                || revised.retryPolicy != old.retryPolicy
                || revised.notificationEnabled != old.notificationEnabled
            if authorityChanged {
                let oldGrantIDs = Set(old.permissionGrantIDs)
                for grantIndex in document.permissionGrants.indices
                where oldGrantIDs.contains(document.permissionGrants[grantIndex].id)
                        && document.permissionGrants[grantIndex].revokedAt == nil {
                    document.permissionGrants[grantIndex].revokedAt = date
                }
                revised.revision = old.revision + 1
                revised.permissionGrantIDs = []
                revised.confirmedAt = nil
                revised.state = .needsAttention
            }
            revised.updatedAt = date
            document.automations[index] = revised
        }
    }

    @discardableResult
    func confirm(
        id: UUID,
        expectedRevision: Int,
        grantIDs: [UUID],
        at date: Date
    ) throws -> YouziDomainDocument {
        try store.update { document in
            guard let index = document.automations.firstIndex(where: { $0.id == id }) else {
                throw YouziAutomationRepositoryError.automationNotFound(id)
            }
            guard document.automations[index].revision == expectedRevision else {
                throw YouziAutomationRepositoryError.revisionConflict(
                    expected: expectedRevision,
                    actual: document.automations[index].revision
                )
            }
            let linkedRecords = document.automations[index].permissionRecordIDs.compactMap {
                permissionID in
                document.permissions.first(where: { $0.id == permissionID })
            }
            guard linkedRecords.count == document.automations[index].permissionRecordIDs.count,
                  linkedRecords.allSatisfy({ $0.taskID == nil && $0.automationID == id }) else {
                throw YouziAutomationRepositoryError.incompletePermissionScope(id)
            }
            let currentRecords = linkedRecords.filter {
                $0.automationRevision == expectedRevision
            }
            guard currentRecords.allSatisfy({ $0.decision == .allowed || $0.decision == .revoked }) else {
                throw YouziAutomationRepositoryError.incompletePermissionScope(id)
            }
            let allowedRecordIDs = Set(
                currentRecords.filter { $0.decision == .allowed }.map(\.id)
            )
            let liveCurrentGrants = document.permissionGrants.filter {
                $0.automationID == id
                    && $0.automationRevision == expectedRevision
                    && $0.revokedAt == nil
                    && $0.consumedAt == nil
                    && ($0.expiresAt.map { $0 > date } ?? true)
            }
            let grantsByRecordID = Dictionary(grouping: liveCurrentGrants, by: \.permissionRecordID)
            guard Set(grantsByRecordID.keys) == allowedRecordIDs,
                  grantsByRecordID.values.allSatisfy({ $0.count == 1 }),
                  grantIDs.count == Set(grantIDs).count,
                  Set(grantIDs) == Set(liveCurrentGrants.map(\.id)) else {
                throw YouziAutomationRepositoryError.incompletePermissionScope(id)
            }
            for grantID in grantIDs {
                guard let grant = document.permissionGrants.first(where: { $0.id == grantID }),
                      grant.automationID == id,
                      grant.automationRevision == expectedRevision,
                      grant.duration == .persistent,
                      grant.revokedAt == nil,
                      grant.consumedAt == nil,
                      grant.expiresAt.map({ $0 > date }) ?? true else {
                    throw YouziAutomationRepositoryError.invalidGrant(grantID)
                }
            }
            document.automations[index].permissionGrantIDs = Self.sortedUnique(grantIDs)
            document.automations[index].confirmedAt = date
            document.automations[index].state = .active
            document.automations[index].updatedAt = date
        }
    }

    @discardableResult
    func claimScheduledRun(
        automationID: UUID,
        revision: Int,
        scheduledFor: Date,
        at date: Date
    ) throws -> (YouziAutomationRun, YouziDomainDocument) {
        var claimed: YouziAutomationRun?
        let document = try store.update { document in
            guard let automationIndex = document.automations.firstIndex(
                where: { $0.id == automationID }
            ) else { throw YouziAutomationRepositoryError.automationNotFound(automationID) }
            let automation = document.automations[automationIndex]
            guard automation.revision == revision else {
                throw YouziAutomationRepositoryError.revisionConflict(
                    expected: revision, actual: automation.revision
                )
            }
            guard automation.state == .active, automation.confirmedAt != nil else {
                throw YouziAutomationRepositoryError.automationNotConfirmed(automationID)
            }
            if let existing = document.automationRuns.first(where: {
                $0.automationID == automationID
                    && $0.automationRevision == revision
                    && $0.scheduledFor == scheduledFor
            }) {
                claimed = existing
                return
            }

            let active = document.automationRuns.first {
                $0.automationID == automationID && $0.status.isClaimActive
            }
            let runID = idGenerator()
            guard !document.automationRuns.contains(where: { $0.id == runID }) else {
                throw YouziAutomationRepositoryError.recordIDConflict(runID)
            }
            let run: YouziAutomationRun
            if active != nil {
                run = YouziAutomationRun(
                    id: runID,
                    automationID: automationID,
                    automationRevision: revision,
                    scheduledFor: scheduledFor,
                    permissionGrantIDs: automation.permissionGrantIDs,
                    retryPolicy: automation.retryPolicy,
                    attemptCount: 0,
                    status: .skipped,
                    recoveryCode: .runtimeUnavailable,
                    createdAt: date,
                    startedAt: nil,
                    finishedAt: date
                )
            } else {
                run = YouziAutomationRun(
                    id: runID,
                    automationID: automationID,
                    automationRevision: revision,
                    scheduledFor: scheduledFor,
                    permissionGrantIDs: automation.permissionGrantIDs,
                    retryPolicy: automation.retryPolicy,
                    attemptCount: 0,
                    status: .queued,
                    createdAt: date,
                    startedAt: nil
                )
            }
            document.upsert(run)
            document.automations[automationIndex].lastScheduledFor = scheduledFor
            document.automations[automationIndex].updatedAt = date
            claimed = run
        }
        return (claimed!, document)
    }

    @discardableResult
    func claimRunNow(automationID: UUID, at date: Date) throws
        -> (YouziAutomationRun, YouziDomainDocument)
    {
        var claimed: YouziAutomationRun?
        let document = try store.update { document in
            guard let automation = document.automations.first(where: { $0.id == automationID }) else {
                throw YouziAutomationRepositoryError.automationNotFound(automationID)
            }
            guard automation.state == .active, automation.confirmedAt != nil else {
                throw YouziAutomationRepositoryError.automationNotConfirmed(automationID)
            }
            guard !document.automationRuns.contains(where: {
                $0.automationID == automationID && $0.status.isClaimActive
            }) else { throw YouziAutomationRepositoryError.overlappingRun(automationID) }
            let runID = idGenerator()
            guard !document.automationRuns.contains(where: { $0.id == runID }) else {
                throw YouziAutomationRepositoryError.recordIDConflict(runID)
            }
            let run = YouziAutomationRun(
                id: runID,
                automationID: automationID,
                automationRevision: automation.revision,
                permissionGrantIDs: automation.permissionGrantIDs,
                retryPolicy: automation.retryPolicy,
                attemptCount: 0,
                status: .queued,
                createdAt: date,
                startedAt: nil
            )
            document.upsert(run)
            claimed = run
        }
        return (claimed!, document)
    }

    @discardableResult
    func settleRun(
        id: UUID,
        expectedStatus: YouziAutomationRunStatus,
        settlement: YouziAutomationRunSettlement,
        at date: Date
    ) throws -> YouziDomainDocument {
        try store.update { document in
            guard let runIndex = document.automationRuns.firstIndex(where: { $0.id == id }) else {
                throw YouziAutomationRepositoryError.runNotFound(id)
            }
            guard document.automationRuns[runIndex].status == expectedStatus else {
                throw YouziAutomationRepositoryError.statusConflict(
                    expected: expectedStatus,
                    actual: document.automationRuns[runIndex].status
                )
            }
            var run = document.automationRuns[runIndex]
            switch settlement {
            case let .running(taskID):
                guard expectedStatus == .queued || expectedStatus == .retryScheduled else {
                    throw YouziAutomationRepositoryError.invalidTransition
                }
                run.taskID = taskID
                run.status = .running
                run.attemptCount += 1
                if run.startedAt == nil { run.startedAt = date }
                run.nextRetryAt = nil
                run.recoveryCode = nil

            case let .awaitingConfirmation(taskID, recoveryCode):
                guard expectedStatus == .queued || expectedStatus == .running else {
                    throw YouziAutomationRepositoryError.invalidTransition
                }
                run.taskID = taskID ?? run.taskID
                run.status = .awaitingConfirmation
                run.recoveryCode = recoveryCode

            case let .retryScheduled(nextRetryAt, recoveryCode):
                guard expectedStatus == .running,
                      run.attemptCount < run.retryPolicy.maximumAttempts,
                      nextRetryAt > date else {
                    throw YouziAutomationRepositoryError.invalidTransition
                }
                run.status = .retryScheduled
                run.nextRetryAt = nextRetryAt
                run.recoveryCode = recoveryCode

            case let .completed(taskID, summary):
                try Self.validateSummary(summary)
                guard expectedStatus == .running else {
                    throw YouziAutomationRepositoryError.invalidTransition
                }
                run.taskID = taskID
                run.status = .completed
                run.summary = summary
                run.finishedAt = date
                run.recoveryCode = nil

            case let .failed(taskID, recoveryCode, summary):
                try Self.validateSummary(summary)
                guard expectedStatus == .running || expectedStatus == .awaitingConfirmation
                    || expectedStatus == .retryScheduled else {
                    throw YouziAutomationRepositoryError.invalidTransition
                }
                run.taskID = taskID ?? run.taskID
                run.status = .failed
                run.summary = summary
                run.recoveryCode = recoveryCode
                run.finishedAt = date

            case let .cancelled(taskID):
                guard expectedStatus.isClaimActive else {
                    throw YouziAutomationRepositoryError.invalidTransition
                }
                run.taskID = taskID ?? run.taskID
                run.status = .cancelled
                run.finishedAt = date

            case let .skipped(recoveryCode):
                guard expectedStatus == .queued else {
                    throw YouziAutomationRepositoryError.invalidTransition
                }
                run.status = .skipped
                run.recoveryCode = recoveryCode
                run.finishedAt = date
            }
            document.automationRuns[runIndex] = run
            if run.status == .completed || run.status == .failed || run.status == .cancelled,
               let automationIndex = document.automations.firstIndex(
                where: { $0.id == run.automationID }
               ) {
                document.automations[automationIndex].lastRunAt = date
                document.automations[automationIndex].updatedAt = date
            }
        }
    }

    @discardableResult
    func appendAudit(_ event: YouziExecutionAuditEvent) throws -> YouziDomainDocument {
        try store.update { document in
            guard !document.executionAuditEvents.contains(where: { $0.id == event.id }) else {
                throw YouziAutomationRepositoryError.recordIDConflict(event.id)
            }
            let previous = document.executionAuditEvents.filter {
                $0.taskID == event.taskID && $0.automationRunID == event.automationRunID
            }.map(\.sequence).max() ?? 0
            let expected = previous + 1
            guard event.sequence == expected else {
                throw YouziAutomationRepositoryError.auditSequenceConflict(
                    expected: expected, actual: event.sequence
                )
            }
            document.upsert(event)
        }
    }

    private static func sortedUnique(_ ids: [UUID]) -> [UUID] {
        Array(Set(ids)).sorted { $0.uuidString.lowercased() < $1.uuidString.lowercased() }
    }

    private static func validateSummary(_ summary: String?) throws {
        if let summary, summary.count > 500 {
            throw YouziAutomationRepositoryError.summaryTooLong
        }
    }
}

extension YouziAutomationRunStatus {
    var isClaimActive: Bool {
        switch self {
        case .queued, .running, .awaitingConfirmation, .retryScheduled: true
        case .completed, .failed, .cancelled, .skipped: false
        }
    }
}
