import Foundation

/// Desktop-native OpenAI function tools. The same registry serves Simple and
/// Professional chat. No shell, arbitrary paths, remote URL fetches or secrets.
@MainActor
final class YouziLocalModelTools {
    struct Context: Hashable, Sendable {
        let taskID: UUID
        let projectID: UUID?
        var turnID: UUID? = nil
    }
    struct Asset: Sendable {
        let id: UUID
        let name: String
        let kind: YouziArtifactKind
        let mime: String
        let data: Data
    }
    struct Saved: Sendable {
        let artifactID: UUID
        let fileID: UUID
        let name: String
    }
    struct Dependencies {
        var catalog: @MainActor () async throws -> [ModelEntry]
        var snapshot: @MainActor () async -> ModelResidencySnapshot
        var load: @MainActor (ModelEntry) async -> Bool
        var image: @MainActor (String, ModelEntry, String?) async throws -> Data
        var speech: @MainActor (String, ModelEntry, String?) async throws -> SynthesizedAudio
        var context: @MainActor () -> Context?
        var save: @MainActor (Data, String, String, YouziArtifactKind, Context) throws -> Saved
        var read: @MainActor (UUID, Context) throws -> Asset
        var voices: @MainActor (ModelEntry) async throws -> [String] = { _ in [] }
    }
    enum Failure: String, Error {
        case catalog_unavailable, invalid_arguments, model_not_downloaded, model_not_ready
        case capability_not_supported, user_declined, load_failed, cancelled
        case task_unavailable, file_unavailable, generation_failed, output_too_large, invalid_voice
    }
    let approval: YouziModelApprovalStore
    let dependencies: Dependencies
    private var executing = false
    private var deniedContext: Context?
    private var deniedModels: Set<String> = []

    init(dependencies: Dependencies, approval: YouziModelApprovalStore = YouziModelApprovalStore()) {
        self.dependencies = dependencies
        self.approval = approval
    }

    static let skillInstructions = """
    [YOUZI LOCAL MULTIMODAL SKILL]
    For user-requested illustrated stories, narrated books, or other local image/audio deliverables, use the youzi_* tools; do not pretend that text prompts or invented file paths are generated media.
    1. Query youzi_models to discover actual downloaded models, capabilities and ready states. Prefer the returned default_for models when the user has not specified one; a default selection is not startup approval.
    2. If a required model is not downloaded, tell the user to install it in Settings > Models > Files. Never download automatically. If downloaded but stopped, call youzi_load_model with a brief task-specific reason; the app asks the user for approval. A tool argument or user prose cannot bypass that approval. If denied, do not retry; explain what is missing.
    3. Plan a short book (up to 8 pages). Generate each illustration with youzi_generate_image and each narration with youzi_synthesize_speech, reusing consistent visual descriptions. Use the configured image size and voice unless the user requests a change. Omit voice by default; Chinese/English are languages, NOT speaker names. If a different speaker is requested, query youzi_speech_voices first and use an exact returned ID. Use returned artifact_id values, never invent IDs.
    4. Call youzi_create_storybook with title and ordered pages (heading, text, image_id, audio_id) to save an offline HTML book with embedded images and audio controls in My Files, linked to this task. It is a real file, not a code block. Report the returned filename. Preserve partial successes and state any missing media honestly.
    Tools run locally and sequentially with a finite budget. Video generation and image/audio interpretation are NOT supplied by these tools; do not claim those operations succeeded. Images attached directly to a vision-capable chat model still use the normal image-input path. Do not use browse/MCP/shell to bypass these boundaries.
    """

