import Foundation
import Testing
@testable import Rapid

@MainActor
@Suite("Youzi automation scheduler — deterministic app-resident execution")
struct YouziAutomationSchedulerTests {
    private let iso = ISO8601DateFormatter()

    private func date(_ value: String) -> Date {
        iso.date(from: value)!
    }

    @Test("Startup runs one missed anchored interval and restart cannot duplicate it")
    func missedRunOnceAndRestartDeduplication() async throws {
        let runID = UUID()
        let taskID = UUID()
        let fixture = try StoreFixture(runIDs: [runID])
        defer { fixture.cleanup() }
        let anchor = date("2026-01-01T00:00:00Z")
        let now = date("2026-01-01T00:20:00Z")
        let action = YouziAutomationAction(
            request: "prepare the anchored report",
            skillIDs: [],
            connectionAccountIDs: []
        )
        let automation = makeAutomation(
            trigger: .interval(seconds: 600, anchorAt: anchor),
            action: action,
            confirmedAt: anchor,
            nextRunAt: date("2026-01-01T00:10:00Z"),
            notificationEnabled: false
        )
        try fixture.store.save(YouziDomainDocument(automations: [automation]))

        let clock = ManualClock(now)
        let coordinator = TestExecutionCoordinator(store: fixture.store, taskIDs: [taskID])
        let scheduler = fixture.scheduler(clock: clock, coordinator: coordinator)
        await scheduler.start()
        await scheduler.waitForActiveRuns()

        var document = try fixture.store.load()
        let run = try #require(document.automationRuns.first)
        #expect(run.id == runID)
        #expect(run.scheduledFor == date("2026-01-01T00:10:00Z"))
        #expect(run.status == .completed)
        #expect(run.taskID == taskID)
        #expect(document.automations[0].nextRunAt == date("2026-01-01T00:30:00Z"))
        #expect(coordinator.executeRequests.count == 1)
        #expect(coordinator.executeRequests[0].input == .automationAction(action))
        await scheduler.shutdown()

        let restartCoordinator = TestExecutionCoordinator(store: fixture.store, taskIDs: [])
        let restarted = fixture.scheduler(clock: clock, coordinator: restartCoordinator)
        await restarted.start()
        await restarted.waitForActiveRuns()
        document = try fixture.store.load()
        #expect(document.automationRuns.count == 1)
        #expect(restartCoordinator.prepareRequests.isEmpty)
        #expect(restartCoordinator.executeRequests.isEmpty)
        await restarted.shutdown()
    }

    @Test("Missed skip records the occurrence without invoking shared execution")
    func missedSkip() async throws {
        let runID = UUID()
        let fixture = try StoreFixture(runIDs: [runID])
        defer { fixture.cleanup() }
        let anchor = date("2026-01-01T00:00:00Z")
        let now = date("2026-01-01T00:20:00Z")
        let automation = makeAutomation(
            trigger: .interval(seconds: 600, anchorAt: anchor),
            confirmedAt: anchor,
            nextRunAt: date("2026-01-01T00:10:00Z"),
            missedRunPolicy: .skip,
            notificationEnabled: false
        )
        try fixture.store.save(YouziDomainDocument(automations: [automation]))
        let coordinator = TestExecutionCoordinator(store: fixture.store, taskIDs: [])
        let scheduler = fixture.scheduler(clock: ManualClock(now), coordinator: coordinator)

        await scheduler.start()
        await scheduler.waitForActiveRuns()

        let document = try fixture.store.load()
        #expect(document.automationRuns.count == 1)
        #expect(document.automationRuns[0].id == runID)
        #expect(document.automationRuns[0].status == .skipped)
        #expect(document.automationRuns[0].attemptCount == 0)
        #expect(document.automations[0].nextRunAt == date("2026-01-01T00:30:00Z"))
        #expect(coordinator.prepareRequests.isEmpty)
        #expect(coordinator.executeRequests.isEmpty)
        await scheduler.shutdown()
    }

    @Test("Cron reconciliation preserves time zone and DST gap semantics")
    func cronDSTGap() async throws {
        let fixture = try StoreFixture(runIDs: [])
        defer { fixture.cleanup() }
        let now = date("2025-03-09T08:00:00Z")
        let automation = makeAutomation(
            trigger: .schedule(
                cronExpression: "30 2 * * *",
                timeZoneIdentifier: "America/Los_Angeles"
            ),
            confirmedAt: now,
            nextRunAt: nil,
            notificationEnabled: false
        )
        try fixture.store.save(YouziDomainDocument(automations: [automation]))
        let coordinator = TestExecutionCoordinator(store: fixture.store, taskIDs: [])
        let scheduler = fixture.scheduler(clock: ManualClock(now), coordinator: coordinator)

        await scheduler.start()

        let document = try fixture.store.load()
        #expect(document.automations[0].nextRunAt == date("2025-03-10T09:30:00Z"))
        #expect(document.automationRuns.isEmpty)
        #expect(coordinator.executeRequests.isEmpty)
        let status = await scheduler.status()
        #expect(status.phase == .idle(nextWakeAt: date("2025-03-10T09:30:00Z")))
        await scheduler.shutdown()
    }

