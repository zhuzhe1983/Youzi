import Foundation

/// The file manager is discoverable before any models have been downloaded.
enum ModelFileCategory {
    static let kinds: [ModelKind] = [.chat, .audio, .image, .video]
    static func title(_ kind: ModelKind, isChinese: Bool) -> String {
        switch kind {
        case .chat: return isChinese ? "聊天" : "Chat"
        case .audio: return isChinese ? "音频" : "Audio"
        case .image: return isChinese ? "图片" : "Image"
        case .video: return isChinese ? "视频" : "Video"
        }
    }
}
