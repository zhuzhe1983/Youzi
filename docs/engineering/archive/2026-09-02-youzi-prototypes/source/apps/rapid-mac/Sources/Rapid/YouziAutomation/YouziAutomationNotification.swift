import Foundation
import UserNotifications

enum YouziNotificationAuthorizationState: String, Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
    case provisional
    case unavailable

    var canDeliver: Bool {
        self == .authorized || self == .provisional
    }
}

enum YouziAutomationNotificationError: Error, Equatable, Sendable {
    case invalidContent
    case permissionNotGranted(YouziNotificationAuthorizationState)
    case authorizationFailed
    case deliveryFailed
}

extension YouziAutomationNotificationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidContent:
            return "The notification content is unavailable."
        case .permissionNotGranted:
            return "Notifications are not enabled for Youzi."
        case .authorizationFailed:
            return "Notification permission could not be requested."
        case .deliveryFailed:
            return "The notification could not be delivered."
        }
    }
}

/// Bounded, display-only completion copy. It intentionally cannot contain an
/// arbitrary payload, URL, file path, connector response, or raw error object.
struct YouziAutomationNotification: Equatable, Sendable {
    static let maximumTitleCharacters = 80
    static let maximumBodyCharacters = 240

    let identifier: String
    let title: String
    let body: String

    init?(identifier: String, title: String, body: String) {
        let normalizedIdentifier = Self.normalized(identifier, limit: 120)
        let normalizedTitle = Self.normalized(title, limit: Self.maximumTitleCharacters)
        let normalizedBody = Self.normalized(body, limit: Self.maximumBodyCharacters)
        guard !normalizedIdentifier.isEmpty,
              !normalizedTitle.isEmpty,
              !normalizedBody.isEmpty
        else { return nil }
        self.identifier = normalizedIdentifier
        self.title = normalizedTitle
        self.body = normalizedBody
    }

    private static func normalized(_ value: String, limit: Int) -> String {
        let collapsed = value
            .components(separatedBy: .controlCharacters)
            .joined(separator: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return String(collapsed.prefix(limit))
    }
}

protocol YouziUserNotificationCenter: Sendable {
    func authorizationState() async -> YouziNotificationAuthorizationState
    func requestAuthorization() async throws -> Bool
    func add(_ notification: YouziAutomationNotification) async throws
}

struct YouziSystemNotificationCenter: YouziUserNotificationCenter, @unchecked Sendable {
    private let center: UNUserNotificationCenter?

    /// `UNUserNotificationCenter.current()` raises an Objective-C exception
    /// when the executable is not inside an application bundle. SwiftPM's
    /// `swift run` and the test runner are intentionally bare executables, so
    /// constructing the production graph must not touch that API there.
    /// The assembled/signed app still receives the real system center.
    init(center: UNUserNotificationCenter? = Self.defaultCenter()) {
        self.center = center
    }

    private static func defaultCenter(
        bundleURL: URL = Bundle.main.bundleURL
    ) -> UNUserNotificationCenter? {
        guard bundleURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
            return nil
        }
        return .current()
    }

    func authorizationState() async -> YouziNotificationAuthorizationState {
        guard let center else { return .unavailable }
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: return .authorized
        case .provisional, .ephemeral: return .provisional
        @unknown default: return .unavailable
        }
    }

    func requestAuthorization() async throws -> Bool {
        guard let center else {
            throw YouziAutomationNotificationError.authorizationFailed
        }
        return try await center.requestAuthorization(options: [.alert, .sound])
    }

    func add(_ notification: YouziAutomationNotification) async throws {
        guard let center else {
            throw YouziAutomationNotificationError.deliveryFailed
        }
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        try await center.add(UNNotificationRequest(
            identifier: notification.identifier,
            content: content,
            trigger: nil
        ))
    }
}

/// Permission-aware notification boundary for scheduled help. Authorization
/// is requested only through the explicit `requestAuthorization` action;
/// background delivery never manufactures a system prompt.
actor YouziAutomationNotificationService {
    private let center: any YouziUserNotificationCenter

    init(center: any YouziUserNotificationCenter = YouziSystemNotificationCenter()) {
        self.center = center
    }

    func authorizationState() async -> YouziNotificationAuthorizationState {
        await center.authorizationState()
    }

    func requestAuthorization() async throws -> YouziNotificationAuthorizationState {
        let current = await center.authorizationState()
        switch current {
        case .authorized, .provisional, .denied, .unavailable:
            return current
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization()
                guard granted else { return .denied }
                let refreshed = await center.authorizationState()
                return refreshed.canDeliver ? refreshed : .authorized
            } catch {
                throw YouziAutomationNotificationError.authorizationFailed
            }
        }
    }

    func deliver(_ notification: YouziAutomationNotification) async throws {
        let state = await center.authorizationState()
        guard state.canDeliver else {
            throw YouziAutomationNotificationError.permissionNotGranted(state)
        }
        do {
            try await center.add(notification)
        } catch {
            throw YouziAutomationNotificationError.deliveryFailed
        }
    }
}
