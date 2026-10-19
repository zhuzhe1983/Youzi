import Foundation

/// Discovery describes candidates, never verifies a provider's inference protocol.
struct RemoteDiscoveredModel: Identifiable, Equatable, Sendable {
    enum Evidence: Sendable { case metadata, name, unknown, other }
    let id: String
    let slots: Set<RemoteModelSlot>
    let evidence: Evidence

    func label(chinese: Bool) -> String {
        switch evidence {
        case .metadata: chinese ? "服务声明" : "Provider metadata"
        case .name: chinese ? "名称候选" : "Name hint"
        case .unknown: chinese ? "能力未知" : "Unknown capability"
        case .other: chinese ? "其他用途" : "Other purpose"
        }
    }

    static func filtered(_ models: [Self], slot: RemoteModelSlot, query: String, showAll: Bool) -> [Self] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return models.filter { (showAll || $0.slots.contains(slot)) &&
            (query.isEmpty || $0.id.localizedCaseInsensitiveContains(query)) }
    }

    static func parse(_ data: Data) throws -> [Self] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["data"] as? [[String: Any]] else { throw RemoteModelError.invalidResponse }
        var models: [String: Self] = [:]
        for item in items {
            guard let id = item["id"] as? String, !id.isEmpty, id.count <= 256,
                  !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { continue }
            let next = classify(id: id, item: item)
            // Keep metadata over name hints when providers return duplicate aliases.
            if let previous = models[id], previous.evidence == .metadata {
                if next.evidence == .metadata {
                    models[id] = Self(id: id, slots: previous.slots.union(next.slots), evidence: .metadata)
                }
            } else { models[id] = next }
        }
        return models.values.sorted { $0.id < $1.id }
    }

    private static func strings(_ value: Any?) -> [String] {
        if let value = value as? String { return [value.lowercased()] }
        return (value as? [String] ?? []).map { $0.lowercased() }
    }

    private static func classify(id: String, item: [String: Any]) -> Self {
        var tokens = strings(item["supported_endpoints"]) + strings(item["endpoints"])
        tokens += strings(item["task"]) + strings(item["pipeline_tag"]) + strings(item["capabilities"])
        if let capabilities = item["capabilities"] as? [String: Any] {
            // Only explicit true flags count. Vision/input modalities do not imply image generation.
            tokens += capabilities.compactMap { key, value in (value as? Bool) == true ? key.lowercased() : nil }
        }
        var slots = Set<RemoteModelSlot>()
        var other = false
        for token in tokens {
            let key = token.replacingOccurrences(of: "-", with: "_")
            switch key {
            case "chat", "text_generation", "chat_completion", "chat_completions": slots.insert(.chat)
            case "image_generation", "text_to_image", "image_to_image", "image_editing": slots.insert(.image)
            case "video_generation", "text_to_video", "image_to_video": slots.insert(.video)
            case "text_to_speech", "speech_synthesis", "tts": slots.insert(.speech)
            case "automatic_speech_recognition", "speech_to_text", "transcription", "asr": slots.insert(.transcription)
            case "embedding", "embeddings", "feature_extraction", "rerank", "reranking", "vad": other = true
            default:
                // Match complete endpoint suffixes, not arbitrary words like 'image_input'.
                let path = "/" + token.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if path.hasSuffix("/images/generations") || path.hasSuffix("/images/edits") { slots.insert(.image) }
                else if path.hasSuffix("/videos") || path.hasSuffix("/videos/generations") { slots.insert(.video) }
                else if path.hasSuffix("/audio/speech") { slots.insert(.speech) }
                else if path.hasSuffix("/audio/transcriptions") { slots.insert(.transcription) }
                else if path.hasSuffix("/chat/completions") || path.hasSuffix("/responses") { slots.insert(.chat) }
                else if path.hasSuffix("/embeddings") || path.hasSuffix("/rerank") { other = true }
            }
        }
        if !slots.isEmpty { return Self(id: id, slots: slots, evidence: .metadata) }
        if other { return Self(id: id, slots: [], evidence: .other) }
        let architecture = item["architecture"] as? [String: Any]
        let modalities = item["modalities"] as? [String: Any]
        let outputs = strings(item["output_modalities"]) + strings(architecture?["output_modalities"]) + strings(modalities?["output"])
        for output in outputs {
            switch output {
            case "image": slots.insert(.image)
            case "video": slots.insert(.video)
            case "text": slots.insert(.chat)
            // Audio output alone is insufficient to promise the /audio/speech contract.
            default: break
            }
        }
        if !slots.isEmpty { return Self(id: id, slots: slots, evidence: .metadata) }
        // An explicit output list overrides a misleading name, including unsupported outputs.
        if !outputs.isEmpty { return Self(id: id, slots: [], evidence: .unknown) }

        let name = id.lowercased().split(separator: "/").last.map(String.init) ?? id.lowercased()
        func matches(_ pattern: String) -> Bool { name.range(of: pattern, options: .regularExpression) != nil }
        if matches(#"(^|[-_])(embedding|reranker?|vad)([-_]|$)"#) {
            return Self(id: id, slots: [], evidence: .other)
        }
        let slot: RemoteModelSlot?
        if matches(#"^(qwen[-_]?image|gpt-image|dall-e|grok-imagine-image|flux[-.]|z-image|stable-diffusion)"#) || matches(#"^gemini-.*-image([-.]|$)"#) { slot = .image }
        else if matches(#"^(grok-imagine-video|minimax-h3([-.]|$)|sora([-.]|$)|veo([-.]|$)|wan[-_]?2[.-]|hunyuan[-_]?video)"#) { slot = .video }
        else if matches(#"(^|[-_])(tts|text-to-speech)([-_]|$)"#) { slot = .speech }
        else if matches(#"(^|[-_])(asr|whisper)([-_]|$)"#) { slot = .transcription }
        else if matches(#"^(gpt-[0-9]|o[1-9]([-.]|$)|gemini-|claude-|grok-[0-9]|qwen[23]([._-]|$)|deepseek-|glm-|kimi-|minimax-m[0-9])"#) && !name.contains("omni") { slot = .chat }
        else { slot = nil }
        if let slot, let flags = item["capabilities"] as? [String: Any] {
            let names: [RemoteModelSlot: Set<String>] = [
                .image: ["image_generation", "text_to_image", "image_editing", "image_to_image"],
                .video: ["video_generation", "text_to_video", "image_to_video"],
                .chat: ["chat", "text_generation", "chat_completions", "chat_completion"],
                .speech: ["text_to_speech", "speech_synthesis", "tts"],
                .transcription: ["automatic_speech_recognition", "speech_to_text", "transcription", "asr"]
            ]
            if flags.contains(where: { names[slot, default: []].contains($0.key.lowercased().replacingOccurrences(of: "-", with: "_")) && ($0.value as? Bool) == false }) {
                return Self(id: id, slots: [], evidence: .unknown)
            }
        }
        return Self(id: id, slots: slot.map { [$0] } ?? [], evidence: slot == nil ? .unknown : .name)
    }
}