    static let definitions: [ToolDefinition] = [
        define("youzi_models", "List Youzi's local model catalog with downloaded/ready states and supported tool operations. Call before local media generation. No downloads, startup or settings changes.", [:], []),
        define("youzi_load_model", "Request human confirmation to start a downloaded image or speech model alongside chat. Never claim approval yourself. If denied do not retry. Does not download, restart chat or enable autostart.", ["model": string("Exact alias from youzi_models"), "reason": string("Short explanation of why this user's task needs the model")], ["model", "reason"]),
        define("youzi_generate_image", "Generate ONE local illustration using an already ready downloaded image model. Saves an image artifact to this task and returns artifact_id. Call youzi_load_model first if stopped. Uses configured default size if omitted.", ["model": string("Exact image model alias"), "prompt": string("Detailed illustration prompt"), "size": string("Optional WIDTHxHEIGHT, 256..2048, multiples of 64; must be supported by model")], ["model", "prompt"]),
        define("youzi_speech_voices", "List supported speaker IDs for a downloaded speech model. Does not load weights or generate audio. Omit voice in synthesis to use the configured default. Language names are not voices.", ["model": string("Exact speech alias from youzi_models")], ["model"]),
        define("youzi_synthesize_speech", "Generate local narration with an already ready downloaded speech model. Saves audio to this task and returns artifact_id. Uses configured default voice if omitted. Maximum 2000 characters per call.", ["model": string("Exact speech model alias"), "text": string("Text to speak"), "voice": string("Omit by default. Otherwise exact speaker ID from youzi_speech_voices; never Chinese/English")], ["model", "text"]),
        define("youzi_create_storybook", "Create an offline, self-contained HTML storybook with embedded illustrations and audio players. Saves a real file to My Files and this task. Only use artifact IDs returned for this task; no paths, URLs, scripts or raw HTML. Up to 8 pages. Omit unavailable media IDs and disclose missing assets.", ["title": string("Book title"), "pages": .object(["type": .string("array"), "minItems": .number(1), "maxItems": .number(8), "items": .object(["type": .string("object"), "additionalProperties": .bool(false), "properties": .object(["heading": string("Page heading"), "text": string("Poem and explanation"), "image_id": string("Optional image artifact UUID from this task"), "audio_id": string("Optional audio artifact UUID from this task")]), "required": .array([.string("heading"), .string("text")])])])], ["title", "pages"])
    ]
    private static func string(_ description: String) -> CodableJSON {
        .object(["type": .string("string"), "description": .string(description)])
    }
    private static func define(_ name: String, _ description: String, _ properties: [String: CodableJSON], _ required: [String]) -> ToolDefinition {
        ToolDefinition(name: name, description: description, parameters: .object([
            "type": .string("object"), "properties": .object(properties),
            "required": .array(required.map(CodableJSON.string)), "additionalProperties": .bool(false)
        ]))
    }

