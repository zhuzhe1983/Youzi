import Foundation

enum ModelSettingsTab: String, CaseIterable, Identifiable {
    case service, files, chat, audio, image, video
    var id: String { rawValue }
    func title(isChinese: Bool) -> String {
        switch self {
        case .service: return isChinese ? "模型服务" : "Service"
        case .files: return isChinese ? "模型文件" : "Files"
        case .chat: return isChinese ? "聊天" : "Chat"
        case .audio: return isChinese ? "音频" : "Audio"
        case .image: return isChinese ? "图片" : "Images"
        case .video: return isChinese ? "视频" : "Video"
        }
    }
}
