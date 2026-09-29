import Foundation
import Observation

/// A permission row shown in the final automation confirmation. It contains
/// stable domain identifiers and purpose copy only; connector configuration,
/// paths, credentials, and tool arguments never enter this UI model.
struct YouziAutomationPermissionDraft: Identifiable, Equatable, Sendable {
    let kind: YouziPermissionKind
    let targetIdentifier: String
    let purpose: String

    var id: String {
        "\(kind.rawValue)|\(targetIdentifier)|\(purpose)"
    }
}

/// Complete editor value passed across the Simple Mode/controller boundary.
/// The domain record remains authoritative after this value is saved.
struct YouziAutomationDefinitionDraft: Equatable, Sendable {
    var automationID: UUID?
    var name: String
    var trigger: YouziAutomationTrigger
    var action: YouziAutomationAction
    var permissions: [YouziAutomationPermissionDraft]
    var missedRunPolicy: YouziAutomationMissedRunPolicy
    var retryPolicy: YouziAutomationRetryPolicy
    var notificationEnabled: Bool

    init(
        automationID: UUID? = nil,
        name: String,
        trigger: YouziAutomationTrigger,
        action: YouziAutomationAction,
        permissions: [YouziAutomationPermissionDraft] = [],
        missedRunPolicy: YouziAutomationMissedRunPolicy = .runOnce,
        retryPolicy: YouziAutomationRetryPolicy = .init(),
        notificationEnabled: Bool = true
    ) {
        self.automationID = automationID
        self.name = name
        self.trigger = trigger
        self.action = action
        self.permissions = permissions
        self.missedRunPolicy = missedRunPolicy
        self.retryPolicy = retryPolicy
        self.notificationEnabled = notificationEnabled
    }
}

enum YouziAutomationCenterError: Error, Equatable, Sendable {
    case invalidName
    case invalidRequest
    case invalidSchedule
    case invalidPermissionSnapshot
    case definitionChanged
    case permissionRequired
    case storageUnavailable
    case automationUnavailable
    case alreadyRunning
    case runtimeUnavailable
    case notificationUnavailable
}

enum YouziAutomationCenterNotice: Equatable, Sendable {
    case saved(automationID: UUID)
    case permissionDenied(automationID: UUID)
    case runStarted(runID: UUID)
    case paused(automationID: UUID)
    case resumed(automationID: UUID)
    case archived(automationID: UUID)
}

protocol YouziAutomationNotificationAuthorizing: Sendable {
    func requestAuthorization() async throws -> YouziNotificationAuthorizationState
}

extension YouziAutomationNotificationService: YouziAutomationNotificationAuthorizing {}

/// The one app-owned Simple Mode automation controller. It composes
/// repositories and the scheduler over the exact `YouziDomainStore` also used
/// by `YouziProductModel`; views never construct their own store or runner.
@MainActor
@Observable
final class YouziAutomationCenter {
    private(set) var schedulerStatus = YouziAutomationSchedulerStatus(
        backgroundContract: .runsOnlyWhileYouziIsRunning,
        phase: .stopped,
        issues: []
    )
    private(set) var notificationAuthorization: YouziNotificationAuthorizationState = .notDetermined
    private(set) var lastError: YouziAutomationCenterError?
    private(set) var lastNotice: YouziAutomationCenterNotice?
    private(set) var isWorking = false

    @ObservationIgnored private let store: YouziDomainStore
    @ObservationIgnored private let productModel: YouziProductModel
    @ObservationIgnored private let repository: YouziAutomationRepository
    @ObservationIgnored private let permissions: YouziPermissionRepository
    @ObservationIgnored private let scheduler: YouziAutomationScheduler
    @ObservationIgnored private let notifications: any YouziAutomationNotificationDelivering
    @ObservationIgnored private let notificationAuthorizer: (any YouziAutomationNotificationAuthorizing)?
    @ObservationIgnored private let scheduleEvaluator: YouziAutomationScheduleEvaluator
    @ObservationIgnored private let clock: any YouziAutomationClock
    @ObservationIgnored private let idGenerator: @Sendable () -> UUID
    @ObservationIgnored private var shutdownTask: Task<Void, Never>?

