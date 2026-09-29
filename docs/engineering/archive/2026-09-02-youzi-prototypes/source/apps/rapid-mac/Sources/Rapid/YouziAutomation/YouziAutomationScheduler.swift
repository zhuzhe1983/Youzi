import Foundation

// MARK: - Shared canonical task execution boundary

enum YouziTaskExecutionOrigin: Equatable, Sendable {
    case interactive
    case automation(automationID: UUID, revision: Int, runID: UUID)
}

enum YouziTaskExecutionInput: Equatable, Sendable {
    case existingTask(taskID: UUID)
    case automationAction(YouziAutomationAction)
}

/// Immutable input to the one foreground/automation execution coordinator.
/// Permission IDs are a snapshot for validation, never authority by themselves.
struct YouziTaskExecutionRequest: Equatable, Sendable {
    let origin: YouziTaskExecutionOrigin
    let input: YouziTaskExecutionInput
    /// Automation coordinators must restrict their domain authorizer to this
    /// exact run snapshot; other grants in the document are out of scope.
    let permissionGrantIDs: [UUID]
}

enum YouziTaskExecutionPreparation: Equatable, Sendable {
    /// The canonical task, workspace, conversation, and lifecycle records exist.
    case ready(taskID: UUID)
    case awaitingConfirmation(recoveryCode: YouziRecoveryCode)
    case unavailable(recoveryCode: YouziRecoveryCode)
}

/// Bounded display-safe result copy. Detailed transcripts and artifacts remain
/// owned by the canonical coordinator; scheduler audit never stores this text.
struct YouziTaskExecutionSummary: Equatable, Sendable {
    static let maximumCharacters = 400
    let text: String

