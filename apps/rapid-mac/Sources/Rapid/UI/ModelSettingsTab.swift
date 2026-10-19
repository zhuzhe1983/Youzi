import Foundation

enum ModelSettingsTab: String, CaseIterable, Identifiable {
    case service, files, chat, audio, image, video
    var id: String { rawValue }
    // Keep the legacy service/files values for persisted tabs and deep links.
    static let loadingTabs: [Self] = [.chat, .audio, .image, .video]
    var loadingTab: Self { Self.loadingTabs.contains(self) ? self : .chat }
    var category: SettingsView.Category {
        switch self {
        case .files: .modelFiles
        case .service: .modelService
        default: .modelLoading
        }
    }
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