    init(
        store: YouziDomainStore,
        productModel: YouziProductModel,
        coordinator: any YouziTaskExecutionCoordinating,
        notificationDeliverer: any YouziAutomationNotificationDelivering,
        notificationAuthorizer: (any YouziAutomationNotificationAuthorizing)? = nil,
        scheduleEvaluator: YouziAutomationScheduleEvaluator = .init(),
        clock: any YouziAutomationClock = YouziSystemAutomationClock(),
        sleeper: any YouziAutomationSleeping = YouziSystemAutomationSleeper(),
        idGenerator: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.store = store
        self.productModel = productModel
        self.repository = YouziAutomationRepository(store: store, idGenerator: idGenerator)
        self.permissions = YouziPermissionRepository(store: store, idGenerator: idGenerator)
        self.notifications = notificationDeliverer
        self.notificationAuthorizer = notificationAuthorizer
        self.scheduleEvaluator = scheduleEvaluator
        self.clock = clock
        self.idGenerator = idGenerator
        self.scheduler = YouziAutomationScheduler(
            repository: YouziAutomationRepository(store: store, idGenerator: idGenerator),
            snapshot: { try store.load() },
            coordinator: coordinator,
            notificationDeliverer: notificationDeliverer,
            scheduleEvaluator: scheduleEvaluator,
            clock: clock,
            sleeper: sleeper,
            auditID: idGenerator
        )
    }

    convenience init(
        store: YouziDomainStore,
        productModel: YouziProductModel,
        coordinator: any YouziTaskExecutionCoordinating,
        notificationService: YouziAutomationNotificationService = .init()
    ) {
        self.init(
            store: store,
            productModel: productModel,
            coordinator: coordinator,
            notificationDeliverer: notificationService,
            notificationAuthorizer: notificationService
        )
    }

    func start() async {
        shutdownTask?.cancel()
        shutdownTask = nil
        await scheduler.start()
        await refreshRuntimeState()
    }

    func foregroundWake() async {
        await scheduler.foregroundWake()
        refreshDocument()
        schedulerStatus = await scheduler.status()
    }

    func shutdown() async {
        await scheduler.shutdown()
        schedulerStatus = await scheduler.status()
    }

    /// AppKit's termination hook is synchronous and must never block the main
    /// actor while the canonical coordinator is cancelling. This starts the
    /// orderly async shutdown; process termination remains the final backstop.
    func requestShutdownForTermination() {
        guard shutdownTask == nil else { return }
        shutdownTask = Task { [weak self] in
            guard let self else { return }
            await self.shutdown()
        }
    }

    func clearFeedback() {
        lastError = nil
        lastNotice = nil
    }

    func refresh() async {
        refreshDocument()
        await refreshRuntimeState()
    }

    @discardableResult
    func saveAndDecide(
        _ draft: YouziAutomationDefinitionDraft,
        decision: YouziPermissionDecision
    ) async -> UUID? {
        guard decision == .allowed || decision == .denied else {
            lastError = .permissionRequired
            return nil
        }
        guard !isWorking else { return nil }
        isWorking = true
        lastError = nil
        lastNotice = nil
        defer { isWorking = false }

        do {
            let normalized = try validated(draft)
            let persisted = try persistDefinition(normalized)
            let automation = persisted.automation
            let requiresConfirmation = persisted.requiresConfirmation
            if requiresConfirmation {
                let requestIDs: [UUID]
                if let permissionRecordIDs = persisted.permissionRecordIDs {
                    requestIDs = permissionRecordIDs
                } else {
                    let prepared = try permissions.preparePermissionRequests(
                        automationID: automation.id,
                        expectedRevision: automation.revision,
                        requests: permissionRequests(
                            normalized.permissions,
                            automationID: automation.id,
                            revision: automation.revision,
                            at: clock.now()
                        )
                    )
                    requestIDs = prepared.permissionRecordIDs
                }
                let decided = try permissions.decideForAutomation(
                    automationID: automation.id,
                    expectedRevision: automation.revision,
                    requestIDs: requestIDs,
                    decision: decision,
                    at: clock.now()
                )
                if decision == .allowed {
                    _ = try repository.confirm(
                        id: automation.id,
                        expectedRevision: automation.revision,
                        grantIDs: decided.grants.map(\.id),
                        at: clock.now()
                    )
                    lastNotice = .saved(automationID: automation.id)
                } else {
                    lastNotice = .permissionDenied(automationID: automation.id)
                }
            } else {
                lastNotice = .saved(automationID: automation.id)
            }
            refreshDocument()
            await scheduler.definitionChanged(automationID: automation.id)
            schedulerStatus = await scheduler.status()
            return automation.id
        } catch {
            lastError = Self.map(error)
            refreshDocument()
            return nil
        }
    }

