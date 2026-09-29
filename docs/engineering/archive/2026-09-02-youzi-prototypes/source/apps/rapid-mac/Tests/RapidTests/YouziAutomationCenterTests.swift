import Foundation
import Testing
@testable import Rapid

@MainActor
@Suite("Youzi automation center — Simple Mode lifecycle")
struct YouziAutomationCenterTests {
    @Test("Retry policy accepts four attempts and rejects five before persistence")
    func retryBounds() async throws {
        let fixture = try CenterFixture()
        defer { fixture.cleanup() }

        var valid = fixture.draft(maximumAttempts: 4)
        let validID = await fixture.center.saveAndDecide(valid, decision: .allowed)
        #expect(validID != nil)
        var document = try fixture.store.load()
        #expect(document.automations.count == 1)
        #expect(document.automations[0].retryPolicy.maximumAttempts == 4)

        valid.automationID = nil
        valid.name = "invalid retry"
        valid.retryPolicy.maximumAttempts = 5
        let invalidID = await fixture.center.saveAndDecide(valid, decision: .allowed)
        #expect(invalidID == nil)
        #expect(fixture.center.lastError == .invalidSchedule)
        document = try fixture.store.load()
        #expect(document.automations.count == 1)
    }

    @Test("Confirmation issues exact persistent authority and denial preserves a safe draft")
    func permissionConfirmationAndDenial() async throws {
        let fixture = try CenterFixture()
        defer { fixture.cleanup() }
        let permission = YouziAutomationPermissionDraft(
            kind: .networkAccess,
            targetIdentifier: "builtin.network",
            purpose: "让所选技能访问网络"
        )

        var allowed = fixture.draft(maximumAttempts: 1)
        allowed.permissions = [permission]
        let allowedID = try #require(
            await fixture.center.saveAndDecide(allowed, decision: .allowed)
        )
        var document = try fixture.store.load()
        let active = try #require(document.automations.first { $0.id == allowedID })
        #expect(active.state == .active)
        #expect(active.confirmedAt != nil)
        #expect(active.permissionRecordIDs.count == 1)
        #expect(active.permissionGrantIDs.count == 1)
        let grant = try #require(document.permissionGrants.first)
        #expect(grant.automationID == allowedID)
        #expect(grant.automationRevision == active.revision)
        #expect(grant.duration == .persistent)
        #expect(grant.kind == .networkAccess)
        #expect(grant.targetIdentifier == "builtin.network")

        var denied = fixture.draft(maximumAttempts: 1)
        denied.name = "denied"
        denied.permissions = [permission]
        let deniedID = try #require(
            await fixture.center.saveAndDecide(denied, decision: .denied)
        )
        document = try fixture.store.load()
        let draft = try #require(document.automations.first { $0.id == deniedID })
        #expect(draft.state == .draft)
        #expect(draft.confirmedAt == nil)
        #expect(draft.permissionGrantIDs.isEmpty)
        let deniedRecords = document.permissions.filter { $0.automationID == deniedID }
        #expect(deniedRecords.count == 1)
        #expect(deniedRecords[0].decision == .denied)
    }

    @Test("Pure permission expansion advances authority revision once and revokes no-scope authority")
    func activePermissionExpansion() async throws {
        let fixture = try CenterFixture()
        defer { fixture.cleanup() }
        var draft = fixture.draft(maximumAttempts: 1)
        let automationID = try #require(
            await fixture.center.saveAndDecide(draft, decision: .allowed)
        )
        var document = try fixture.store.load()
        #expect(document.automations[0].revision == 1)
        #expect(document.automations[0].permissionRecordIDs.isEmpty)

        draft.automationID = automationID
        draft.permissions = [
            .init(
                kind: .networkAccess,
                targetIdentifier: "builtin.network",
                purpose: "让所选技能访问网络"
            ),
        ]
        #expect(await fixture.center.saveAndDecide(draft, decision: .allowed) == automationID)
        document = try fixture.store.load()
        let revised = try #require(document.automations.first)
        #expect(revised.revision == 2)
        #expect(revised.state == .active)
        #expect(revised.permissionRecordIDs.count == 1)
        #expect(revised.permissionGrantIDs.count == 1)
        #expect(document.permissions.last?.automationRevision == 2)
        #expect(document.permissionGrants.last?.automationRevision == 2)
    }

    @Test("Pause, resume, run now, foreground wake, and shutdown share one scheduler")
    func lifecycleActions() async throws {
        let fixture = try CenterFixture()
        defer { fixture.cleanup() }
        let automationID = try #require(
            await fixture.center.saveAndDecide(
                fixture.draft(maximumAttempts: 1),
                decision: .allowed
            )
        )

        await fixture.center.start()
        #expect(fixture.center.schedulerStatus.backgroundContract == .runsOnlyWhileYouziIsRunning)
        await fixture.center.pause(automationID: automationID)
        #expect(try fixture.store.load().automations[0].state == .paused)
        await fixture.center.resume(automationID: automationID)
        #expect(try fixture.store.load().automations[0].state == .active)

        await fixture.center.runNow(automationID: automationID)
        guard case .runStarted = fixture.center.lastNotice else {
            Issue.record("Expected a typed run-started notice")
            return
        }
        for _ in 0 ..< 200 {
            await Task.yield()
            fixture.productModel.refresh()
            if fixture.productModel.automationRuns.first?.status == .completed { break }
        }
        let run = try #require(fixture.productModel.automationRuns.first)
        #expect(run.status == .completed)
        #expect(fixture.coordinator.prepareCount == 1)
        #expect(fixture.coordinator.executeCount == 1)

        await fixture.center.foregroundWake()
        await fixture.center.shutdown()
        #expect(fixture.center.schedulerStatus.phase == .stopped)
    }

    @Test("Simple Mode source exposes the full safe automation contract without direct execution")
    func simpleModeSourceContract() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let page = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/Rapid/UI/YouziSimple/YouziSimpleAutomationPage.swift"
            ),
            encoding: .utf8
        )
        let center = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/Rapid/YouziAutomation/YouziAutomationCenter.swift"
            ),
            encoding: .utf8
        )

        #expect(page.contains("仅在 Youzi 运行时执行"))
        #expect(page.contains("缺失时刻跳过；重复时刻运行两次"))
        #expect(page.contains("立即运行"))
        #expect(page.contains("运行历史"))
        #expect(page.contains("需要你确认后才能继续"))
        #expect(!page.contains("ChatViewModel"))
        #expect(!page.contains("MCPTool"))
        #expect(!page.contains("YouziDomainStore("))
        #expect(center.contains("any YouziTaskExecutionCoordinating"))
        #expect(center.contains("revisePermissionScope"))
        #expect(center.contains("preparePermissionRequests"))
        #expect(center.contains("decideForAutomation"))
        #expect(center.contains("repository.confirm"))
    }
}