    @Test("Retry backoff is deterministic and maximum attempts fail with a bounded code")
    func retryExhaustion() async throws {
        let runID = UUID()
        let taskID = UUID()
        let fixture = try StoreFixture(runIDs: [runID])
        defer { fixture.cleanup() }
        let now = date("2026-02-01T12:00:00Z")
        let automation = makeAutomation(
            trigger: .manual,
            confirmedAt: now,
            retryPolicy: .init(maximumAttempts: 4, baseDelaySeconds: 10),
            notificationEnabled: false
        )
        try fixture.store.save(YouziDomainDocument(automations: [automation]))
        let clock = ManualClock(now)
        let coordinator = TestExecutionCoordinator(
            store: fixture.store,
            taskIDs: [taskID],
            outcomes: [
                .retryableFailure(recoveryCode: .connectorUnavailable),
                .retryableFailure(recoveryCode: .connectorUnavailable),
                .retryableFailure(recoveryCode: .connectorUnavailable),
                .retryableFailure(recoveryCode: .connectorUnavailable),
            ]
        )
        let scheduler = fixture.scheduler(clock: clock, coordinator: coordinator)
        await scheduler.start()

        #expect(await scheduler.runNow(automationID: automation.id) == .started(runID: runID))
        await scheduler.waitForActiveRuns()
        var document = try fixture.store.load()
        #expect(document.automationRuns[0].status == .retryScheduled)
        #expect(document.automationRuns[0].attemptCount == 1)
        #expect(document.automationRuns[0].nextRetryAt == now.addingTimeInterval(10))

        clock.set(now.addingTimeInterval(10))
        await scheduler.foregroundWake()
        await scheduler.waitForActiveRuns()
        document = try fixture.store.load()
        #expect(document.automationRuns[0].status == .retryScheduled)
        #expect(document.automationRuns[0].attemptCount == 2)
        #expect(document.automationRuns[0].nextRetryAt == now.addingTimeInterval(30))

        clock.set(now.addingTimeInterval(30))
        await scheduler.foregroundWake()
        await scheduler.waitForActiveRuns()
        document = try fixture.store.load()
        #expect(document.automationRuns[0].status == .retryScheduled)
        #expect(document.automationRuns[0].attemptCount == 3)
        #expect(document.automationRuns[0].nextRetryAt == now.addingTimeInterval(70))

        clock.set(now.addingTimeInterval(70))
        await scheduler.foregroundWake()
        await scheduler.waitForActiveRuns()
        document = try fixture.store.load()
        #expect(document.automationRuns[0].status == .failed)
        #expect(document.automationRuns[0].attemptCount == 4)
        #expect(document.automationRuns[0].recoveryCode == .retryExhausted)
        #expect(document.automationRuns[0].nextRetryAt == nil)
        #expect(coordinator.prepareRequests.count == 1)
        #expect(coordinator.executeRequests.count == 4)
        #expect(Set(document.executionAuditEvents.map(\.kind))
            == Set([.executionStarted, .executionFailed]))
        await scheduler.shutdown()
    }

    @Test("A grant revoked after prepare fails closed before canonical execution")
    func revokedGrantAfterPrepare() async throws {
        let runID = UUID()
        let taskID = UUID()
        let fixture = try StoreFixture(runIDs: [runID])
        defer { fixture.cleanup() }
        let now = date("2026-03-01T09:00:00Z")
        let automationID = UUID()
        let permissionID = UUID()
        let grantID = UUID()
        let permission = YouziPermissionRecord(
            id: permissionID,
            automationID: automationID,
            automationRevision: 1,
            kind: .networkAccess,
            targetIdentifier: "api.example.test",
            purpose: "Scheduled lookup",
            duration: .persistent,
            decision: .allowed,
            requestedAt: now.addingTimeInterval(-10),
            decidedAt: now.addingTimeInterval(-9)
        )
        let grant = YouziPermissionGrant(
            id: grantID,
            permissionRecordID: permissionID,
            automationID: automationID,
            automationRevision: 1,
            kind: .networkAccess,
            targetIdentifier: "api.example.test",
            duration: .persistent,
            grantedAt: now.addingTimeInterval(-9)
        )
        let action = YouziAutomationAction(
            request: "use the exact authorized lookup",
            skillIDs: [],
            connectionAccountIDs: []
        )
        let automation = makeAutomation(
            id: automationID,
            trigger: .manual,
            action: action,
            permissionRecordIDs: [permissionID],
            permissionGrantIDs: [grantID],
            confirmedAt: now,
            notificationEnabled: false
        )
        try fixture.store.save(YouziDomainDocument(
            permissions: [permission],
            permissionGrants: [grant],
            automations: [automation]
        ))
        let clock = ManualClock(now)
        let permissionRepository = YouziPermissionRepository(store: fixture.store)
        let coordinator = TestExecutionCoordinator(store: fixture.store, taskIDs: [taskID])
        coordinator.prepareHook = { _ in
            let revokedAt = now.addingTimeInterval(1)
            clock.set(revokedAt)
            _ = try permissionRepository.revoke(grantID: grantID, at: revokedAt)
        }
        let scheduler = fixture.scheduler(clock: clock, coordinator: coordinator)
        await scheduler.start()

        #expect(await scheduler.runNow(automationID: automationID) == .started(runID: runID))
        await scheduler.waitForActiveRuns()

        let document = try fixture.store.load()
        let run = try #require(document.automationRuns.first)
        #expect(run.status == .awaitingConfirmation)
        #expect(run.recoveryCode == .grantRevoked)
        #expect(run.attemptCount == 0)
        #expect(document.automations[0].revision == 2)
        #expect(document.automations[0].state == .needsAttention)
        #expect(coordinator.executeRequests.isEmpty)
        #expect(coordinator.prepareRequests[0].permissionGrantIDs == [grantID])
        #expect(coordinator.prepareRequests[0].input == .automationAction(action))
        let status = await scheduler.status()
        #expect(status.issues.contains(.grantRevoked(automationID: automationID)))
        await scheduler.shutdown()
    }

    @Test("Historical permission rows do not expand the current revision scope")
    func historicalPermissionRowsDoNotBlockCurrentScope() async throws {
        let runID = UUID()
        let taskID = UUID()
        let fixture = try StoreFixture(runIDs: [runID])
        defer { fixture.cleanup() }
        let now = date("2026-03-01T10:00:00Z")
        let automationID = UUID()
        let historicalID = UUID()
        let currentID = UUID()
        let currentGrantID = UUID()
        let historical = YouziPermissionRecord(
            id: historicalID,
            automationID: automationID,
            automationRevision: 1,
            kind: .networkAccess,
            targetIdentifier: "old.example.test",
            purpose: "Immutable previous scope",
            duration: .persistent,
            decision: .allowed,
            requestedAt: now.addingTimeInterval(-30),
            decidedAt: now.addingTimeInterval(-29)
        )
        let current = YouziPermissionRecord(
            id: currentID,
            automationID: automationID,
            automationRevision: 2,
            kind: .networkAccess,
            targetIdentifier: "current.example.test",
            purpose: "Current scope",
            duration: .persistent,
            decision: .allowed,
            requestedAt: now.addingTimeInterval(-20),
            decidedAt: now.addingTimeInterval(-19)
        )
        let grant = YouziPermissionGrant(
            id: currentGrantID,
            permissionRecordID: currentID,
            automationID: automationID,
            automationRevision: 2,
            kind: .networkAccess,
            targetIdentifier: "current.example.test",
            duration: .persistent,
            grantedAt: now.addingTimeInterval(-19)
        )
        let automation = YouziAutomation(
            id: automationID,
            name: "Revision two",
            revision: 2,
            trigger: .manual,
            action: .init(request: "run current scope", skillIDs: [], connectionAccountIDs: []),
            permissionRecordIDs: [historicalID, currentID],
            permissionGrantIDs: [currentGrantID],
            notificationEnabled: false,
            state: .active,
            confirmedAt: now,
            createdAt: now,
            updatedAt: now
        )
        try fixture.store.save(.init(
            permissions: [historical, current],
            permissionGrants: [grant],
            automations: [automation]
        ))
        let coordinator = TestExecutionCoordinator(store: fixture.store, taskIDs: [taskID])
        let scheduler = fixture.scheduler(clock: ManualClock(now), coordinator: coordinator)
        await scheduler.start()

        #expect(await scheduler.runNow(automationID: automationID) == .started(runID: runID))
        await scheduler.waitForActiveRuns()

        let run = try #require(try fixture.store.load().automationRuns.first)
        #expect(run.status == .completed)
        #expect(run.permissionGrantIDs == [currentGrantID])
        #expect(coordinator.executeRequests.count == 1)
        await scheduler.shutdown()
    }

    @Test("An empty current permission scope ignores immutable previous revisions")
    func emptyCurrentPermissionScopeIgnoresHistory() async throws {
        let runID = UUID()
        let taskID = UUID()
        let fixture = try StoreFixture(runIDs: [runID])
        defer { fixture.cleanup() }
        let now = date("2026-03-01T11:00:00Z")
        let automationID = UUID()
        let historicalID = UUID()
        let historical = YouziPermissionRecord(
            id: historicalID,
            automationID: automationID,
            automationRevision: 1,
            kind: .networkAccess,
            targetIdentifier: "old.example.test",
            purpose: "Immutable previous scope",
            duration: .persistent,
            decision: .allowed,
            requestedAt: now.addingTimeInterval(-20),
            decidedAt: now.addingTimeInterval(-19)
        )
        let automation = YouziAutomation(
            id: automationID,
            name: "Empty revision two scope",
            revision: 2,
            trigger: .manual,
            action: .init(request: "run without authority", skillIDs: [], connectionAccountIDs: []),
            permissionRecordIDs: [historicalID],
            permissionGrantIDs: [],
            notificationEnabled: false,
            state: .active,
            confirmedAt: now,
            createdAt: now,
            updatedAt: now
        )
        try fixture.store.save(.init(permissions: [historical], automations: [automation]))
        let coordinator = TestExecutionCoordinator(store: fixture.store, taskIDs: [taskID])
        let scheduler = fixture.scheduler(clock: ManualClock(now), coordinator: coordinator)
        await scheduler.start()

        #expect(await scheduler.runNow(automationID: automationID) == .started(runID: runID))
        await scheduler.waitForActiveRuns()

        let run = try #require(try fixture.store.load().automationRuns.first)
        #expect(run.status == .completed)
        #expect(run.permissionGrantIDs.isEmpty)
        #expect(coordinator.executeRequests.count == 1)
        await scheduler.shutdown()
    }

    @Test("A pending record in the exact current revision still blocks execution")
    func pendingCurrentPermissionScopeFailsClosed() async throws {
        let runID = UUID()
        let fixture = try StoreFixture(runIDs: [runID])
        defer { fixture.cleanup() }
        let now = date("2026-03-01T12:00:00Z")
        let automationID = UUID()
        let requestID = UUID()
        let request = YouziPermissionRecord(
            id: requestID,
            automationID: automationID,
            automationRevision: 2,
            kind: .networkAccess,
            targetIdentifier: "pending.example.test",
            purpose: "Unconfirmed current scope",
            duration: .persistent,
            decision: .pending,
            requestedAt: now
        )
        let automation = YouziAutomation(
            id: automationID,
            name: "Pending revision two scope",
            revision: 2,
            trigger: .manual,
            action: .init(request: "must not run", skillIDs: [], connectionAccountIDs: []),
            permissionRecordIDs: [requestID],
            notificationEnabled: false,
            state: .active,
            confirmedAt: now,
            createdAt: now,
            updatedAt: now
        )
        try fixture.store.save(.init(permissions: [request], automations: [automation]))
        let coordinator = TestExecutionCoordinator(store: fixture.store, taskIDs: [])
        let scheduler = fixture.scheduler(clock: ManualClock(now), coordinator: coordinator)
        await scheduler.start()

        #expect(await scheduler.runNow(automationID: automationID) == .started(runID: runID))
        await scheduler.waitForActiveRuns()

        let run = try #require(try fixture.store.load().automationRuns.first)
        #expect(run.status == .awaitingConfirmation)
        #expect(run.recoveryCode == .permissionRequired)
        #expect(coordinator.prepareRequests.isEmpty)
        #expect(coordinator.executeRequests.isEmpty)
        await scheduler.shutdown()
    }

    @Test("Action and revision are immutable across prepare")
    func exactActionSnapshotRejectsRevisionMutation() async throws {
        let runID = UUID()
        let taskID = UUID()
        let fixture = try StoreFixture(runIDs: [runID])
        defer { fixture.cleanup() }
        let now = date("2026-03-02T09:00:00Z")
        let originalAction = YouziAutomationAction(
            request: "original immutable request",
            skillIDs: [],
            connectionAccountIDs: []
        )
        let automation = makeAutomation(
            trigger: .manual,
            action: originalAction,
            confirmedAt: now,
            notificationEnabled: false
        )
        try fixture.store.save(YouziDomainDocument(automations: [automation]))
        let clock = ManualClock(now)
        let coordinator = TestExecutionCoordinator(store: fixture.store, taskIDs: [taskID])
        coordinator.prepareHook = { _ in
            let changedAt = now.addingTimeInterval(1)
            clock.set(changedAt)
            _ = try fixture.repository.revise(
                id: automation.id,
                expectedRevision: 1,
                mutation: { $0.action.request = "mutated request" },
                at: changedAt
            )
        }
        let scheduler = fixture.scheduler(clock: clock, coordinator: coordinator)
        await scheduler.start()

        #expect(await scheduler.runNow(automationID: automation.id) == .started(runID: runID))
        await scheduler.waitForActiveRuns()

        let document = try fixture.store.load()
        #expect(document.automationRuns[0].status == .skipped)
        #expect(document.automationRuns[0].recoveryCode == .automationRevisionChanged)
        #expect(document.automationRuns[0].attemptCount == 0)
        #expect(coordinator.prepareRequests[0].input == .automationAction(originalAction))
        #expect(coordinator.executeRequests.isEmpty)
        let status = await scheduler.status()
        #expect(status.issues.contains(.staleRevision(
            automationID: automation.id,
            runID: runID
        )))
        await scheduler.shutdown()
    }

    @Test("Run now creates a canonical task and compact redacted audit")
    func runNowCanonicalTaskAndAudit() async throws {
        let runID = UUID()
        let taskID = UUID()
        let fixture = try StoreFixture(runIDs: [runID])
        defer { fixture.cleanup() }
        let now = date("2026-04-01T00:00:00Z")
        let sentinel = "raw-token-sentinel-must-not-enter-audit"
        let action = YouziAutomationAction(
            request: sentinel,
            skillIDs: [],
            connectionAccountIDs: []
        )
        let automation = makeAutomation(
            trigger: .manual,
            action: action,
            confirmedAt: now,
            notificationEnabled: false
        )
        try fixture.store.save(YouziDomainDocument(automations: [automation]))
        let coordinator = TestExecutionCoordinator(
            store: fixture.store,
            taskIDs: [taskID],
            outcomes: [.completed(summary: YouziTaskExecutionSummary("Finished safely"))]
        )
        let scheduler = fixture.scheduler(clock: ManualClock(now), coordinator: coordinator)
        await scheduler.start()

        #expect(await scheduler.runNow(automationID: automation.id) == .started(runID: runID))
        await scheduler.waitForActiveRuns()

        let document = try fixture.store.load()
        let run = try #require(document.automationRuns.first)
        #expect(run.status == .completed)
        #expect(run.taskID == taskID)
        #expect(run.summary == "Finished safely")
        #expect(document.tasks.count == 1)
        #expect(document.tasks[0].request == sentinel)
        #expect(document.tasks[0].skillSelectionIntent == .explicit)
        #expect(document.tasks[0].connectionAccountSelectionIntent == .explicit)
        #expect(document.executionAuditEvents.sorted(by: { $0.sequence < $1.sequence }).map(\.kind)
            == [.executionStarted, .executionCompleted])
        let auditData = try JSONEncoder().encode(document.executionAuditEvents)
        let auditJSON = String(decoding: auditData, as: UTF8.self)
        #expect(!auditJSON.contains(sentinel))
        #expect(coordinator.prepareRequests == coordinator.executeRequests)
        let status = await scheduler.status()
        #expect(status.backgroundContract == .runsOnlyWhileYouziIsRunning)
        await scheduler.shutdown()
    }

    @Test("Scheduled overlap is skipped and shutdown cancels only the canonical task")
    func overlapAndShutdownCancellation() async throws {
        let firstRunID = UUID()
        let overlapRunID = UUID()
        let taskID = UUID()
        let fixture = try StoreFixture(runIDs: [firstRunID, overlapRunID])
        defer { fixture.cleanup() }
        let anchor = date("2026-05-01T00:00:00Z")
        let firstOccurrence = anchor.addingTimeInterval(600)
        let automation = makeAutomation(
            trigger: .interval(seconds: 600, anchorAt: anchor),
            confirmedAt: anchor,
            nextRunAt: firstOccurrence,
            notificationEnabled: false
        )
        try fixture.store.save(YouziDomainDocument(automations: [automation]))
        let clock = ManualClock(firstOccurrence)
        let coordinator = TestExecutionCoordinator(store: fixture.store, taskIDs: [taskID])
        coordinator.blocksExecution = true
        let scheduler = fixture.scheduler(clock: clock, coordinator: coordinator)

        await scheduler.start()
        await coordinator.waitForExecutionStarts(1)
        #expect(coordinator.executeRequests.count == 1)
        #expect(await scheduler.runNow(automationID: automation.id) == .alreadyRunning)

        clock.set(anchor.addingTimeInterval(1_200))
        await scheduler.foregroundWake()
        var document = try fixture.store.load()
        #expect(document.automationRuns.count == 2)
        #expect(document.automationRuns.first(where: { $0.id == firstRunID })?.status == .running)
        #expect(document.automationRuns.first(where: { $0.id == overlapRunID })?.status == .skipped)
        #expect(document.automations[0].nextRunAt == anchor.addingTimeInterval(1_800))
        #expect(coordinator.executeRequests.count == 1)

        await scheduler.shutdown()
        document = try fixture.store.load()
        #expect(document.automationRuns.first(where: { $0.id == firstRunID })?.status == .cancelled)
        #expect(document.automationRuns.first(where: { $0.id == overlapRunID })?.status == .skipped)
        #expect(coordinator.cancelCalls.count == 1)
        #expect(coordinator.cancelCalls[0].taskID == taskID)
        #expect(await scheduler.status().phase == .stopped)
    }

    @Test("Awaiting-confirmation preparation never enters execution")
    func awaitingConfirmation() async throws {
        let runID = UUID()
        let fixture = try StoreFixture(runIDs: [runID])
        defer { fixture.cleanup() }
        let now = date("2026-06-01T00:00:00Z")
        let automation = makeAutomation(
            trigger: .manual,
            confirmedAt: now,
            notificationEnabled: false
        )
        try fixture.store.save(YouziDomainDocument(automations: [automation]))
        let coordinator = TestExecutionCoordinator(store: fixture.store, taskIDs: [])
        coordinator.preparationOverride = .awaitingConfirmation(recoveryCode: .permissionRequired)
        let scheduler = fixture.scheduler(clock: ManualClock(now), coordinator: coordinator)
        await scheduler.start()

        #expect(await scheduler.runNow(automationID: automation.id) == .started(runID: runID))
        await scheduler.waitForActiveRuns()

        let run = try #require(try fixture.store.load().automationRuns.first)
        #expect(run.status == .awaitingConfirmation)
        #expect(run.recoveryCode == .permissionRequired)
        #expect(run.taskID == nil)
        #expect(coordinator.executeRequests.isEmpty)
        await scheduler.shutdown()
    }

    @Test("Paused, needs-attention, archived, and manual definitions never arm stale dates")
    func inactiveAndManualDefinitions() async throws {
        let fixture = try StoreFixture(runIDs: [])
        defer { fixture.cleanup() }
        let now = date("2026-07-01T00:00:00Z")
        let stale = now.addingTimeInterval(600)
        let records = [
            makeAutomation(trigger: .manual, confirmedAt: now, nextRunAt: stale,
                           notificationEnabled: false),
            makeAutomation(trigger: .interval(seconds: 600, anchorAt: now),
                           confirmedAt: nil, nextRunAt: stale, state: .paused,
                           notificationEnabled: false),
            makeAutomation(trigger: .interval(seconds: 600, anchorAt: now),
                           confirmedAt: nil, nextRunAt: stale, state: .needsAttention,
                           notificationEnabled: false),
            makeAutomation(trigger: .interval(seconds: 600, anchorAt: now),
                           confirmedAt: nil, nextRunAt: stale, state: .archived,
                           notificationEnabled: false),
        ]
        try fixture.store.save(YouziDomainDocument(automations: records))
        let coordinator = TestExecutionCoordinator(store: fixture.store, taskIDs: [])
        let scheduler = fixture.scheduler(clock: ManualClock(now), coordinator: coordinator)

        await scheduler.start()

        let document = try fixture.store.load()
        #expect(document.automations.allSatisfy { $0.nextRunAt == nil })
        #expect(document.automationRuns.isEmpty)
        #expect(coordinator.prepareRequests.isEmpty)
        #expect(await scheduler.status().phase == .idle(nextWakeAt: nil))
        let pausedID = try #require(records.first(where: { $0.state == .paused })?.id)
        #expect(await scheduler.runNow(automationID: pausedID)
            == .unavailable(.reviewSchedule(automationID: pausedID)))
        #expect(try fixture.store.load().automationRuns.isEmpty)
        await scheduler.shutdown()
    }

    @Test("Startup never replays an orphaned running task")
    func interruptedRunningRecovery() async throws {
        let runID = UUID()
        let taskID = UUID()
        let fixture = try StoreFixture(runIDs: [])
        defer { fixture.cleanup() }
        let now = date("2026-08-01T00:00:00Z")
        let automation = makeAutomation(
            trigger: .manual,
            confirmedAt: now.addingTimeInterval(-60),
            notificationEnabled: false
        )
        let task = YouziTask(id: taskID, title: "Interrupted", request: "work")
        let run = YouziAutomationRun(
            id: runID,
            automationID: automation.id,
            automationRevision: automation.revision,
            taskID: taskID,
            permissionGrantIDs: [],
            retryPolicy: automation.retryPolicy,
            attemptCount: 1,
            status: .running,
            createdAt: now.addingTimeInterval(-30),
            startedAt: now.addingTimeInterval(-30)
        )
        try fixture.store.save(YouziDomainDocument(
            tasks: [task],
            automations: [automation],
            automationRuns: [run]
        ))
        let coordinator = TestExecutionCoordinator(store: fixture.store, taskIDs: [])
        let scheduler = fixture.scheduler(clock: ManualClock(now), coordinator: coordinator)

        await scheduler.start()

        let recovered = try #require(try fixture.store.load().automationRuns.first)
        #expect(recovered.status == .failed)
        #expect(recovered.recoveryCode == .runtimeUnavailable)
        #expect(coordinator.prepareRequests.isEmpty)
        #expect(coordinator.executeRequests.isEmpty)
        #expect(await scheduler.status().issues.contains(.interruptedRun(runID: runID)))
        await scheduler.shutdown()
    }

    @Test("Startup closes a queued stale revision instead of leaving an overlap blocker")
    func staleQueuedRecovery() async throws {
        let runID = UUID()
        let fixture = try StoreFixture(runIDs: [])
        defer { fixture.cleanup() }
        let now = date("2026-08-02T00:00:00Z")
        var automation = makeAutomation(
            trigger: .manual,
            action: .init(
                request: "current revision",
                skillIDs: [],
                connectionAccountIDs: []
            ),
            confirmedAt: now.addingTimeInterval(-60),
            notificationEnabled: false
        )
        automation.revision = 2
        let staleRun = YouziAutomationRun(
            id: runID,
            automationID: automation.id,
            automationRevision: 1,
            permissionGrantIDs: [],
            retryPolicy: automation.retryPolicy,
            attemptCount: 0,
            status: .queued,
            createdAt: now.addingTimeInterval(-30),
            startedAt: nil
        )
        try fixture.store.save(YouziDomainDocument(
            automations: [automation],
            automationRuns: [staleRun]
        ))
        let coordinator = TestExecutionCoordinator(store: fixture.store, taskIDs: [])
        let scheduler = fixture.scheduler(clock: ManualClock(now), coordinator: coordinator)

        await scheduler.start()

        let recovered = try #require(try fixture.store.load().automationRuns.first)
        #expect(recovered.status == .skipped)
        #expect(recovered.recoveryCode == .automationRevisionChanged)
        #expect(coordinator.prepareRequests.isEmpty)
        #expect(coordinator.executeRequests.isEmpty)
        #expect(await scheduler.status().issues.contains(.staleRevision(
            automationID: automation.id,
            runID: runID
        )))
        await scheduler.shutdown()
    }

    @Test("Background completion never requests notification permission or exposes request text")
    func notificationDoesNotPrompt() async throws {
        let runID = UUID()
        let taskID = UUID()
        let fixture = try StoreFixture(runIDs: [runID])
        defer { fixture.cleanup() }
        let now = date("2026-09-01T00:00:00Z")
        let sentinel = "private-request-sentinel"
        let automation = makeAutomation(
            name: "Morning help",
            trigger: .manual,
            action: .init(request: sentinel, skillIDs: [], connectionAccountIDs: []),
            confirmedAt: now,
            notificationEnabled: true
        )
        try fixture.store.save(YouziDomainDocument(automations: [automation]))
        let center = SchedulerNotificationCenter(state: .notDetermined)
        let service = YouziAutomationNotificationService(center: center)
        let coordinator = TestExecutionCoordinator(store: fixture.store, taskIDs: [taskID])
        let scheduler = fixture.scheduler(
            clock: ManualClock(now),
            coordinator: coordinator,
            notifications: service
        )
        await scheduler.start()

        #expect(await scheduler.runNow(automationID: automation.id) == .started(runID: runID))
        await scheduler.waitForActiveRuns()

        #expect(await center.requestCount == 0)
        #expect(await center.delivered.isEmpty)
        #expect(try fixture.store.load().automationRuns[0].status == .completed)
        #expect(await scheduler.status().issues.contains(
            .notificationUnavailable(automationID: automation.id)
        ))
        await scheduler.shutdown()

        let authorizedCenter = SchedulerNotificationCenter(state: .authorized)
        let notificationService = YouziAutomationNotificationService(center: authorizedCenter)
        let deliveredFixture = try StoreFixture(runIDs: [UUID()])
        defer { deliveredFixture.cleanup() }
        try deliveredFixture.store.save(YouziDomainDocument(automations: [automation]))
        let deliveredCoordinator = TestExecutionCoordinator(
            store: deliveredFixture.store,
            taskIDs: [UUID()]
        )
        let deliveredScheduler = deliveredFixture.scheduler(
            clock: ManualClock(now),
            coordinator: deliveredCoordinator,
            notifications: notificationService
        )
        await deliveredScheduler.start()
        _ = await deliveredScheduler.runNow(automationID: automation.id)
        await deliveredScheduler.waitForActiveRuns()
        let delivered = await authorizedCenter.delivered
        #expect(delivered.count == 1)
        #expect(!delivered[0].body.contains(sentinel))
        #expect(delivered[0].body == "Scheduled help finished.")
        #expect(await authorizedCenter.requestCount == 0)
        await deliveredScheduler.shutdown()
    }

    private func makeAutomation(
        id: UUID = UUID(),
        name: String = "Scheduled help",
        trigger: YouziAutomationTrigger,
        action: YouziAutomationAction = .init(
            request: "help me",
            skillIDs: [],
            connectionAccountIDs: []
        ),
        permissionRecordIDs: [UUID] = [],
        permissionGrantIDs: [UUID] = [],
        confirmedAt: Date?,
        nextRunAt: Date? = nil,
        missedRunPolicy: YouziAutomationMissedRunPolicy = .runOnce,
        retryPolicy: YouziAutomationRetryPolicy = .init(),
        state: YouziAutomationState = .active,
        notificationEnabled: Bool
    ) -> YouziAutomation {
        let createdAt = confirmedAt ?? Date(timeIntervalSinceReferenceDate: 1)
        return YouziAutomation(
            id: id,
            name: name,
            trigger: trigger,
            action: action,
            permissionRecordIDs: permissionRecordIDs,
            permissionGrantIDs: permissionGrantIDs,
            missedRunPolicy: missedRunPolicy,
            retryPolicy: retryPolicy,
            notificationEnabled: notificationEnabled,
            state: state,
            confirmedAt: confirmedAt,
            nextRunAt: nextRunAt,
            createdAt: createdAt,
            updatedAt: createdAt
        )
    }
}