    func pause(automationID: UUID) async {
        await changeState(automationID: automationID, to: .paused, notice: .paused(automationID: automationID))
    }

    func resume(automationID: UUID) async {
        guard let automation = productModel.scheduledAutomations.first(where: { $0.id == automationID }),
              automation.confirmedAt != nil,
              !automation.permissionGrantIDs.isEmpty || automation.permissionRecordIDs.isEmpty else {
            lastError = .permissionRequired
            return
        }
        await changeState(automationID: automationID, to: .active, notice: .resumed(automationID: automationID))
    }

    func archive(automationID: UUID) async {
        await changeState(automationID: automationID, to: .archived, notice: .archived(automationID: automationID))
    }

    func runNow(automationID: UUID) async {
        lastError = nil
        lastNotice = nil
        let result = await scheduler.runNow(automationID: automationID)
        switch result {
        case .started(let runID):
            lastNotice = .runStarted(runID: runID)
        case .alreadyRunning:
            lastError = .alreadyRunning
        case .unavailable(let recovery):
            lastError = Self.map(recovery)
        }
        refreshDocument()
        schedulerStatus = await scheduler.status()
    }

    func requestNotificationAuthorization() async {
        guard let notificationAuthorizer else {
            notificationAuthorization = await notifications.authorizationState()
            if !notificationAuthorization.canDeliver {
                lastError = .notificationUnavailable
            }
            return
        }
        do {
            notificationAuthorization = try await notificationAuthorizer.requestAuthorization()
            if !notificationAuthorization.canDeliver {
                lastError = .notificationUnavailable
            }
        } catch {
            lastError = .notificationUnavailable
        }
    }

    func permissionDrafts(for automation: YouziAutomation) -> [YouziAutomationPermissionDraft] {
        let ids = Set(automation.permissionRecordIDs)
        return productModel.permissionRecords
            .filter {
                ids.contains($0.id)
                    && $0.automationID == automation.id
                    && $0.automationRevision == automation.revision
            }
            .map {
                YouziAutomationPermissionDraft(
                    kind: $0.kind,
                    targetIdentifier: $0.targetIdentifier,
                    purpose: $0.purpose
                )
            }
            .sorted { $0.id < $1.id }
    }

    private struct PersistedDefinition {
        let automation: YouziAutomation
        let permissionRecordIDs: [UUID]?
        let requiresConfirmation: Bool
    }

