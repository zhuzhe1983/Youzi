import Foundation
import Security
import Observation

/// Application-side supplements, never sidecar residency or downloadable files.
enum RemoteModelSlot: String, Codable, CaseIterable, Identifiable, Sendable {
    case chat, transcription, speech, image, video
    var id: String { rawValue }
    var kind: ModelKind {
        switch self { case .chat: .chat; case .transcription, .speech: .audio; case .image: .image; case .video: .video }
    }
    func title(chinese: Bool) -> String {
        switch self {
        case .chat: chinese ? "聊天" : "Chat"
        case .transcription: chinese ? "语音识别" : "Transcription"
        case .speech: chinese ? "语音合成" : "Speech"
        case .image: chinese ? "图片" : "Images"
        case .video: chinese ? "视频" : "Video"
        }
    }
}
enum ModelSourcePriority: String, Codable, CaseIterable, Sendable {
    case localFirst, remoteFirst
    func title(chinese: Bool) -> String {
        self == .localFirst ? (chinese ? "本地优先（推荐）" : "Local first (recommended)") : (chinese ? "远程优先" : "Remote first")
    }
}
enum RemoteVideoAPI: String, Codable, CaseIterable, Sendable {
    case openAI, cliProxyAPI
}
struct RemoteModelConfiguration: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name = ""
    var modelID = ""
    var baseURL = ""
    var slot: RemoteModelSlot = .chat
    var enabled = true
    var allowInsecureHTTP = false
    var supportsVision = false
    var supportsImageEditing = false
    var imageResponseFormat = "auto"
    var supportsVideoImageInput = false
    var voices = "alloy"
    var videoSizes = "720x1280,1280x720"
    var videoSeconds = "4,8,12"
    // Optional so pre-existing version-1 documents continue to decode unchanged.
    var videoAPI: RemoteVideoAPI? = nil
    var usesCLIProxyVideo: Bool { slot == .video && videoAPI == .cliProxyAPI }
    var alias: String { "youzi-remote/" + id.uuidString.lowercased() }
    var displayName: String { name.isEmpty ? modelID : name }
    /// Follow the provider ID until the user gives this configuration a custom name.
    mutating func selectModelID(_ value: String) {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name == modelID {
            name = value
        }
        modelID = value
    }
    var voiceNames: [String] { Self.items(voices) }
    var sizes: [String] { Self.items(videoSizes) }
    var durations: [Int] { Self.items(videoSeconds).compactMap(Int.init).filter { $0 > 0 && $0 <= 600 } }
    static func items(_ value: String) -> [String] {
        var seen = Set<String>()
        return value.split(whereSeparator: { $0 == "," || $0 == "，" || $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
    func validated() throws -> Self {
        var copy = self
        copy.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.modelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !copy.modelID.isEmpty, copy.modelID.count <= 256,
              !copy.modelID.contains(where: { $0.isNewline || $0.asciiValue.map { $0 < 32 } == true }) else { throw RemoteModelError.invalidModel }
        if copy.name.isEmpty { copy.name = copy.modelID }
        copy.baseURL = try RemoteModelEndpoint.normalizedBaseURL(baseURL, allowHTTP: allowInsecureHTTP).absoluteString
        guard ["auto", "b64_json"].contains(imageResponseFormat) else { throw RemoteModelError.invalidResponse }
        if slot == .speech && voiceNames.isEmpty { throw RemoteModelError.invalidVoice }
        if slot == .video && (sizes.isEmpty || durations.isEmpty || sizes.contains(where: { $0.range(of: #"^\d{2,5}x\d{2,5}$"#, options: .regularExpression) == nil })) { throw RemoteModelError.invalidVideo }
        if copy.usesCLIProxyVideo {
            let parts = copy.modelID.lowercased().split(separator: "/")
            guard URL(string: copy.baseURL)?.path.hasSuffix("/v1") == true,
                  parts.count == 1 || (parts.count == 2 && ["xai", "x-ai", "grok"].contains(String(parts[0]))),
                  ["grok-imagine-video", "grok-imagine-video-1.5", "grok-imagine-video-1.5-preview"].contains(String(parts.last ?? ""))
            else { throw RemoteModelError.unsupportedVideoAPI }
        }
        return copy
    }
    var entry: ModelEntry {
        var entry = ModelEntry(alias: alias, hfRepo: nil, sizeOnDisk: nil, cached: false)
        entry.kind = slot.kind
        entry.runtimeAdapter = "openai_remote"
        switch slot {
        case .chat: break
        case .transcription: entry.audioCapability = .transcription; entry.audioFamily = "openai_remote"
        case .speech: entry.audioCapability = .speech; entry.audioFamily = "openai_remote"
        case .image: entry.imageCapability = supportsImageEditing ? .generationAndEditing : .generation
        case .video: entry.videoCapabilities = supportsVideoImageInput ? [.textToVideo, .imageToVideo] : [.textToVideo]
        }
        return entry
    }
}
struct RemoteModelDocument: Codable, Equatable, Sendable {
    var version = 1
    var models: [RemoteModelConfiguration] = []
    var globalPriority: ModelSourcePriority = .localFirst
    /// Kind keys intentionally share the Audio override across ASR and TTS.
    var overrides: [String: ModelSourcePriority] = [:]
    /// Preferred remote within each slot; disabled/removed choices fall back in list order.
    var preferred: [String: UUID] = [:]
    /// One GUI default per workflow. Missing keys retain the legacy effective
    /// choice; an empty value explicitly clears it. Optional for v1 decoding.
    var preferredModels: [String: String]? = nil
    func priority(for kind: ModelKind) -> ModelSourcePriority { overrides[kind.rawValue] ?? globalPriority }
    func model(alias: String) -> RemoteModelConfiguration? { models.first { $0.alias == alias && $0.enabled } }
    func remote(for slot: RemoteModelSlot) -> RemoteModelConfiguration? {
        let choices = models.filter { $0.enabled && $0.slot == slot }
        return choices.first { $0.id == preferred[slot.rawValue] } ?? choices.first
    }
    /// Only used for AUTOMATIC choice. Explicit aliases never fall through here.
    func automatic(for slot: RemoteModelSlot, local: String?) -> String? {
        if let preferred = preferredModels?[slot.rawValue] {
            if RemoteModelEndpoint.isRemote(preferred) {
                return model(alias: preferred).flatMap { $0.slot == slot ? $0.alias : nil }
            }
            return !preferred.isEmpty && local == preferred ? local : nil
        }
        let remote = remote(for: slot)?.alias
        return priority(for: slot.kind) == .localFirst ? (local ?? remote) : (remote ?? local)
    }
}

enum RemoteModelError: Error, LocalizedError {
    case invalidURL, insecureHTTP, invalidModel, invalidVoice, invalidVideo, unsupportedVideoAPI, unavailable, corruptSettings, changedEndpointKey, invalidKey, keychain(OSStatus), http(Int), invalidResponse, transport
    var errorDescription: String? {
        switch self {
        case .unsupportedVideoAPI: "CLIProxyAPI 视频模式需使用以 /v1 结尾的常规地址，模型限 grok-imagine-video、1.5 或 1.5-preview。 / CLIProxyAPI video requires the regular /v1 base and a supported Grok Imagine Video model."
        case .invalidURL: "请填写 API Base URL，不含用户名、密码、查询参数或接口名。 / Enter an API base URL without credentials, query, fragment, or endpoint."
        case .insecureHTTP: "HTTP 会明文传输数据和密钥；请使用 HTTPS，或明确允许 HTTP。 / Use HTTPS or explicitly allow unencrypted HTTP."
        case .invalidModel: "请填写有效的模型 ID。 / Enter a valid model ID."
        case .invalidVoice: "请至少填写一个服务商支持的音色。 / Enter at least one provider-supported voice."
        case .invalidVideo: "请填写有效的视频尺寸和时长。 / Enter valid video sizes and durations."
        case .unavailable: "远程模型已停用或移除，请重新选择。 / This remote model is disabled or removed. Select another model."
        case .corruptSettings: "远程模型配置无法读取，未覆盖原始配置。 / Remote settings could not be read; the original data was preserved."
        case .changedEndpointKey: "地址已更改，请明确替换或清空密钥。 / The endpoint changed; explicitly replace or clear its key."
        case .invalidKey: "API Key 不能包含控制字符。 / API keys cannot contain control characters."
        case .keychain(let status): "无法访问远程模型钥匙串（\(status)）。 / Cannot access remote model Keychain (\(status))."
        case .http(let status): "远程服务返回 HTTP \(status)，请检查地址、权限、模型 ID 或配额。 / Remote HTTP \(status); check URL, access, model ID and quota."
        case .transport: "远程连接失败，请检查网络和地址。 / Remote connection failed; check network and URL."
        case .invalidResponse: "远程服务返回了不兼容的数据。 / The remote service returned an incompatible response."
        }
    }
}

protocol RemoteModelSecrets: Sendable {
    func read(_ id: UUID) throws -> String?
    func write(_ value: String?, for id: UUID) throws
}
struct RemoteModelKeychain: RemoteModelSecrets {
    private let service = "com.youzi.remote-models.api-key.v1"
    var items: any KeychainItemAccessing = SecurityKeychainItems()

    // Availability discovery runs during launch. Reuse the application's
    // non-interactive adapter: a locked/inaccessible credential is an error,
    // never a SecurityAgent prompt that can block the main thread indefinitely.
    func read(_ id: UUID) throws -> String? {
        switch items.query(account: id.uuidString, service: service) {
        case .found(let value): return value
        case .missing: return nil
        case .unavailable: throw RemoteModelError.keychain(errSecInteractionNotAllowed)
        }
    }
    func write(_ value: String?, for id: UUID) throws {
        let success: Bool
        if let value, !value.isEmpty {
            success = items.upsert(account: id.uuidString, service: service, secret: value)
        } else {
            success = items.remove(account: id.uuidString, service: service)
        }
        guard success else { throw RemoteModelError.keychain(errSecInteractionNotAllowed) }
    }
}
/// Immutable references only; UserDefaults and Keychain serialize their storage.
struct RemoteModelRepository: @unchecked Sendable {
    static let key = "youzi.models.remote.v1"
    var defaults: UserDefaults = .standard
    var secrets: any RemoteModelSecrets = RemoteModelKeychain()
    func load() throws -> RemoteModelDocument {
        guard let data = defaults.data(forKey: Self.key) else { return .init() }
        guard let doc = try? JSONDecoder().decode(RemoteModelDocument.self, from: data), doc.version == 1,
              Set(doc.models.map(\.id)).count == doc.models.count else { throw RemoteModelError.corruptSettings }
        return doc
    }
    func save(_ doc: RemoteModelDocument) throws { defaults.set(try JSONEncoder().encode(doc), forKey: Self.key) }
    func endpoint(alias: String, slot: RemoteModelSlot? = nil) throws -> RemoteModelEndpoint? {
        guard RemoteModelEndpoint.isRemote(alias) else { return nil }
        guard let model = try load().model(alias: alias) else { throw RemoteModelError.unavailable }
        guard slot == nil || model.slot == slot else { throw RemoteModelError.unavailable }
        return try RemoteModelEndpoint(configuration: model, apiKey: secrets.read(model.id))
    }
}
@MainActor @Observable
final class RemoteModelSettings {
    static let shared = RemoteModelSettings()
    let repository: RemoteModelRepository
    private(set) var document = RemoteModelDocument()
    private(set) var loadError: String?
    private(set) var revision = 0
    init(repository: RemoteModelRepository = .init()) {
        self.repository = repository
        do { document = try repository.load() } catch { loadError = error.localizedDescription }
    }
    func update(_ mutation: (inout RemoteModelDocument) -> Void) throws {
        guard loadError == nil else { throw RemoteModelError.corruptSettings }
        var next = document; mutation(&next)
        try repository.save(next); document = next; revision += 1
    }
    /// Selecting a configured remote also enables it. Local selection is
    /// validated against the downloaded catalog by the settings UI.
    func prefer(_ alias: String?, for slot: RemoteModelSlot) throws {
        if let alias, RemoteModelEndpoint.isRemote(alias),
           !document.models.contains(where: { $0.alias == alias && $0.slot == slot }) {
            throw RemoteModelError.unavailable
        }
        try update { doc in
            var choices = doc.preferredModels ?? [:]
            choices[slot.rawValue] = alias ?? ""
            doc.preferredModels = choices
            if let index = doc.models.firstIndex(where: { $0.alias == alias && $0.slot == slot }) {
                doc.models[index].enabled = true
            }
        }
    }

    /// nil key means keep existing; empty means explicitly remove authentication.
    func save(_ model: RemoteModelConfiguration, key: String?, inheritingFrom sourceID: UUID? = nil) throws {
        guard loadError == nil else { throw RemoteModelError.corruptSettings }
        let key = try resolvedDraftKey(model, key: key, sourceID: sourceID)
        let valid = try model.validated()
        // Changing hosts must never silently transfer the previous host's key.
        if let old = document.models.first(where: { $0.id == model.id }), old.baseURL != valid.baseURL, key == nil { throw RemoteModelError.changedEndpointKey }
        var next = document
        if let index = next.models.firstIndex(where: { $0.id == valid.id }) { next.models[index] = valid }
        else { next.models.append(valid) }
        // Encode before touching the credential, so a serialization failure cannot
        // leave old metadata paired with a newly changed key.
        let data = try JSONEncoder().encode(next)
        if let key {
            guard !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw RemoteModelError.invalidKey }
            try repository.secrets.write(key.trimmingCharacters(in: .whitespacesAndNewlines), for: model.id)
        }
        repository.defaults.set(data, forKey: RemoteModelRepository.key)
        document = next; revision += 1
    }
    func remove(_ id: UUID) throws {
        guard loadError == nil else { throw RemoteModelError.corruptSettings }
        var next = document
        next.models.removeAll { $0.id == id }
        next.preferred = next.preferred.filter { $0.value != id }
        let data = try JSONEncoder().encode(next)
        try repository.secrets.write(nil, for: id)
        repository.defaults.set(data, forKey: RemoteModelRepository.key)
        document = next; revision += 1
    }
    /// Discovery has the same credential boundary as Save, including gateway paths.
    /// It does not validate inference presets or mutate the saved configuration.
    func discoveryEndpoint(_ draft: RemoteModelConfiguration, key: String?, inheritingFrom sourceID: UUID? = nil) throws -> RemoteModelEndpoint {
        guard loadError == nil else { throw RemoteModelError.corruptSettings }
        let key = try resolvedDraftKey(draft, key: key, sourceID: sourceID)
        let url = try RemoteModelEndpoint.normalizedBaseURL(draft.baseURL, allowHTTP: draft.allowInsecureHTTP)
        if let old = document.models.first(where: { $0.id == draft.id }),
           old.baseURL != url.absoluteString, key == nil { throw RemoteModelError.changedEndpointKey }
        var probe = draft
        probe.slot = .chat; probe.modelID = "discovery-only"; probe.imageResponseFormat = "auto"
        let credential = try key ?? repository.secrets.read(draft.id)
        return try RemoteModelEndpoint(configuration: probe, apiKey: credential)
    }
    /// Reuse is explicit, only for new configurations at the exact same API base.
    /// Save copies the key to a separate Keychain item; later source removal is safe.
    private func resolvedDraftKey(_ draft: RemoteModelConfiguration, key: String?, sourceID: UUID?) throws -> String? {
        guard let sourceID else { return key }
        guard key == nil, !document.models.contains(where: { $0.id == draft.id }),
              let source = document.models.first(where: { $0.id == sourceID }),
              try RemoteModelEndpoint.normalizedBaseURL(draft.baseURL, allowHTTP: draft.allowInsecureHTTP).absoluteString == source.baseURL
        else { throw RemoteModelError.changedEndpointKey }
        return try repository.secrets.read(sourceID) ?? ""
    }
    func entries(kind: ModelKind) -> [ModelEntry] { document.models.filter { $0.enabled && $0.slot.kind == kind }.map(\.entry) }
    func readiness(_ alias: String) -> ModelReadiness? {
        guard RemoteModelEndpoint.isRemote(alias) else { return nil }
        guard document.model(alias: alias) != nil else {
            return .failed(alias: alias, message: RemoteModelError.unavailable.localizedDescription, action: nil)
        }
        // Routable configuration, not a health probe or local residency claim.
        return .ready(alias: alias)
    }
    func title(_ alias: String) -> String { document.models.first { $0.alias == alias }.map { "\($0.displayName) · \(YouziI18nConfig.shared.isChinese ? "远程" : "Remote")" } ?? alias }
}
extension ModelEntry {
    var isRemote: Bool { RemoteModelEndpoint.isRemote(alias) }
    var isAvailableForInference: Bool { cached || isRemote }
}