private final class StoreFixture: @unchecked Sendable {
    let root: URL
    let store: YouziDomainStore
    let repository: YouziAutomationRepository

    init(runIDs: [UUID]) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("youzi-scheduler-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = YouziDomainStore(fileURL: root.appendingPathComponent("domain.json"))
        let queue = SchedulerIDQueue(runIDs)
        self.store = store
        repository = YouziAutomationRepository(store: store) { queue.next() }
    }

    func scheduler(
        clock: ManualClock,
        coordinator: TestExecutionCoordinator,
        notifications: any YouziAutomationNotificationDelivering = RecordingNotifications()
    ) -> YouziAutomationScheduler {
        YouziAutomationScheduler(
            repository: repository,
            snapshot: { try self.store.load() },
            coordinator: coordinator,
            notificationDeliverer: notifications,
            clock: clock,
            sleeper: NeverWallClockSleeper()
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class SchedulerIDQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [UUID]

    init(_ ids: [UUID]) { self.ids = ids }

    func next() -> UUID {
        lock.lock()
        defer { lock.unlock() }
        return ids.isEmpty ? UUID() : ids.removeFirst()
    }
}

private final class ManualClock: YouziAutomationClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ value: Date) {
        lock.lock()
        self.value = value
        lock.unlock()
    }
}

