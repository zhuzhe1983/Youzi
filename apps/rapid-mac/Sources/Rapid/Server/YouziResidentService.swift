import Foundation

/// Explicit opt-in resident set. Downloading a model never adds it implicitly.
enum YouziResidentServicePreference {
    static let enabledKey = "youzi.models.residentService.enabled.v1"
    static func enabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    enum Slot: String, CaseIterable, Identifiable {
        case chat, transcription, speech, image, video
        var id: String { rawValue }
        var key: String { "youzi.models.residentService.\(rawValue).v1" }
        var kind: ModelKind {
            switch self {
            case .chat: .chat
            case .image: .image
            case .video: .video
            case .transcription, .speech: .audio
            }
        }
        var selectionKey: String { "youzi.models.startup.\(rawValue).v2" }
        var defaultKey: String { "youzi.models.default.\(rawValue).v1" }
        // The audio runtime still owns one engine per lane. Never promise
        // multi-residency by silently replacing the previous selection.
        var allowsMultiple: Bool { kind != .audio }
        func accepts(_ entry: ModelEntry) -> Bool {
            guard entry.cached else { return false }
            switch self {
            case .chat: return entry.kind == .chat
            case .video: return entry.kind == .video
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
            case .chat: isChinese ? "聊天" : "Chat"
            case .video: isChinese ? "视频生成" : "Video generation"
            case .transcription: isChinese ? "语音识别" : "Transcription"
            case .speech: isChinese ? "语音合成" : "Speech"
            case .image: isChinese ? "图片生成" : "Image generation"
            }
        }
    }

    /// Read legacy single aliases without deleting them. An explicit empty v2
    /// array wins, so clearing a migrated selection cannot resurrect the old one.
    static func aliases(for slot: Slot, in defaults: UserDefaults = .standard) -> [String] {
        let values = defaults.stringArray(forKey: slot.selectionKey)
            ?? defaults.string(forKey: slot.key).map { [$0] } ?? []
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func setAliases(_ aliases: [String], for slot: Slot, in defaults: UserDefaults = .standard) {
        var seen = Set<String>()
        let unique = aliases.filter { !$0.isEmpty && seen.insert($0).inserted }
        defaults.set(slot.allowsMultiple ? unique : Array(unique.prefix(1)), forKey: slot.selectionKey)
    }

    static func defaultAlias(for slot: Slot, entries: [ModelEntry], in defaults: UserDefaults = .standard) -> String? {
        guard let alias = defaults.string(forKey: slot.defaultKey),
              entries.contains(where: { $0.alias == alias && slot.accepts($0) }) else { return nil }
        return alias
    }

    static func selected(in defaults: UserDefaults = .standard) -> [(Slot, String)] {
        Slot.allCases.flatMap { slot in aliases(for: slot, in: defaults).map { (slot, $0) } }
    }
}
