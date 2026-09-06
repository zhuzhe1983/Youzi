import Foundation

/// Explicit opt-in resident set. Downloading a model never adds it implicitly.
enum YouziResidentServicePreference {
    static let enabledKey = "youzi.models.residentService.enabled.v1"
    static func enabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    enum Slot: String, CaseIterable, Identifiable {
        case transcription, speech, image
        var id: String { rawValue }
        var key: String { "youzi.models.residentService.\(rawValue).v1" }
        var kind: ModelKind { self == .image ? .image : .audio }
        func accepts(_ entry: ModelEntry) -> Bool {
            guard entry.cached else { return false }
            switch self {
            case .transcription:
                return entry.kind == .audio && entry.audioCapability == .transcription
            case .speech:
                return entry.kind == .audio && entry.audioCapability == .speech
            case .image:
                return entry.kind == .image && entry.imageCapability?.supportsGeneration == true
            }
        }
        func title(isChinese: Bool) -> String {
            switch self {
            case .transcription: isChinese ? "语音识别" : "Transcription"
            case .speech: isChinese ? "语音合成" : "Speech"
            case .image: isChinese ? "图片生成" : "Image generation"
            }
        }
    }

    static func selected(in defaults: UserDefaults = .standard) -> [(Slot, String)] {
        Slot.allCases.compactMap { slot in
            guard let alias = defaults.string(forKey: slot.key), !alias.isEmpty else { return nil }
            return (slot, alias)
        }
    }
}