    private func persistDefinition(
        _ draft: YouziAutomationDefinitionDraft
    ) throws -> PersistedDefinition {
        let now = clock.now()
        if let id = draft.automationID {
            let document = try store.load()
            guard let old = document.automations.first(where: { $0.id == id }) else {
                throw YouziAutomationRepositoryError.automationNotFound(id)
            }
            let otherAuthorityChanged = old.trigger != draft.trigger
                || old.action != draft.action
                || old.missedRunPolicy != draft.missedRunPolicy
                || old.retryPolicy != draft.retryPolicy
                || old.notificationEnabled != draft.notificationEnabled
            let updated = try repository.revise(
                id: id,
                expectedRevision: old.revision,
                mutation: { automation in
                    automation.name = draft.name
                    automation.trigger = draft.trigger
                    automation.action = draft.action
                    automation.missedRunPolicy = draft.missedRunPolicy
                    automation.retryPolicy = draft.retryPolicy
                    automation.notificationEnabled = draft.notificationEnabled
                },
                at: now
            )
            guard let revised = updated.automations.first(where: { $0.id == id }) else {
                throw YouziAutomationRepositoryError.automationNotFound(id)
            }
            let scope = try permissions.revisePermissionScope(
                automationID: id,
                expectedRevision: revised.revision,
                requests: permissionRequests(
                    draft.permissions,
                    automationID: id,
                    revision: revised.revision,
                    at: now
                ),
                at: now
            )
            guard let automation = scope.document.automations.first(where: { $0.id == id }) else {
                throw YouziAutomationRepositoryError.automationNotFound(id)
            }
            let requiresConfirmation = otherAuthorityChanged || scope.didChange
                || automation.confirmedAt == nil
                || automation.state == .draft
                || automation.state == .needsAttention
            return PersistedDefinition(
                automation: automation,
                permissionRecordIDs: scope.permissionRecordIDs,
                requiresConfirmation: requiresConfirmation
            )
        }

        let id = idGenerator()
        let automation = YouziAutomation(
            id: id,
            name: draft.name,
            trigger: draft.trigger,
            action: draft.action,
            missedRunPolicy: draft.missedRunPolicy,
            retryPolicy: draft.retryPolicy,
            notificationEnabled: draft.notificationEnabled,
            state: .draft,
            confirmedAt: nil,
            createdAt: now,
            updatedAt: now
        )
        let document = try repository.create(automation, at: now)
        guard let created = document.automations.first(where: { $0.id == id }) else {
            throw YouziAutomationRepositoryError.automationNotFound(id)
        }
        return PersistedDefinition(
            automation: created,
            permissionRecordIDs: nil,
            requiresConfirmation: true
        )
    }

    private func permissionRequests(
        _ drafts: [YouziAutomationPermissionDraft],
        automationID: UUID,
        revision: Int,
        at date: Date
    ) -> [YouziPermissionRecord] {
        drafts.map {
            YouziPermissionRecord(
                id: idGenerator(),
                automationID: automationID,
                automationRevision: revision,
                kind: $0.kind,
                targetIdentifier: $0.targetIdentifier,
                purpose: $0.purpose,
                duration: .persistent,
                requestedAt: date
            )
        }
    }

    private func changeState(
        automationID: UUID,
        to state: YouziAutomationState,
        notice: YouziAutomationCenterNotice
    ) async {
        lastError = nil
        lastNotice = nil
        do {
            let document = try store.load()
            guard let automation = document.automations.first(where: { $0.id == automationID }) else {
                throw YouziAutomationRepositoryError.automationNotFound(automationID)
            }
            _ = try repository.revise(
                id: automationID,
                expectedRevision: automation.revision,
                mutation: {
                    $0.state = state
                    if state != .active { $0.nextRunAt = nil }
                },
                at: clock.now()
            )
            lastNotice = notice
            refreshDocument()
            await scheduler.definitionChanged(automationID: automationID)
            schedulerStatus = await scheduler.status()
        } catch {
            lastError = Self.map(error)
            refreshDocument()
        }
    }