    init?(_ value: String) {
        let normalized = value
            .components(separatedBy: .controlCharacters)
            .joined(separator: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !normalized.isEmpty else { return nil }
        text = String(normalized.prefix(Self.maximumCharacters))
    }
}

enum YouziTaskExecutionOutcome: Equatable, Sendable {
    case completed(summary: YouziTaskExecutionSummary?)
    case awaitingConfirmation(recoveryCode: YouziRecoveryCode)
    case retryableFailure(recoveryCode: YouziRecoveryCode)
    case failed(recoveryCode: YouziRecoveryCode)
    case cancelled
}

/// Shared production seam. `prepare` must be idempotent for an automation
/// `runID`: a crash after task creation but before run settlement must return
/// the same canonical task rather than creating another one. Neither method
/// may bypass the scoped-turn resolver, permission evaluator, advertised-tool
/// checks, or the existing low-level tool approval/dispatch gates.
@MainActor
protocol YouziTaskExecutionCoordinating: AnyObject, Sendable {
    func prepare(_ request: YouziTaskExecutionRequest) async
        -> YouziTaskExecutionPreparation
    func execute(
        taskID: UUID,
        request: YouziTaskExecutionRequest
    ) async -> YouziTaskExecutionOutcome
    func cancel(taskID: UUID, origin: YouziTaskExecutionOrigin) async
}

// MARK: - Injected time and notification boundaries

protocol YouziAutomationClock: Sendable {
    func now() -> Date
}

struct YouziSystemAutomationClock: YouziAutomationClock {
    func now() -> Date { Date() }
}

protocol YouziAutomationSleeping: Sendable {
    func sleep(until date: Date) async throws
}

struct YouziSystemAutomationSleeper: YouziAutomationSleeping {
    func sleep(until date: Date) async throws {
        let seconds = max(0, date.timeIntervalSinceNow)
        let nanoseconds = UInt64(min(seconds, 365 * 24 * 60 * 60) * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

protocol YouziAutomationNotificationDelivering: Sendable {
    func authorizationState() async -> YouziNotificationAuthorizationState
    func deliver(_ notification: YouziAutomationNotification) async throws
}

extension YouziAutomationNotificationService: YouziAutomationNotificationDelivering {}

// MARK: - Scheduler status

enum YouziAutomationBackgroundContract: String, Equatable, Sendable {
    case runsOnlyWhileYouziIsRunning
}

enum YouziAutomationSchedulerRecovery: Equatable, Sendable {
    case reopenYouzi
    case reviewSchedule(automationID: UUID)
    case reviewPermission(automationID: UUID)
    case reviewRevision(automationID: UUID)
    case retryRuntime(automationID: UUID)
    case enableNotifications
    case inspectRun(runID: UUID)
}

enum YouziAutomationSchedulerIssue: Equatable, Sendable {
    case storageUnavailable
    case scheduleInvalid(automationID: UUID)
    case permissionRequired(automationID: UUID)
    case grantRevoked(automationID: UUID)
    case staleRevision(automationID: UUID, runID: UUID?)
    case interruptedRun(runID: UUID)
    case executionUnavailable(runID: UUID, recoveryCode: YouziRecoveryCode)
    case notificationUnavailable(automationID: UUID)

    var recovery: YouziAutomationSchedulerRecovery {
        switch self {
        case .storageUnavailable:
            return .reopenYouzi
        case .scheduleInvalid(let automationID):
            return .reviewSchedule(automationID: automationID)
        case .permissionRequired(let automationID), .grantRevoked(let automationID):
            return .reviewPermission(automationID: automationID)
        case .staleRevision(let automationID, _):
            return .reviewRevision(automationID: automationID)
        case .interruptedRun(let runID), .executionUnavailable(let runID, _):
            return .inspectRun(runID: runID)
        case .notificationUnavailable:
            return .enableNotifications
        }
    }
}

enum YouziAutomationSchedulerPhase: Equatable, Sendable {
    case stopped
    case reconciling
    case idle(nextWakeAt: Date?)
    case executing(runIDs: [UUID], nextWakeAt: Date?)
    case shuttingDown
    case failed(recovery: YouziAutomationSchedulerRecovery)
}

struct YouziAutomationSchedulerStatus: Equatable, Sendable {
    let backgroundContract: YouziAutomationBackgroundContract
    let phase: YouziAutomationSchedulerPhase
    let issues: [YouziAutomationSchedulerIssue]
}

enum YouziAutomationReconciliationReason: Equatable, Sendable {
    case startup
    case foregroundWake
    case definitionChanged(automationID: UUID?)
    case timerFired(expectedAt: Date)
}

enum YouziAutomationRunNowResult: Equatable, Sendable {
    case started(runID: UUID)
    case alreadyRunning
    case unavailable(YouziAutomationSchedulerRecovery)
}

// MARK: - Scheduler

actor YouziAutomationScheduler {
    private static let maximumRememberedIssues = 32
    private static let maximumRetryDelay: TimeInterval = 60 * 60

    private struct RunPlan: Equatable, Sendable {
        let runID: UUID
        let automationID: UUID
        let revision: Int
        let action: YouziAutomationAction
        let permissionGrantIDs: [UUID]
        let retryPolicy: YouziAutomationRetryPolicy
        let notificationEnabled: Bool
        let automationName: String

        var origin: YouziTaskExecutionOrigin {
            .automation(
                automationID: automationID,
                revision: revision,
                runID: runID
            )
        }

        var request: YouziTaskExecutionRequest {
            YouziTaskExecutionRequest(
                origin: origin,
                input: .automationAction(action),
                permissionGrantIDs: permissionGrantIDs
            )
        }
    }

    private enum PreflightFailure: Equatable {
        case permissionRequired
        case grantRevoked
        case staleRevision
        case unavailable

        var recoveryCode: YouziRecoveryCode {
            switch self {
            case .permissionRequired: return .permissionRequired
            case .grantRevoked: return .grantRevoked
            case .staleRevision: return .automationRevisionChanged
            case .unavailable: return .runtimeUnavailable
            }
        }
    }

    private let repository: YouziAutomationRepository
    private let snapshot: @Sendable () throws -> YouziDomainDocument
    private let scheduleEvaluator: YouziAutomationScheduleEvaluator
    private let clock: any YouziAutomationClock
    private let sleeper: any YouziAutomationSleeping
    private let coordinator: any YouziTaskExecutionCoordinating
    private let notifications: any YouziAutomationNotificationDelivering
    private let auditID: @Sendable () -> UUID

    private var isRunning = false
    private var timerTask: Task<Void, Never>?
    private var nextWakeAt: Date?
    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    private var activeTaskIDs: [UUID: UUID] = [:]
    private var cancellationRequestedRunIDs: Set<UUID> = []
    private var issues: [YouziAutomationSchedulerIssue] = []
    private var phase: YouziAutomationSchedulerPhase = .stopped

    init(
        repository: YouziAutomationRepository,
        snapshot: @escaping @Sendable () throws -> YouziDomainDocument,
        coordinator: any YouziTaskExecutionCoordinating,
        notificationDeliverer: any YouziAutomationNotificationDelivering,
        scheduleEvaluator: YouziAutomationScheduleEvaluator = .init(),
        clock: any YouziAutomationClock = YouziSystemAutomationClock(),
        sleeper: any YouziAutomationSleeping = YouziSystemAutomationSleeper(),
        auditID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.repository = repository
        self.snapshot = snapshot
        self.coordinator = coordinator
        self.notifications = notificationDeliverer
        self.scheduleEvaluator = scheduleEvaluator
        self.clock = clock
        self.sleeper = sleeper
        self.auditID = auditID
    }

    func status() -> YouziAutomationSchedulerStatus {
        YouziAutomationSchedulerStatus(
            backgroundContract: .runsOnlyWhileYouziIsRunning,
            phase: phase,
            issues: issues
        )
    }

    func start() async {
        guard !isRunning else { return }
        isRunning = true
        await reconcile(.startup)
    }

    func foregroundWake() async {
        guard isRunning else { return }
        await reconcile(.foregroundWake)
    }

    func definitionChanged(automationID: UUID? = nil) async {
        guard isRunning else { return }
        await reconcile(.definitionChanged(automationID: automationID))
    }

    func runNow(automationID: UUID) async -> YouziAutomationRunNowResult {
        guard isRunning else { return .unavailable(.reopenYouzi) }
        let now = clock.now()
        do {
            let (run, document) = try repository.claimRunNow(
                automationID: automationID,
                at: now
            )
            guard let plan = makePlan(run: run, document: document) else {
                record(.executionUnavailable(runID: run.id, recoveryCode: .runtimeUnavailable))
                return .unavailable(.inspectRun(runID: run.id))
            }
            launch(plan)
            await armNextWake()
            return .started(runID: run.id)
        } catch YouziAutomationRepositoryError.overlappingRun {
            return .alreadyRunning
        } catch YouziAutomationRepositoryError.automationNotConfirmed,
                YouziAutomationRepositoryError.automationNotFound {
            return .unavailable(.reviewSchedule(automationID: automationID))
        } catch {
            record(.storageUnavailable)
            phase = .failed(recovery: .reopenYouzi)
            return .unavailable(.reopenYouzi)
        }
    }

    func reconcile(_ reason: YouziAutomationReconciliationReason) async {
        guard isRunning else { return }
        phase = .reconciling
        timerTask?.cancel()
        timerTask = nil
        nextWakeAt = nil
        let now = clock.now()

        let initial: YouziDomainDocument
        do {
            initial = try snapshot()
        } catch {
            record(.storageUnavailable)
            phase = .failed(recovery: .reopenYouzi)
            return
        }

        await recoverOrResumeRuns(in: initial, now: now)

        let current: YouziDomainDocument
        do {
            current = try snapshot()
        } catch {
            record(.storageUnavailable)
            phase = .failed(recovery: .reopenYouzi)
            return
        }

        for automation in current.automations.sorted(by: stableIDOrder) {
            await reconcileAutomation(automation, reason: reason, now: now)
        }
        await armNextWake()
    }

    func shutdown() async {
        guard isRunning else { return }
        phase = .shuttingDown
        isRunning = false
        timerTask?.cancel()
        timerTask = nil
        nextWakeAt = nil

        let tasks = Array(activeTasks.values)
        for task in tasks { task.cancel() }
        for (runID, taskID) in activeTaskIDs {
            if let plan = planForRun(runID) {
                await requestCanonicalCancellation(plan: plan, taskID: taskID)
            }
        }
        for task in tasks { await task.value }
        activeTasks.removeAll()
        activeTaskIDs.removeAll()
        phase = .stopped
    }

    /// Test/integration synchronization point; it never waits for the timer.
    func waitForActiveRuns() async {
        while let task = activeTasks.values.first {
            await task.value
        }
    }

    // MARK: Reconciliation

    private func recoverOrResumeRuns(
        in document: YouziDomainDocument,
        now: Date
    ) async {
        for run in document.automationRuns.sorted(by: stableIDOrder) {
            guard activeTasks[run.id] == nil else { continue }
            switch run.status {
            case .running:
                do {
                    _ = try repository.settleRun(
                        id: run.id,
                        expectedStatus: .running,
                        settlement: .failed(
                            taskID: run.taskID,
                            recoveryCode: .runtimeUnavailable,
                            summary: nil
                        ),
                        at: now
                    )
                    record(.interruptedRun(runID: run.id))
                } catch {
                    record(.storageUnavailable)
                }
            case .queued:
                if let plan = makePlan(run: run, document: document) {
                    launch(plan)
                } else {
                    settleUnresumable(run, document: document, at: now)
                }
            case .retryScheduled:
                if makePlan(run: run, document: document) == nil {
                    settleUnresumable(run, document: document, at: now)
                } else if let retryAt = run.nextRetryAt, retryAt <= now,
                          let plan = makePlan(run: run, document: document) {
                    launch(plan)
                }
            case .awaitingConfirmation, .completed, .failed, .cancelled, .skipped:
                break
            }
        }
    }

    private func reconcileAutomation(
        _ automation: YouziAutomation,
        reason: YouziAutomationReconciliationReason,
        now: Date
    ) async {
        guard automation.state == .active, automation.confirmedAt != nil else {
            if automation.nextRunAt != nil {
                persistNextRun(nil, automation: automation, at: now)
            }
            return
        }

        guard case .manual = automation.trigger else {
            let recompute = {
                if case .definitionChanged(let changedID) = reason {
                    return changedID == nil || changedID == automation.id
                }
                return false
            }()
            let occurrence: Date
            do {
                if !recompute, let stored = automation.nextRunAt {
                    occurrence = stored
                } else {
                    let reference = recompute
                        ? now
                        : (automation.lastScheduledFor
                            ?? automation.confirmedAt
                            ?? automation.createdAt)
                    occurrence = try nextOccurrence(for: automation, after: reference)
                }
            } catch {
                markScheduleInvalid(automation, at: now)
                return
            }

            guard occurrence <= now else {
                persistNextRun(occurrence, automation: automation, at: now)
                return
            }

            let isTimerOccurrence: Bool
            if case .timerFired(let expectedAt) = reason {
                isTimerOccurrence = expectedAt == occurrence
            } else {
                isTimerOccurrence = false
            }
            let claimed: Bool
            if isTimerOccurrence || automation.missedRunPolicy == .runOnce {
                claimed = claimScheduled(
                    automation: automation,
                    scheduledFor: occurrence,
                    now: now,
                    shouldExecute: true
                )
            } else {
                claimed = claimScheduled(
                    automation: automation,
                    scheduledFor: occurrence,
                    now: now,
                    shouldExecute: false
                )
            }
            // Never advance past an occurrence that was not durably claimed.
            guard claimed else { return }

            do {
                let next = try nextOccurrence(for: automation, after: now)
                persistNextRun(next, automation: automation, at: now)
            } catch {
                markScheduleInvalid(automation, at: now)
            }
            return
        }

        if automation.nextRunAt != nil {
            persistNextRun(nil, automation: automation, at: now)
        }
    }

    private func claimScheduled(
        automation: YouziAutomation,
        scheduledFor: Date,
        now: Date,
        shouldExecute: Bool
    ) -> Bool {
        do {
            let (run, document) = try repository.claimScheduledRun(
                automationID: automation.id,
                revision: automation.revision,
                scheduledFor: scheduledFor,
                at: now
            )
            guard shouldExecute else {
                if run.status == .queued {
                    _ = try repository.settleRun(
                        id: run.id,
                        expectedStatus: .queued,
                        settlement: .skipped(recoveryCode: nil),
                        at: now
                    )
                }
                return true
            }
            if run.status == .queued, let plan = makePlan(run: run, document: document) {
                launch(plan)
            }
            return true
        } catch YouziAutomationRepositoryError.revisionConflict {
            record(.staleRevision(automationID: automation.id, runID: nil))
            return false
        } catch {
            record(.storageUnavailable)
            return false
        }
    }

    private func settleUnresumable(
        _ run: YouziAutomationRun,
        document: YouziDomainDocument,
        at date: Date
    ) {
        let recoveryCode: YouziRecoveryCode = document.automations.contains(where: {
            $0.id == run.automationID && $0.revision != run.automationRevision
        }) ? .automationRevisionChanged : .runtimeUnavailable
        do {
            switch run.status {
            case .queued:
                _ = try repository.settleRun(
                    id: run.id,
                    expectedStatus: .queued,
                    settlement: .skipped(recoveryCode: recoveryCode),
                    at: date
                )
            case .retryScheduled:
                _ = try repository.settleRun(
                    id: run.id,
                    expectedStatus: .retryScheduled,
                    settlement: .failed(
                        taskID: run.taskID,
                        recoveryCode: recoveryCode,
                        summary: nil
                    ),
                    at: date
                )
            case .running, .awaitingConfirmation, .completed, .failed, .cancelled, .skipped:
                return
            }
            if recoveryCode == .automationRevisionChanged {
                record(.staleRevision(automationID: run.automationID, runID: run.id))
            } else {
                record(.executionUnavailable(runID: run.id, recoveryCode: recoveryCode))
            }
        } catch {
            record(.storageUnavailable)
        }
    }

    private func nextOccurrence(
        for automation: YouziAutomation,
        after date: Date
    ) throws -> Date {
        switch automation.trigger {
        case .manual:
            throw YouziAutomationScheduleError.noOccurrenceWithinHorizon
        case .interval(let seconds, let anchorAt):
            return try scheduleEvaluator.nextInterval(
                after: date,
                seconds: seconds,
                anchorAt: anchorAt
            )
        case .schedule(let expression, let timeZoneIdentifier):
            return try scheduleEvaluator.nextCron(
                after: date,
                expression: expression,
                timeZoneIdentifier: timeZoneIdentifier
            )
        }
    }

    private func persistNextRun(
        _ date: Date?,
        automation: YouziAutomation,
        at now: Date
    ) {
        guard automation.nextRunAt != date else { return }
        do {
            _ = try repository.revise(
                id: automation.id,
                expectedRevision: automation.revision,
                mutation: { $0.nextRunAt = date },
                at: now
            )
        } catch YouziAutomationRepositoryError.revisionConflict {
            record(.staleRevision(automationID: automation.id, runID: nil))
        } catch {
            record(.storageUnavailable)
        }
    }

    private func markScheduleInvalid(_ automation: YouziAutomation, at now: Date) {
        do {
            _ = try repository.revise(
                id: automation.id,
                expectedRevision: automation.revision,
                mutation: {
                    $0.state = .needsAttention
                    $0.confirmedAt = nil
                    $0.nextRunAt = nil
                },
                at: now
            )
            record(.scheduleInvalid(automationID: automation.id))
        } catch {
            record(.storageUnavailable)
        }
    }

    // MARK: Execution

    private func makePlan(
        run: YouziAutomationRun,
        document: YouziDomainDocument
    ) -> RunPlan? {
        guard let automation = document.automations.first(where: {
            $0.id == run.automationID && $0.revision == run.automationRevision
        }) else { return nil }
        return RunPlan(
            runID: run.id,
            automationID: automation.id,
            revision: automation.revision,
            action: automation.action,
            permissionGrantIDs: run.permissionGrantIDs.sorted(by: uuidOrder),
            retryPolicy: run.retryPolicy,
            notificationEnabled: automation.notificationEnabled,
            automationName: automation.name
        )
    }

    private func planForRun(_ runID: UUID) -> RunPlan? {
        guard let document = try? snapshot(),
              let run = document.automationRuns.first(where: { $0.id == runID })
        else { return nil }
        return makePlan(run: run, document: document)
    }

    private func launch(_ plan: RunPlan) {
        guard isRunning, activeTasks[plan.runID] == nil else { return }
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.execute(plan)
        }
        activeTasks[plan.runID] = task
        updatePhase()
    }

    private func execute(_ plan: RunPlan) async {
        defer {
            activeTasks.removeValue(forKey: plan.runID)
            activeTaskIDs.removeValue(forKey: plan.runID)
            cancellationRequestedRunIDs.remove(plan.runID)
            updatePhase()
            Task { [weak self] in await self?.armNextWake() }
        }

        let startingDocument: YouziDomainDocument
        do {
            startingDocument = try snapshot()
        } catch {
            record(.storageUnavailable)
            return
        }
        guard let run = startingDocument.automationRuns.first(where: { $0.id == plan.runID })
        else {
            record(.executionUnavailable(runID: plan.runID, recoveryCode: .runtimeUnavailable))
            return
        }
        if let failure = preflight(plan, run: run, document: startingDocument, at: clock.now()) {
            settlePreflightFailure(failure, plan: plan, run: run, taskID: run.taskID)
            return
        }

        let taskID: UUID
        if run.status == .retryScheduled, let existingTaskID = run.taskID {
            taskID = existingTaskID
        } else if run.status == .queued {
            let preparation = await coordinator.prepare(plan.request)
            if Task.isCancelled || !isRunning {
                if case .ready(let preparedTaskID) = preparation {
                    await requestCanonicalCancellation(plan: plan, taskID: preparedTaskID)
                    settleCancelled(plan: plan, taskID: preparedTaskID)
                } else {
                    settleCancelled(plan: plan, taskID: nil)
                }
                return
            }
            switch preparation {
            case .ready(let preparedTaskID):
                taskID = preparedTaskID
            case .awaitingConfirmation(let recoveryCode):
                settleAwaiting(plan: plan, taskID: nil, recoveryCode: recoveryCode)
                return
            case .unavailable(let recoveryCode):
                settleSkipped(plan: plan, recoveryCode: recoveryCode)
                return
            }
        } else {
            return
        }

        let preparedDocument: YouziDomainDocument
        do {
            preparedDocument = try snapshot()
        } catch {
            record(.storageUnavailable)
            settleSkipped(plan: plan, recoveryCode: .runtimeUnavailable)
            return
        }
        guard preparedDocument.tasks.filter({ $0.id == taskID }).count == 1,
              let preparedRun = preparedDocument.automationRuns.first(where: {
                $0.id == plan.runID
              })
        else {
            settleSkipped(plan: plan, recoveryCode: .runtimeUnavailable)
            return
        }
        if let failure = preflight(
            plan,
            run: preparedRun,
            document: preparedDocument,
            at: clock.now()
        ) {
            settlePreflightFailure(failure, plan: plan, run: preparedRun, taskID: taskID)
            return
        }

        do {
            _ = try repository.settleRun(
                id: plan.runID,
                expectedStatus: preparedRun.status,
                settlement: .running(taskID: taskID),
                at: clock.now()
            )
        } catch {
            record(.storageUnavailable)
            await requestCanonicalCancellation(plan: plan, taskID: taskID)
            return
        }
        activeTaskIDs[plan.runID] = taskID

        guard appendAudit(
            taskID: taskID,
            runID: plan.runID,
            kind: .executionStarted,
            outcome: .allowed,
            recoveryCode: nil
        ) else {
            await requestCanonicalCancellation(plan: plan, taskID: taskID)
            settleFailed(
                plan: plan,
                taskID: taskID,
                recoveryCode: .runtimeUnavailable,
                summary: nil
            )
            return
        }

        let outcome = await coordinator.execute(taskID: taskID, request: plan.request)
        if Task.isCancelled || !isRunning {
            await requestCanonicalCancellation(plan: plan, taskID: taskID)
            settleCancelled(plan: plan, taskID: taskID)
            return
        }
        await settle(outcome, plan: plan, taskID: taskID)
    }

    private func requestCanonicalCancellation(plan: RunPlan, taskID: UUID) async {
        guard cancellationRequestedRunIDs.insert(plan.runID).inserted else { return }
        await coordinator.cancel(taskID: taskID, origin: plan.origin)
    }

    private func preflight(
        _ plan: RunPlan,
        run: YouziAutomationRun,
        document: YouziDomainDocument,
        at date: Date
    ) -> PreflightFailure? {
        guard run.automationID == plan.automationID,
              run.automationRevision == plan.revision,
              run.permissionGrantIDs.sorted(by: uuidOrder) == plan.permissionGrantIDs
        else { return .staleRevision }

        let automations = document.automations.filter { $0.id == plan.automationID }
        guard automations.count == 1, let automation = automations.first else {
            return .unavailable
        }
        let grantsByID = Dictionary(grouping: document.permissionGrants, by: \.id)
        let requestsByID = Dictionary(grouping: document.permissions, by: \.id)
        var currentPermissionRecordIDs = Set<UUID>()
        var currentScopeIsConfirmed = true
        for requestID in automation.permissionRecordIDs {
            guard let requests = requestsByID[requestID], requests.count == 1,
                  let request = requests.first else {
                return .permissionRequired
            }
            if request.automationID == plan.automationID,
               request.automationRevision == plan.revision {
                currentPermissionRecordIDs.insert(request.id)
                if request.decision != .allowed || request.duration != .persistent {
                    currentScopeIsConfirmed = false
                }
            } else {
                guard request.automationID == plan.automationID,
                      request.automationRevision != nil else {
                    return .permissionRequired
                }
                // Rows from other revisions of this automation are immutable
                // history. The exact automation snapshot guard below decides
                // whether the run itself has become stale.
            }
        }
        for grantID in plan.permissionGrantIDs {
            guard let grants = grantsByID[grantID], grants.count == 1,
                  let grant = grants.first,
                  grant.automationID == plan.automationID,
                  grant.automationRevision == plan.revision,
                  grant.duration == .persistent,
                  grant.revokedAt == nil,
                  grant.consumedAt == nil,
                  grant.grantedAt <= date,
                  grant.expiresAt.map({ $0 > date }) ?? true,
                  currentPermissionRecordIDs.contains(grant.permissionRecordID),
                  let requests = requestsByID[grant.permissionRecordID],
                  requests.count == 1,
                  let request = requests.first,
                  request.automationID == plan.automationID,
                  request.automationRevision == plan.revision,
                  request.decision == .allowed,
                  request.duration == .persistent,
                  request.kind == grant.kind,
                  request.targetIdentifier == grant.targetIdentifier
            else { return .grantRevoked }
        }

        guard currentScopeIsConfirmed else { return .permissionRequired }

        guard automation.revision == plan.revision,
              automation.state == .active,
              automation.confirmedAt != nil,
              automation.action == plan.action,
              automation.permissionGrantIDs.sorted(by: uuidOrder) == plan.permissionGrantIDs
        else { return .staleRevision }

        if (!currentPermissionRecordIDs.isEmpty
                || !automation.action.connectionAccountIDs.isEmpty)
            && plan.permissionGrantIDs.isEmpty {
            return .permissionRequired
        }
        let attachedRequestIDs = Set(plan.permissionGrantIDs.compactMap {
            grantsByID[$0]?.first?.permissionRecordID
        })
        if currentPermissionRecordIDs != attachedRequestIDs {
            return .permissionRequired
        }
        return nil
    }

    private func settle(
        _ outcome: YouziTaskExecutionOutcome,
        plan: RunPlan,
        taskID: UUID
    ) async {
        switch outcome {
        case .completed(let summary):
            do {
                _ = try repository.settleRun(
                    id: plan.runID,
                    expectedStatus: .running,
                    settlement: .completed(taskID: taskID, summary: summary?.text),
                    at: clock.now()
                )
                _ = appendAudit(
                    taskID: taskID,
                    runID: plan.runID,
                    kind: .executionCompleted,
                    outcome: .succeeded,
                    recoveryCode: nil
                )
                await deliverNotification(plan: plan, succeeded: true)
            } catch {
                record(.storageUnavailable)
            }
        case .awaitingConfirmation(let recoveryCode):
            settleAwaiting(plan: plan, taskID: taskID, recoveryCode: recoveryCode)
        case .retryableFailure(let recoveryCode):
            scheduleRetryOrFail(
                plan: plan,
                taskID: taskID,
                recoveryCode: recoveryCode
            )
        case .failed(let recoveryCode):
            settleFailed(
                plan: plan,
                taskID: taskID,
                recoveryCode: recoveryCode,
                summary: nil
            )
            await deliverNotification(plan: plan, succeeded: false)
        case .cancelled:
            settleCancelled(plan: plan, taskID: taskID)
        }
    }

    private func scheduleRetryOrFail(
        plan: RunPlan,
        taskID: UUID,
        recoveryCode: YouziRecoveryCode
    ) {
        guard let document = try? snapshot(),
              let run = document.automationRuns.first(where: { $0.id == plan.runID })
        else {
            record(.storageUnavailable)
            return
        }
        guard run.status == .running else { return }
        if run.attemptCount < run.retryPolicy.maximumAttempts {
            let exponent = max(0, run.attemptCount - 1)
            let unbounded = run.retryPolicy.baseDelaySeconds * pow(2, Double(exponent))
            let delay = min(Self.maximumRetryDelay, max(1, unbounded))
            let retryAt = clock.now().addingTimeInterval(delay)
            do {
                _ = try repository.settleRun(
                    id: plan.runID,
                    expectedStatus: .running,
                    settlement: .retryScheduled(
                        nextRetryAt: retryAt,
                        recoveryCode: recoveryCode
                    ),
                    at: clock.now()
                )
            } catch {
                record(.storageUnavailable)
            }
        } else {
            settleFailed(
                plan: plan,
                taskID: taskID,
                recoveryCode: .retryExhausted,
                summary: nil
            )
        }
    }

    private func settlePreflightFailure(
        _ failure: PreflightFailure,
        plan: RunPlan,
        run: YouziAutomationRun,
        taskID: UUID?
    ) {
        switch failure {
        case .permissionRequired:
            record(.permissionRequired(automationID: plan.automationID))
        case .grantRevoked:
            record(.grantRevoked(automationID: plan.automationID))
        case .staleRevision:
            record(.staleRevision(automationID: plan.automationID, runID: plan.runID))
        case .unavailable:
            record(.executionUnavailable(runID: plan.runID, recoveryCode: .runtimeUnavailable))
        }

        do {
            switch run.status {
            case .queued:
                if failure == .permissionRequired || failure == .grantRevoked {
                    _ = try repository.settleRun(
                        id: plan.runID,
                        expectedStatus: .queued,
                        settlement: .awaitingConfirmation(
                            taskID: taskID,
                            recoveryCode: failure.recoveryCode
                        ),
                        at: clock.now()
                    )
                } else {
                    _ = try repository.settleRun(
                        id: plan.runID,
                        expectedStatus: .queued,
                        settlement: .skipped(recoveryCode: failure.recoveryCode),
                        at: clock.now()
                    )
                }
            case .retryScheduled, .running, .awaitingConfirmation:
                _ = try repository.settleRun(
                    id: plan.runID,
                    expectedStatus: run.status,
                    settlement: .failed(
                        taskID: taskID,
                        recoveryCode: failure.recoveryCode,
                        summary: nil
                    ),
                    at: clock.now()
                )
            case .completed, .failed, .cancelled, .skipped:
                break
            }
        } catch {
            record(.storageUnavailable)
        }
    }

    private func settleAwaiting(
        plan: RunPlan,
        taskID: UUID?,
        recoveryCode: YouziRecoveryCode
    ) {
        guard let run = currentRun(plan.runID) else { return }
        do {
            _ = try repository.settleRun(
                id: plan.runID,
                expectedStatus: run.status,
                settlement: .awaitingConfirmation(
                    taskID: taskID,
                    recoveryCode: recoveryCode
                ),
                at: clock.now()
            )
            record(.permissionRequired(automationID: plan.automationID))
            if let taskID {
                _ = appendAudit(
                    taskID: taskID,
                    runID: plan.runID,
                    kind: .permissionChecked,
                    outcome: .denied,
                    recoveryCode: recoveryCode
                )
            }
        } catch {
            record(.storageUnavailable)
        }
    }

    private func settleSkipped(
        plan: RunPlan,
        recoveryCode: YouziRecoveryCode
    ) {
        guard let run = currentRun(plan.runID), run.status == .queued else { return }
        do {
            _ = try repository.settleRun(
                id: plan.runID,
                expectedStatus: .queued,
                settlement: .skipped(recoveryCode: recoveryCode),
                at: clock.now()
            )
            record(.executionUnavailable(runID: plan.runID, recoveryCode: recoveryCode))
        } catch {
            record(.storageUnavailable)
        }
    }

    private func settleFailed(
        plan: RunPlan,
        taskID: UUID?,
        recoveryCode: YouziRecoveryCode,
        summary: String?
    ) {
        guard let run = currentRun(plan.runID) else { return }
        do {
            _ = try repository.settleRun(
                id: plan.runID,
                expectedStatus: run.status,
                settlement: .failed(
                    taskID: taskID,
                    recoveryCode: recoveryCode,
                    summary: summary
                ),
                at: clock.now()
            )
            if let taskID {
                _ = appendAudit(
                    taskID: taskID,
                    runID: plan.runID,
                    kind: .executionFailed,
                    outcome: .failed,
                    recoveryCode: recoveryCode
                )
            }
            record(.executionUnavailable(runID: plan.runID, recoveryCode: recoveryCode))
        } catch {
            record(.storageUnavailable)
        }
    }

    private func settleCancelled(plan: RunPlan, taskID: UUID?) {
        guard let run = currentRun(plan.runID), run.status.isClaimActive else { return }
        do {
            _ = try repository.settleRun(
                id: plan.runID,
                expectedStatus: run.status,
                settlement: .cancelled(taskID: taskID),
                at: clock.now()
            )
            if let taskID {
                _ = appendAudit(
                    taskID: taskID,
                    runID: plan.runID,
                    kind: .executionCancelled,
                    outcome: .cancelled,
                    recoveryCode: nil
                )
            }
        } catch {
            record(.storageUnavailable)
        }
    }

    private func currentRun(_ id: UUID) -> YouziAutomationRun? {
        guard let document = try? snapshot() else { return nil }
        return document.automationRuns.first(where: { $0.id == id })
    }

    // MARK: Audit and notifications

    @discardableResult
    private func appendAudit(
        taskID: UUID,
        runID: UUID,
        kind: YouziExecutionAuditKind,
        outcome: YouziExecutionAuditOutcome,
        recoveryCode: YouziRecoveryCode?
    ) -> Bool {
        do {
            let document = try snapshot()
            let sequence = (document.executionAuditEvents
                .filter { $0.taskID == taskID && $0.automationRunID == runID }
                .map(\.sequence)
                .max() ?? 0) + 1
            _ = try repository.appendAudit(
                YouziExecutionAuditEvent(
                    id: auditID(),
                    sequence: sequence,
                    taskID: taskID,
                    automationRunID: runID,
                    kind: kind,
                    outcome: outcome,
                    recoveryCode: recoveryCode,
                    occurredAt: clock.now()
                )
            )
            return true
        } catch {
            record(.storageUnavailable)
            return false
        }
    }

    private func deliverNotification(plan: RunPlan, succeeded: Bool) async {
        guard plan.notificationEnabled else { return }
        let state = await notifications.authorizationState()
        guard state.canDeliver,
              let notification = YouziAutomationNotification(
                identifier: "youzi.automation.\(plan.runID.uuidString.lowercased())",
                title: plan.automationName,
                body: succeeded
                    ? "Scheduled help finished."
                    : "Scheduled help needs attention."
              )
        else {
            record(.notificationUnavailable(automationID: plan.automationID))
            return
        }
        do {
            try await notifications.deliver(notification)
        } catch {
            record(.notificationUnavailable(automationID: plan.automationID))
        }
    }

    // MARK: Timer and status

    private func armNextWake() async {
        guard isRunning else { return }
        timerTask?.cancel()
        timerTask = nil

        let document: YouziDomainDocument
        do {
            document = try snapshot()
        } catch {
            record(.storageUnavailable)
            phase = .failed(recovery: .reopenYouzi)
            return
        }
        let now = clock.now()
        let scheduleDates = document.automations.compactMap { automation -> Date? in
            guard automation.state == .active, automation.confirmedAt != nil else { return nil }
            return automation.nextRunAt
        }
        let retryDates = document.automationRuns.compactMap { run -> Date? in
            guard run.status == .retryScheduled else { return nil }
            return run.nextRetryAt
        }
        guard let wake = (scheduleDates + retryDates).min() else {
            nextWakeAt = nil
            updatePhase()
            return
        }
        nextWakeAt = wake
        updatePhase()
        guard wake > now else {
            timerTask = Task { [weak self] in
                await self?.timerDidFire(expectedAt: wake)
            }
            return
        }
        let sleeper = self.sleeper
        timerTask = Task { [weak self] in
            do {
                try await sleeper.sleep(until: wake)
                guard !Task.isCancelled else { return }
                await self?.timerDidFire(expectedAt: wake)
            } catch {
                // Cancellation is the normal re-arm/shutdown path.
            }
        }
    }

    private func timerDidFire(expectedAt: Date) async {
        guard isRunning, nextWakeAt == expectedAt else { return }
        timerTask = nil
        nextWakeAt = nil
        await reconcile(.timerFired(expectedAt: expectedAt))
    }

    private func updatePhase() {
        guard isRunning else {
            if phase != .shuttingDown { phase = .stopped }
            return
        }
        let runIDs = activeTasks.keys.sorted(by: uuidOrder)
        phase = runIDs.isEmpty
            ? .idle(nextWakeAt: nextWakeAt)
            : .executing(runIDs: runIDs, nextWakeAt: nextWakeAt)
    }

    private func record(_ issue: YouziAutomationSchedulerIssue) {
        if let index = issues.firstIndex(of: issue) { issues.remove(at: index) }
        issues.append(issue)
        if issues.count > Self.maximumRememberedIssues {
            issues.removeFirst(issues.count - Self.maximumRememberedIssues)
        }
    }
}

private func stableIDOrder<Record: Identifiable>(_ lhs: Record, _ rhs: Record) -> Bool
where Record.ID == UUID {
    uuidOrder(lhs.id, rhs.id)
}

private func uuidOrder(_ lhs: UUID, _ rhs: UUID) -> Bool {
    lhs.uuidString.lowercased() < rhs.uuidString.lowercased()
}
