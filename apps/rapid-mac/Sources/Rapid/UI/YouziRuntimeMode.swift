import Foundation

/// Compact runtime badge for the account menu. AIO means at least two
/// modalities are actually resident, not merely routable.
enum YouziRuntimeMode: String, Equatable, Sendable, CaseIterable {
    case llm
    case voice
    case image
    case video
    case aio

    var label: String {
        switch self {
        case .llm: "LLM"
        case .voice: "VOICE"
        case .image: "IMAGE"
        case .video: "VIDEO"
        case .aio: "AIO"
        }
    }

    static func resolve(
        hasChat: Bool,
        hasVoice: Bool,
        hasImage: Bool,
        hasVideo: Bool
    ) -> YouziRuntimeMode {
        let count = [hasChat, hasVoice, hasImage, hasVideo].filter { $0 }.count
        if count >= 2 { return .aio }
        if hasVideo { return .video }
        if hasImage { return .image }
        if hasVoice { return .voice }
        return .llm
    }
}