private actor NeverWallClockSleeper: YouziAutomationSleeping {
    private(set) var requestedDates: [Date] = []

    func sleep(until date: Date) async throws {
        requestedDates.append(date)
        try await Task.sleep(nanoseconds: UInt64.max)
    }
}

private actor RecordingNotifications: YouziAutomationNotificationDelivering {
    private(set) var delivered: [YouziAutomationNotification] = []

    func authorizationState() async -> YouziNotificationAuthorizationState { .authorized }

    func deliver(_ notification: YouziAutomationNotification) async throws {
        delivered.append(notification)
    }
}

private actor SchedulerNotificationCenter: YouziUserNotificationCenter {
    private(set) var state: YouziNotificationAuthorizationState
    private(set) var requestCount = 0
    private(set) var delivered: [YouziAutomationNotification] = []

    init(state: YouziNotificationAuthorizationState) { self.state = state }

    func authorizationState() async -> YouziNotificationAuthorizationState { state }

    func requestAuthorization() async throws -> Bool {
        requestCount += 1
        return false
    }

    func add(_ notification: YouziAutomationNotification) async throws {
        delivered.append(notification)
    }
}

@MainActor
private final class TestExecutionCoordinator: YouziTaskExecutionCoordinating {
    struct CancelCall: Equatable {
        let taskID: UUID
        let origin: YouziTaskExecutionOrigin
    }

