import Foundation
import Observation

/// App-wide custom instructions shared by every chat. Conversation-specific
/// instructions live on ``ChatConversation`` because they travel with history;
/// this value owns only the global layer stored in preferences.
@MainActor
@Observable
final class CustomInstructionsConfig {
    nonisolated static let storageKey = "rapid.custom-instructions.global.v1"
    nonisolated static let maximumLength = 4_000

    nonisolated static let identityMaximumLength = 60
    nonisolated static let userAddressKey = "youzi.personalization.userAddress.v1"
    nonisolated static let assistantNameKey = "youzi.personalization.assistantName.v1"
    nonisolated static let replyStyleKey = "youzi.personalization.replyStyle.v1"
    nonisolated static let waitingHintsKey = "youzi.personalization.waitingHints.v1"
    nonisolated static let waitingTextKey = "youzi.personalization.waitingText.v1"

    enum ReplyStyle: String, CaseIterable, Identifiable, Sendable {
        case balanced, concise, detailed, friendly
        var id: String { rawValue }
        var instruction: String? {
            switch self {
            case .balanced: return nil
            case .concise: return "Prefer concise, direct answers. Keep necessary safety notes and important details."
            case .detailed: return "Explain clearly with useful detail and examples when appropriate. Avoid repetition."
            case .friendly: return "Use a warm, natural tone without excessive praise or forced intimacy."
            }
        }
    }

    var userAddress: String {
        didSet {
            let value = Self.identity(userAddress)
            if userAddress != value { userAddress = value }
            defaults.set(value, forKey: Self.userAddressKey)
        }
    }
    var assistantName: String {
        didSet {
            let value = Self.identity(assistantName)
            if assistantName != value { assistantName = value }
            defaults.set(value, forKey: Self.assistantNameKey)
        }
    }
    var replyStyle: ReplyStyle { didSet { defaults.set(replyStyle.rawValue, forKey: Self.replyStyleKey) } }
    var showsWaitingHints: Bool { didSet { defaults.set(showsWaitingHints, forKey: Self.waitingHintsKey) } }
    var waitingText: String {
        didSet {
            let value = Self.singleLine(waitingText, limit: 160)
            if waitingText != value { waitingText = value }
            defaults.set(value, forKey: Self.waitingTextKey)
        }
    }

    var resolvedAssistantName: String {
        let name = assistantName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "柚子" : name
    }

    /// Snapshot into one separate user-preference layer for each send. Encode
    /// names as JSON strings so punctuation cannot masquerade as prompt markup.
    var personalizationContext: String {
        func quoted(_ text: String) -> String {
            String(data: (try? JSONEncoder().encode(text)) ?? Data(), encoding: .utf8) ?? "\"\""
        }
        var lines = ["Assistant display name: " + quoted(resolvedAssistantName) + ". This is a conversational nickname, not a change to model or application identity."]
        let address = userAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if !address.isEmpty { lines.append("Address the user as " + quoted(address) + " when natural; do not repeat the name in every answer.") }
        if let instruction = replyStyle.instruction { lines.append(instruction) }
        return lines.joined(separator: "\n")
    }

    nonisolated static func identity(_ value: String) -> String {
        singleLine(value, limit: identityMaximumLength)
    }

    nonisolated static func singleLine(_ value: String, limit: Int) -> String {
        String(String(value.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()).prefix(limit))
    }

    private let defaults: UserDefaults
    private var storedGlobal: String

    var global: String {
        get { storedGlobal }
        set {
            let value = Self.limited(newValue)
            storedGlobal = value
            if value.isEmpty {
                defaults.removeObject(forKey: Self.storageKey)
            } else {
                defaults.set(value, forKey: Self.storageKey)
            }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.userAddress = Self.identity(defaults.string(forKey: Self.userAddressKey) ?? "")
        self.assistantName = Self.identity(defaults.string(forKey: Self.assistantNameKey) ?? "")
        self.replyStyle = ReplyStyle(rawValue: defaults.string(forKey: Self.replyStyleKey) ?? "") ?? .balanced
        self.showsWaitingHints = defaults.object(forKey: Self.waitingHintsKey) == nil ? true : defaults.bool(forKey: Self.waitingHintsKey)
        self.waitingText = Self.singleLine(defaults.string(forKey: Self.waitingTextKey) ?? "", limit: 160)
        self.storedGlobal = Self.limited(defaults.string(forKey: Self.storageKey) ?? "")
    }

    nonisolated static func normalized(_ value: String) -> String? {
        let trimmed = limited(value).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated static func limited(_ value: String) -> String {
        String(value.prefix(maximumLength))
    }
}