    private func validated(
        _ draft: YouziAutomationDefinitionDraft
    ) throws -> YouziAutomationDefinitionDraft {
        var normalized = draft
        normalized.name = Self.normalizedText(draft.name)
        normalized.action.request = Self.normalizedText(draft.action.request)
        guard !normalized.name.isEmpty else { throw YouziAutomationCenterError.invalidName }
        guard !normalized.action.request.isEmpty else { throw YouziAutomationCenterError.invalidRequest }
        switch normalized.trigger {
        case .manual:
            break
        case .interval(let seconds, _):
            try scheduleEvaluator.validateInterval(seconds)
        case .schedule(let expression, let timeZoneIdentifier):
            _ = try scheduleEvaluator.nextCron(
                after: clock.now(),
                expression: expression,
                timeZoneIdentifier: timeZoneIdentifier
            )
        }
        guard normalized.retryPolicy.maximumAttempts >= 1,
              normalized.retryPolicy.maximumAttempts <= 4,
              normalized.retryPolicy.baseDelaySeconds >= 1,
              normalized.retryPolicy.baseDelaySeconds <= 3_600 else {
            throw YouziAutomationCenterError.invalidSchedule
        }
        let uniquePermissions = Dictionary(
            normalized.permissions.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        ).values.sorted { $0.id < $1.id }
        guard uniquePermissions.allSatisfy({
            !$0.targetIdentifier.isEmpty && !$0.purpose.isEmpty
        }) else {
            throw YouziAutomationCenterError.invalidPermissionSnapshot
        }
        normalized.permissions = uniquePermissions
        normalized.action.skillIDs = Self.sortedUnique(normalized.action.skillIDs)
        normalized.action.connectionAccountIDs = Self.sortedUnique(
            normalized.action.connectionAccountIDs
        )
        return normalized
    }

    private func permissionDrafts(
        in document: YouziDomainDocument,
        automation: YouziAutomation
    ) -> [YouziAutomationPermissionDraft] {
        let ids = Set(automation.permissionRecordIDs)
        return document.permissions
            .filter {
                ids.contains($0.id)
                    && $0.automationID == automation.id
                    && $0.automationRevision == automation.revision
            }
            .map {
                .init(kind: $0.kind, targetIdentifier: $0.targetIdentifier, purpose: $0.purpose)
            }
            .sorted { $0.id < $1.id }
    }

    private func refreshDocument() {
        productModel.refresh()
        if productModel.lastPersistenceError != nil {
            lastError = .storageUnavailable
        }
    }

    private func refreshRuntimeState() async {
        schedulerStatus = await scheduler.status()
        notificationAuthorization = await notifications.authorizationState()
    }

    private static func normalizedText(_ value: String) -> String {
        value
            .components(separatedBy: .controlCharacters)
            .joined(separator: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func sortedUnique(_ values: [UUID]) -> [UUID] {
        Array(Set(values)).sorted { $0.uuidString.lowercased() < $1.uuidString.lowercased() }
    }

    private static func map(_ error: Error) -> YouziAutomationCenterError {
        if let error = error as? YouziAutomationCenterError { return error }
        if error is YouziAutomationScheduleError { return .invalidSchedule }
        if let error = error as? YouziAutomationRepositoryError {
            switch error {
            case .automationNotFound, .runNotFound:
                return .automationUnavailable
            case .revisionConflict:
                return .definitionChanged
            case .automationNotConfirmed, .invalidGrant:
                return .permissionRequired
            case .overlappingRun:
                return .alreadyRunning
            default:
                return .storageUnavailable
            }
        }
        if let error = error as? YouziPermissionRepositoryError {
            switch error {
            case .automationNotFound:
                return .automationUnavailable
            case .automationRevisionConflict, .authorityRevisionRequired:
                return .definitionChanged
            case .invalidAutomationRequestDuration, .requestAutomationMismatch,
                    .invalidGrantSubject, .requestNotLinkedToAutomation:
                return .invalidPermissionSnapshot
            default:
                return .storageUnavailable
            }
        }
        return .storageUnavailable
    }

    private static func map(
        _ recovery: YouziAutomationSchedulerRecovery
    ) -> YouziAutomationCenterError {
        switch recovery {
        case .reviewPermission:
            return .permissionRequired
        case .reviewRevision:
            return .definitionChanged
        case .enableNotifications:
            return .notificationUnavailable
        case .reviewSchedule:
            return .invalidSchedule
        case .reopenYouzi, .retryRuntime, .inspectRun:
            return .runtimeUnavailable
        }
    }
}