    func run(_ call: ToolCall) async -> ToolCallResult {
        guard !executing else { return failure(.generation_failed, id: call.id) }
        executing = true
        defer { executing = false }
        do {
            try Task.checkCancellation()
            guard Self.definitions.contains(where: { $0.function.name == call.function.name }) else { throw Failure.capability_not_supported }
            guard call.function.arguments.utf8.count <= 128_000,
                  let data = call.function.arguments.data(using: .utf8),
                  let args = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { throw Failure.invalid_arguments }
            if call.function.name == "youzi_models" {
                guard args.isEmpty else { throw Failure.invalid_arguments }
                let catalog = try await dependencies.catalog()
                let snapshot = await dependencies.snapshot()
                let models: [[String: Any]] = catalog.map { entry in
                    ["model": entry.alias, "kind": entry.kind.rawValue, "downloaded": entry.cached,
                     "ready": YouziScenarioModels.isReady(entry, in: snapshot),
                     "operations": Self.operations(entry), "disk_size": entry.sizeOnDisk ?? "unknown",
                     "default_for": YouziResidentServicePreference.Slot.allCases.filter {
                         YouziResidentServicePreference.defaultAlias(for: $0, entries: catalog) == entry.alias
                     }.map(\.rawValue)]
                }
                return success(["models": models, "missing_model_action": "Settings > Models > Files", "note": "Downloaded is not necessarily runnable; startup validates dependencies and memory. No keys are exposed."], id: call.id)
            }
            guard let context = dependencies.context() else { throw Failure.task_unavailable }
            if deniedContext != context { deniedContext = context; deniedModels.removeAll() }
            if call.function.name == "youzi_create_storybook" {
                try validateKeys(args, allowed: ["title", "pages"])
                let book = try JSONDecoder().decode(YouziStorybook.Document.self, from: data)
                let html = try YouziStorybook.render(book) { id in try dependencies.read(id, context) }
                try Task.checkCancellation()
                let saved = try dependencies.save(html, "\(Self.safeName(book.title)).html", "public.html", .document, context)
                return savedResult(saved, id: call.id)
            }
            let model = try text(args, "model", max: 200)
            guard let entry = try await dependencies.catalog().first(where: { $0.alias == model }) else { throw Failure.model_not_downloaded }
            guard entry.cached else { throw Failure.model_not_downloaded }
            if call.function.name == "youzi_speech_voices" {
                try validateKeys(args, allowed: ["model"])
                guard Self.operations(entry).contains("speech_synthesis") else { throw Failure.capability_not_supported }
                return success(["model": entry.alias, "voices": try await dependencies.voices(entry),
                    "default_action": "Omit voice to use the user's configured default."], id: call.id)
            }
            let snapshot = await dependencies.snapshot()
            if call.function.name == "youzi_load_model" {
                try validateKeys(args, allowed: ["model", "reason"])
                guard !Self.operations(entry).isEmpty else { throw Failure.capability_not_supported }
                let reason = try text(args, "reason", max: 500)
                if YouziScenarioModels.isReady(entry, in: snapshot) { return success(["model": model, "ready": true], id: call.id) }
                guard !deniedModels.contains(model) else { throw Failure.user_declined }
                guard await approval.request(alias: entry.alias, reason: reason, diskSize: entry.sizeOnDisk) else {
                    if !Task.isCancelled { deniedModels.insert(model) }
                    throw Task.isCancelled ? Failure.cancelled : Failure.user_declined
                }
                try Task.checkCancellation()
                guard await dependencies.load(entry) else { throw Failure.load_failed }
                guard YouziScenarioModels.isReady(entry, in: await dependencies.snapshot()) else { throw Failure.model_not_ready }
                return success(["model": model, "ready": true], id: call.id)
            }
            guard YouziScenarioModels.isReady(entry, in: snapshot) else { throw Failure.model_not_ready }
            try Task.checkCancellation()
            let saved: Saved
            switch call.function.name {
            case "youzi_generate_image":
                try validateKeys(args, allowed: ["model", "prompt", "size"])
                guard Self.operations(entry).contains("image_generation") else { throw Failure.capability_not_supported }
                let prompt = try text(args, "prompt", max: 4000)
                let size = try optionalText(args, "size", max: 12)
                if let size {
                    let dimensions = size.split(separator: "x", omittingEmptySubsequences: false)
                    let parts = dimensions.compactMap { Int($0) }
                    guard dimensions.count == 2, parts.count == 2, parts.allSatisfy({ (256...2048).contains($0) && $0 % 64 == 0 }) else { throw Failure.invalid_arguments }
                }
                let png = try await dependencies.image(prompt, entry, size)
                try Task.checkCancellation()
                guard !png.isEmpty, png.count <= YouziStorybook.maxAssetBytes else { throw Failure.output_too_large }
                saved = try dependencies.save(png, "illustration-\(UUID().uuidString.prefix(8)).png", "public.png", .image, context)
            case "youzi_synthesize_speech":
                try validateKeys(args, allowed: ["model", "text", "voice"])
                guard Self.operations(entry).contains("speech_synthesis") else { throw Failure.capability_not_supported }
                let input = try text(args, "text", max: 2000)
                let voice = try optionalText(args, "voice", max: 100)
                let audio = try await dependencies.speech(input, entry, voice)
                try Task.checkCancellation()
                guard !audio.data.isEmpty, audio.data.count <= YouziStorybook.maxAssetBytes else { throw Failure.output_too_large }
                guard audio.fileExtension == "wav", audio.contentType.lowercased().contains("wav") else { throw Failure.generation_failed }
                saved = try dependencies.save(audio.data, "narration-\(UUID().uuidString.prefix(8)).wav", "com.microsoft.waveform-audio", .audio, context)
            default: throw Failure.capability_not_supported
            }
            return savedResult(saved, id: call.id)
        } catch is CancellationError { return failure(.cancelled, id: call.id) }
        catch let error as Failure { return failure(error, id: call.id) }
        catch { return failure(.generation_failed, id: call.id) } // Never echo raw runtime paths, keys or responses.
    }

