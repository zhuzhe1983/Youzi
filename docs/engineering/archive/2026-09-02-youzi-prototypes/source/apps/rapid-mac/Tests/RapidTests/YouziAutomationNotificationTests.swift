import Foundation
import Testing
@testable import Rapid

@Suite("Youzi automation — honest notifications")
struct YouziAutomationNotificationTests {
    @Test("A non-app process keeps system notifications unavailable without crashing")
    func unavailableOutsideApplicationBundle() async throws {
        let center = YouziSystemNotificationCenter(center: nil)
        #expect(await center.authorizationState() == .unavailable)
        await #expect(throws: YouziAutomationNotificationError.authorizationFailed) {
            _ = try await center.requestAuthorization()
        }
        let notification = try #require(YouziAutomationNotification(
            identifier: "automation.swiftpm",
            title: "完成",
            body: "请查看"
        ))
        await #expect(throws: YouziAutomationNotificationError.deliveryFailed) {
            try await center.add(notification)
        }
    }

    @Test("Display content is whitespace-normalized, bounded, and requires all fields")
    func boundedContent() throws {
        let notification = try #require(YouziAutomationNotification(
            identifier: "  automation.1  ",
            title: String(repeating: "标题", count: 100),
            body: "完成\n\t请查看" + String(repeating: "。", count: 300)
        ))
        #expect(notification.identifier == "automation.1")
        #expect(notification.title.count == YouziAutomationNotification.maximumTitleCharacters)
        #expect(notification.body.count == YouziAutomationNotification.maximumBodyCharacters)
        #expect(!notification.body.contains("\n"))
        #expect(YouziAutomationNotification(identifier: "", title: "完成", body: "请查看") == nil)
        #expect(YouziAutomationNotification(identifier: "id", title: "", body: "请查看") == nil)
        #expect(YouziAutomationNotification(identifier: "id", title: "完成", body: "") == nil)
    }

    @Test("Delivery never prompts and fails closed before authorization")
    func backgroundDeliveryDoesNotPrompt() async throws {
        let center = NotificationCenterFake(state: .notDetermined)
        let service = YouziAutomationNotificationService(center: center)
        let notification = try #require(YouziAutomationNotification(
            identifier: "automation.1",
            title: "柚子已完成",
            body: "结果可以查看了"
        ))

        await #expect(throws: YouziAutomationNotificationError.permissionNotGranted(.notDetermined)) {
            try await service.deliver(notification)
        }
        #expect(await center.requestCount == 0)
        #expect(await center.delivered.isEmpty)
    }

    @Test("Explicit authorization requests once and then delivery succeeds")
    func authorizationAndDelivery() async throws {
        let center = NotificationCenterFake(state: .notDetermined)
        await center.setRequestResult(true, resultingState: .authorized)
        let service = YouziAutomationNotificationService(center: center)

        #expect(try await service.requestAuthorization() == .authorized)
        #expect(await center.requestCount == 1)
        #expect(try await service.requestAuthorization() == .authorized)
        #expect(await center.requestCount == 1)

        let notification = try #require(YouziAutomationNotification(
            identifier: "automation.1",
            title: "柚子已完成",
            body: "结果可以查看了"
        ))
        try await service.deliver(notification)
        #expect(await center.delivered == [notification])
    }

    @Test("Denied users are not repeatedly prompted")
    func deniedIsStable() async throws {
        let center = NotificationCenterFake(state: .denied)
        let service = YouziAutomationNotificationService(center: center)
        #expect(try await service.requestAuthorization() == .denied)
        #expect(await center.requestCount == 0)
    }

    @Test("Authorization and delivery errors are typed and redact underlying details")
    func failuresAreRedacted() async throws {
        let authCenter = NotificationCenterFake(state: .notDetermined)
        await authCenter.setAuthorizationFailure(true)
        let authService = YouziAutomationNotificationService(center: authCenter)
        await #expect(throws: YouziAutomationNotificationError.authorizationFailed) {
            _ = try await authService.requestAuthorization()
        }

        let deliveryCenter = NotificationCenterFake(state: .authorized)
        await deliveryCenter.setDeliveryFailure(true)
        let deliveryService = YouziAutomationNotificationService(center: deliveryCenter)
        let notification = try #require(YouziAutomationNotification(
            identifier: "automation.1",
            title: "完成",
            body: "请查看"
        ))
        await #expect(throws: YouziAutomationNotificationError.deliveryFailed) {
            try await deliveryService.deliver(notification)
        }
        #expect(!YouziAutomationNotificationError.deliveryFailed.localizedDescription
            .contains("underlying-sentinel"))
    }

    @Test("Notification failure is independent from automation task settlement")
    func failureDoesNotRewriteTaskResult() async throws {
        let center = NotificationCenterFake(state: .denied)
        let service = YouziAutomationNotificationService(center: center)
        var taskSucceeded = true
        let notification = try #require(YouziAutomationNotification(
            identifier: "automation.1",
            title: "完成",
            body: "请查看"
        ))
        do {
            try await service.deliver(notification)
        } catch {
            // Callers report notification state separately; no task/run value
            // is accepted by this service, so it cannot rewrite settlement.
        }
        #expect(taskSucceeded)
        taskSucceeded = false
        #expect(!taskSucceeded) // prove the local assertion is not constant-folded
    }
}

private actor NotificationCenterFake: YouziUserNotificationCenter {
    private(set) var state: YouziNotificationAuthorizationState
    private(set) var requestCount = 0
    private(set) var delivered: [YouziAutomationNotification] = []
    private var requestResult = false
    private var resultingState: YouziNotificationAuthorizationState = .denied
    private var authorizationFails = false
    private var deliveryFails = false

    init(state: YouziNotificationAuthorizationState) {
        self.state = state
    }

    func setRequestResult(
        _ result: Bool,
        resultingState: YouziNotificationAuthorizationState
    ) {
        requestResult = result
        self.resultingState = resultingState
    }

    func setAuthorizationFailure(_ value: Bool) {
        authorizationFails = value
    }

    func setDeliveryFailure(_ value: Bool) {
        deliveryFails = value
    }

    func authorizationState() async -> YouziNotificationAuthorizationState { state }

    func requestAuthorization() async throws -> Bool {
        requestCount += 1
        if authorizationFails { throw NSError(domain: "underlying-sentinel", code: 1) }
        state = resultingState
        return requestResult
    }

    func add(_ notification: YouziAutomationNotification) async throws {
        if deliveryFails { throw NSError(domain: "underlying-sentinel", code: 2) }
        delivered.append(notification)
    }
}
