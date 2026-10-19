import Foundation

/// Single source of truth for startup AND unspecified-model routing.
/// Only the preferred local model starts automatically; all others require Load.
/// A scenario may explicitly request any compatible model; that never changes
/// the preference or authorizes loading/downloading it.
enum YouziResidentServicePreference {
    static let enabledKey = "youzi.models.residentService.enabled.v1"
    static func enabled(in defaults: UserDefaults = .standard) -> Bool {
        !selected(in: defaults).isEmpty
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
            entry.cached && supports(entry)
        }
        func supports(_ entry: ModelEntry) -> Bool {
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

    /// Effective GUI preference, including read-only migration of old source
    /// priorities and ordered local pools. One slot yields at most one model.
    static func preferredAlias(for slot: Slot, in defaults: UserDefaults = .standard,
                               remoteDocument: RemoteModelDocument? = nil) -> String? {
        let document = remoteDocument ?? defaults.data(forKey: RemoteModelRepository.key)
            .flatMap { try? JSONDecoder().decode(RemoteModelDocument.self, from: $0) }
        if let explicit = document?.preferredModels?[slot.rawValue] {
            return explicit.isEmpty ? nil : explicit
        }
        let local = (defaults.stringArray(forKey: slot.selectionKey)
            ?? defaults.string(forKey: slot.key).map { [$0] } ?? []).first { !$0.isEmpty }
        guard let document, let remoteSlot = RemoteModelSlot(rawValue: slot.rawValue) else { return local }
        return document.automatic(for: remoteSlot, local: local)
    }

    /// Only the preferred local model may start automatically. A remote
    /// preference suppresses local startup without unloading resident models.
    static func aliases(for slot: Slot, in defaults: UserDefaults = .standard) -> [String] {
        guard let alias = preferredAlias(for: slot, in: defaults),
              !RemoteModelEndpoint.isRemote(alias) else { return [] }
        return [alias]
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

    /// Only the compatible, downloaded preferred model may start. A different
    /// resident model never replaces this preference merely because it is ready.
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

    static func preferredInferenceAlias(for slot: Slot, entries: [ModelEntry],
                                        in defaults: UserDefaults = .standard,
                                        remoteDocument: RemoteModelDocument? = nil) -> String? {
        guard let alias = preferredAlias(for: slot, in: defaults, remoteDocument: remoteDocument),
              entries.contains(where: { $0.alias == alias && $0.isAvailableForInference && slot.supports($0) }) else { return nil }
        return alias
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

    /// The first compatible automatic model can own the service, including an
    /// image/audio/video-only setup. A preferred remote never starts local weights.
    static func startupEntry(entries: [ModelEntry], in defaults: UserDefaults = .standard) -> ModelEntry? {
        selected(in: defaults).lazy.compactMap { slot, alias in
            entries.first { $0.alias == alias && slot.accepts($0) && !$0.isRemote }
        }.first
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