@MainActor
private final class CenterFixture {
    let root: URL
    let store: YouziDomainStore
    let productModel: YouziProductModel
    let coordinator: CenterTestCoordinator
    let notifications: CenterTestNotifications
    let center: YouziAutomationCenter
    private let now = Date(timeIntervalSinceReferenceDate: 10_000)

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("youzi-automation-center-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = YouziDomainStore(fileURL: root.appendingPathComponent("domain.json"))
        productModel = YouziProductModel(store: store)
        coordinator = CenterTestCoordinator(store: store)
        notifications = CenterTestNotifications()
        center = YouziAutomationCenter(
            store: store,
            productModel: productModel,
            coordinator: coordinator,
            notificationDeliverer: notifications,
            notificationAuthorizer: notifications,
            clock: CenterTestClock(now: now),
            sleeper: CenterTestSleeper()
        )
    }

    func draft(maximumAttempts: Int) -> YouziAutomationDefinitionDraft {
        YouziAutomationDefinitionDraft(
            name: "morning brief",
            trigger: .manual,
            action: YouziAutomationAction(
                request: "prepare a concise brief",
                skillIDs: [],
                connectionAccountIDs: []
            ),
            retryPolicy: .init(maximumAttempts: maximumAttempts, baseDelaySeconds: 30),
            notificationEnabled: false
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private struct CenterTestClock: YouziAutomationClock {
    let nowValue: Date

    init(now: Date) { nowValue = now }
    func now() -> Date { nowValue }
}

private struct CenterTestSleeper: YouziAutomationSleeping {
    func sleep(until date: Date) async throws {
        try await Task.sleep(nanoseconds: 60_000_000_000)
    }
}

private actor CenterTestNotifications:
    YouziAutomationNotificationDelivering,
    YouziAutomationNotificationAuthorizing
{
    func authorizationState() async -> YouziNotificationAuthorizationState { .authorized }
    func requestAuthorization() async throws -> YouziNotificationAuthorizationState { .authorized }
    func deliver(_ notification: YouziAutomationNotification) async throws {}
}

@MainActor
private final class CenterTestCoordinator: YouziTaskExecutionCoordinating, @unchecked Sendable {
    private let store: YouziDomainStore
    private(set) var prepareCount = 0
    private(set) var executeCount = 0

    init(store: YouziDomainStore) {
        self.store = store
    }

    func prepare(_ request: YouziTaskExecutionRequest) async -> YouziTaskExecutionPreparation {
        prepareCount += 1
        let id = UUID()
        do {
            _ = try store.update {
                $0.upsert(YouziTask(id: id, title: "automation", request: "work"))
            }
            return .ready(taskID: id)
        } catch {
            return .unavailable(recoveryCode: .runtimeUnavailable)
        }
    }

    func execute(
        taskID: UUID,
        request: YouziTaskExecutionRequest
    ) async -> YouziTaskExecutionOutcome {
        executeCount += 1
        return .completed(summary: YouziTaskExecutionSummary("done"))
    }

    func cancel(taskID: UUID, origin: YouziTaskExecutionOrigin) async {}
}
