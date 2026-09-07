import Foundation

/// Single source of truth for startup AND unspecified-model routing.
/// Downloaded models are either automatic (ordered preferred pool) or on-demand.
/// A scenario may explicitly request any compatible model; that never changes
/// this pool or authorizes loading/downloading it.
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
        var legacyDefaultKey: String { "youzi.models.default.\(rawValue).v1" }
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

    enum LoadingPolicy: String, CaseIterable {
        case automatic, onDemand
    }

    static func loadingPolicy(for alias: String, slot: Slot, in defaults: UserDefaults = .standard) -> LoadingPolicy {
        aliases(for: slot, in: defaults).contains(alias) ? .automatic : .onDemand
    }

    /// Only compatible, downloaded members of the explicit pool are candidates.
    /// Prefer a ready member to avoid a second allocation; ties use saved order,
    /// never catalog order. The global switch pauses startup, not pool membership.
    static func automaticAlias(
        for slot: Slot, entries: [ModelEntry], snapshot: ModelResidencySnapshot? = nil,
        in defaults: UserDefaults = .standard
    ) -> String? {
        let candidates = aliases(for: slot, in: defaults).compactMap { alias in
            entries.first { $0.alias == alias && slot.accepts($0) }
        }
        if let snapshot, let ready = candidates.first(where: { YouziScenarioModels.isReady($0, in: snapshot) }) {
            return ready.alias
        }
        return candidates.first?.alias
    }

    /// Explicit requests (including scenario recommendations) are exact and
    /// never fall back to another model. Nil means no matching usable selection,
    /// not permission to download or start arbitrary catalog entries.
    static func resolveAlias(
        requested: String?, for slot: Slot, entries: [ModelEntry],
        snapshot: ModelResidencySnapshot? = nil, in defaults: UserDefaults = .standard
    ) -> String? {
        if let requested {
            return entries.first { $0.alias == requested && slot.accepts($0) }?.alias
        }
        return automaticAlias(for: slot, entries: entries, snapshot: snapshot, in: defaults)
    }

    /// Reorder the same pool instead of maintaining a second default-model key.
    static func promote(_ alias: String, for slot: Slot, in defaults: UserDefaults = .standard) {
        let current = aliases(for: slot, in: defaults)
        guard current.contains(alias) else { return }
        setAliases([alias] + current.filter { $0 != alias }, for: slot, in: defaults)
    }

    /// Settings and the sidecar consume exactly the same ordered aliases.
    static func automaticPool(in defaults: UserDefaults = .standard) -> [String: [String]] {
        Dictionary(uniqueKeysWithValues: Slot.allCases.map { ($0.rawValue, aliases(for: $0, in: defaults)) })
    }

    static func encodedPolicy(in defaults: UserDefaults = .standard) -> String? {
        guard let data = try? JSONEncoder().encode(ModelLoadingPolicyClient.Policy(automatic: automaticPool(in: defaults))) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Launch may only choose the user's automatic pool. Session history and
    /// scenario recommendations are not authorization to make a model resident.
    static func startupChatAlias(entries: [ModelEntry], in defaults: UserDefaults = .standard) -> String? {
        guard enabled(in: defaults) else { return nil }
        return automaticAlias(for: .chat, entries: entries, snapshot: nil, in: defaults)
    }

    static func setLoadingPolicy(_ policy: LoadingPolicy, for alias: String, slot: Slot, in defaults: UserDefaults = .standard) {
        let current = aliases(for: slot, in: defaults)
        let next = policy == .onDemand ? current.filter { $0 != alias }
            : slot.allowsMultiple ? current + [alias] : [alias]
        setAliases(next, for: slot, in: defaults)
    }

    static func selected(in defaults: UserDefaults = .standard) -> [(Slot, String)] {
        Slot.allCases.flatMap { slot in aliases(for: slot, in: defaults).map { (slot, $0) } }
    }
}