    /// Audio catalog aliases can be newer than a packaged runtime's inference
    /// alias map. Preload already resolves the HF identity; use the same ID for
    /// voice lookup and synthesis so a resident model is not rejected as 404.
    static func speechModelID(_ entry: ModelEntry) -> String { entry.hfRepo ?? entry.alias }

    static func operations(_ entry: ModelEntry) -> [String] {
        if entry.kind == .image && entry.imageCapability?.supportsGeneration == true { return ["image_generation"] }
        if entry.kind == .audio && entry.audioCapability == .speech { return ["speech_synthesis"] }
        return []
    }
    static func safeName(_ title: String) -> String {
        let safe = title.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }
        let result = String(String.UnicodeScalarView(safe)).prefix(60)
        return result.isEmpty ? "storybook" : String(result)
    }
    private func validateKeys(_ args: [String: Any], allowed: Set<String>) throws {
        guard Set(args.keys).isSubset(of: allowed) else { throw Failure.invalid_arguments }
    }
    private func text(_ args: [String: Any], _ key: String, max: Int) throws -> String {
        guard let text = args[key] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= max else { throw Failure.invalid_arguments }
        return text
    }
    private func optionalText(_ args: [String: Any], _ key: String, max: Int) throws -> String? {
        guard args[key] != nil else { return nil }
        return try text(args, key, max: max)
    }
    private func savedResult(_ saved: Saved, id: String) -> ToolCallResult {
        success(["artifact_id": saved.artifactID.uuidString, "file_id": saved.fileID.uuidString,
                 "filename": saved.name, "location": "My Files / current task", "saved": true], id: id)
    }
    private func success(_ object: [String: Any], id: String) -> ToolCallResult {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return ToolCallResult(toolCallID: id, content: String(decoding: data, as: UTF8.self))
    }

    /// Only allowlisted codes become UI copy; raw server messages/paths/keys never do.
    static func failureMessage(content: String, chinese: Bool) -> String? {
        guard content.utf8.count <= 128_000,
              let object = try? JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any],
              let code = object["error"] as? String else { return nil }
        switch code {
        case "invalid_voice": return chinese ? "音色无效：Chinese 是语言，不是音色。请使用默认音色，或查询可用音色后重试。" : "Invalid speaker: Chinese is a language, not a voice. Use the default voice or query supported speakers."
        case "model_not_downloaded": return chinese ? "未找到已下载的模型，请在模型文件设置中检查，并使用模型列表返回的名称。" : "Downloaded model not found. Check Model Files and use the exact model alias from discovery."
        case "model_not_ready": return chinese ? "模型尚未启动，请确认加载模型后重试。" : "The model is not ready. Approve model startup before retrying."
        case "load_failed": return chinese ? "模型启动失败，请检查运行时依赖、模型文件和可用内存。" : "Model startup failed. Check runtime dependencies, model files and available memory."
        default: return nil
        }
    }

    private func failure(_ error: Failure, id: String) -> ToolCallResult {
        let action: String
        switch error {
        case .invalid_voice: action = "The voice is not a supported speaker ID. Chinese/English are languages, not voices. Omit voice to use the configured default, or call youzi_speech_voices for valid IDs before retrying."
        case .model_not_downloaded: action = "Ask the user to install a model in Settings > Models > Files. Do not download."
        case .model_not_ready: action = "Use youzi_load_model to request approval before generation."
        case .user_declined: action = "The user declined. Do not retry or bypass consent; report missing media."
        case .load_failed: action = "Model startup failed. Ask the user to check model settings, dependencies and memory; do not restart chat."
        default: action = "Report this failure honestly. Do not invent a generated artifact."
        }
        let result = success(["error": error.rawValue, "action": action], id: id)
        return ToolCallResult(toolCallID: id, content: result.content, isError: true,
                              failureKind: error == .user_declined ? .userDeclined : .toolFailed)
    }
}