    private let store: YouziDomainStore
    private var taskIDs: [UUID]
    private var taskIDByRun: [UUID: UUID] = [:]
    private var outcomes: [YouziTaskExecutionOutcome]

    var preparationOverride: YouziTaskExecutionPreparation?
    var prepareHook: ((YouziTaskExecutionRequest) throws -> Void)?
    var blocksExecution = false
    private(set) var prepareRequests: [YouziTaskExecutionRequest] = []
    private(set) var executeRequests: [YouziTaskExecutionRequest] = []
    private(set) var cancelCalls: [CancelCall] = []

    init(
        store: YouziDomainStore,
        taskIDs: [UUID],
        outcomes: [YouziTaskExecutionOutcome] = [.completed(summary: nil)]
    ) {
        self.store = store
        self.taskIDs = taskIDs
        self.outcomes = outcomes
    }

    func prepare(_ request: YouziTaskExecutionRequest) async
        -> YouziTaskExecutionPreparation
    {
        prepareRequests.append(request)
        if let preparationOverride { return preparationOverride }
        guard case let .automation(_, _, runID) = request.origin,
              case let .automationAction(action) = request.input
        else { return .unavailable(recoveryCode: .runtimeUnavailable) }

        let taskID: UUID
        if let existing = taskIDByRun[runID] {
            taskID = existing
        } else {
            taskID = taskIDs.isEmpty ? UUID() : taskIDs.removeFirst()
            taskIDByRun[runID] = taskID
        }
        do {
            _ = try store.update { document in
                guard !document.tasks.contains(where: { $0.id == taskID }) else { return }
                document.upsert(YouziTask(
                    id: taskID,
                    title: "Scheduled help",
                    request: action.request,
                    workspaceID: action.workspaceID,
                    projectID: action.projectID,
                    helperID: action.helperID,
                    helperSelectionIntent: .explicit,
                    skillIDs: action.skillIDs,
                    skillSelectionIntent: .explicit,
                    connectionAccountIDs: action.connectionAccountIDs,
                    connectionAccountSelectionIntent: .explicit,
                    status: .inProgress
                ))
            }
            try prepareHook?(request)
            return .ready(taskID: taskID)
        } catch {
            return .unavailable(recoveryCode: .runtimeUnavailable)
        }
    }

    func execute(
        taskID: UUID,
        request: YouziTaskExecutionRequest
    ) async -> YouziTaskExecutionOutcome {
        executeRequests.append(request)
        if blocksExecution {
            do {
                try await Task.sleep(nanoseconds: UInt64.max)
            } catch {
                return .cancelled
            }
        }
        return outcomes.isEmpty ? .completed(summary: nil) : outcomes.removeFirst()
    }

    func cancel(taskID: UUID, origin: YouziTaskExecutionOrigin) async {
        cancelCalls.append(.init(taskID: taskID, origin: origin))
    }

    func waitForExecutionStarts(_ expected: Int) async {
        var remaining = 10_000
        while executeRequests.count < expected, remaining > 0 {
            remaining -= 1
            await Task.yield()
        }
    }
}
