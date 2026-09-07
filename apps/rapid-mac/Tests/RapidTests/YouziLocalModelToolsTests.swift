import Foundation
import Testing
@testable import Rapid

@MainActor
@Suite("Youzi local multimodal tools", .serialized)
struct YouziLocalModelToolsTests {
    @MainActor final class Fixture {
        let image = ModelEntry(alias: "local-image", hfRepo: "local/image", sizeOnDisk: "4 GiB", cached: true, kind: .image, imageCapability: .generation)
        let speech = ModelEntry(alias: "local-voice", hfRepo: "local/voice", sizeOnDisk: "1 GiB", cached: true, kind: .audio, audioCapability: .speech)
        let missing = ModelEntry(alias: "missing", hfRepo: "local/missing", sizeOnDisk: nil, cached: false, kind: .image, imageCapability: .generation)
        var context = YouziLocalModelTools.Context(taskID: UUID(), projectID: nil)
        var ready: Set<String> = []
        var additionalModels: [ModelEntry] = []
        var generatedWith: [String] = []
        let suite = "YouziModelToolPolicy." + UUID().uuidString
        lazy var preferences = UserDefaults(suiteName: suite)!
        deinit { UserDefaults.standard.removePersistentDomain(forName: suite) }
        var loads = 0
        var generations = 0
        var capturedSize: String?
        var capturedVoice: String?
        var saved: [UUID: (YouziLocalModelTools.Asset, YouziLocalModelTools.Context)] = [:]
        var loadFails = false
        let png = Data([137, 80, 78, 71, 13, 10, 26, 10, 0])
        let wav = Data("RIFF0000WAVE0000".utf8)
        lazy var tools = YouziLocalModelTools(dependencies: .init(
            catalog: { [self] in [image, speech, missing] + additionalModels },
            snapshot: { [self] in snapshot },
            load: { [self] entry in loads += 1; if loadFails { return false }; ready.insert(entry.alias); return true },
            image: { [self] _, entry, size in generatedWith.append(entry.alias); generations += 1; capturedSize = size; return png },
            speech: { [self] _, entry, voice in generatedWith.append(entry.alias); generations += 1; capturedVoice = voice; return SynthesizedAudio(data: wav, contentType: "audio/wav") },
            context: { [self] in context },
            save: { [self] data, name, _, kind, context in
                let id = UUID()
                saved[id] = (.init(id: id, name: name, kind: kind, mime: kind == .image ? "image/png" : "audio/wav", data: data), context)
                return .init(artifactID: id, fileID: UUID(), name: name)
            },
            read: { [self] id, context in
                guard let (asset, owner) = saved[id], owner.taskID == context.taskID else { throw YouziLocalModelTools.Failure.file_unavailable }
                return asset
            }
        ), preferences: preferences)
        var snapshot: ModelResidencySnapshot {
            ModelResidencySnapshot(memoryLimitBytes: 100, memoryUsedBytes: 30, memoryAvailableBytes: 70,
                idleTTLSeconds: 0, loadsTotal: loads, evictionsTotal: 0,
                models: ([image] + additionalModels).filter { ready.contains($0.alias) }.map { Self.resident($0.alias, path: $0.hfRepo ?? $0.alias) },
                audioLanes: ready.contains(speech.alias) ? [.init(lane: "tts", model: speech.hfRepo, state: "busy")] : [])
        }
        static func resident(_ alias: String, path: String, state: String = "resident") -> ResidentModelStatus {
            .init(id: alias, modelPath: path, aliases: ["other-alias"], modality: "image", state: state,
                  pinned: true, primary: false, activeRequests: 0, estimatedBytes: 30, measuredBytes: nil, idleSeconds: 0)
        }
        func call(_ name: String, _ args: [String: Any] = [:]) async throws -> ToolCallResult {
            let json = String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)
            return await tools.run(ToolCall(id: UUID().uuidString, name: name, arguments: json))
        }
    }

    func json(_ result: ToolCallResult) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(result.content.utf8)) as? [String: Any])
    }
    func pending(_ store: YouziModelApprovalStore) async throws -> YouziModelApprovalStore.Request {
        for _ in 0..<200 {
            if let request = store.pending { return request }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw YouziLocalModelTools.Failure.generation_failed
    }

    @Test("Discovery reports downloaded and actual ready states without changing models")
    func discovery() async throws {
        let f = Fixture(); f.ready.insert(f.speech.alias)
        let result = try await f.call("youzi_models")
        #expect(!result.isError)
        let models = try #require(try json(result)["models"] as? [[String: Any]])
        #expect(models.count == 3)
        #expect(models.first { $0["model"] as? String == f.speech.alias }?["ready"] as? Bool == true)
        #expect(models.first { $0["model"] as? String == f.missing.alias }?["downloaded"] as? Bool == false)
        #expect(f.loads == 0 && f.generations == 0)
        #expect(!result.content.lowercased().contains("bearer"))
    }

    @Test("Missing models never download; on-demand generation asks before loading")
    func missingAndStopped() async throws {
        let f = Fixture()
        let missing = try await f.call("youzi_generate_image", ["model": "missing", "prompt": "moon"])
        #expect(missing.content.contains("model_not_downloaded"))
        let task = Task { try await f.call("youzi_generate_image", ["model": f.image.alias, "prompt": "moon"]) }
        let request = try await pending(f.tools.approval)
        #expect(f.loads == 0 && f.generations == 0)
        f.tools.approval.resolve(id: request.id, allow: true)
        #expect(try await !task.value.isError)
        #expect(f.loads == 1 && f.generations == 1)
        #expect(YouziResidentServicePreference.selected(in: f.preferences).isEmpty)
    }

    @Test("Omitted models use the automatic pool; explicit requests never fall back")
    func automaticRouting() async throws {
        let f = Fixture()
        f.ready = [f.image.alias, f.speech.alias]
        let absent = try await f.call("youzi_generate_image", ["prompt": "moon"])
        #expect(absent.content.contains("automatic_model_unavailable"))
        #expect(f.loads == 0 && f.generations == 0)
        YouziResidentServicePreference.setAliases([f.image.alias], for: .image, in: f.preferences)
        YouziResidentServicePreference.setAliases([f.speech.alias], for: .speech, in: f.preferences)
        let image = try await f.call("youzi_generate_image", ["prompt": "moon"])
        let speech = try await f.call("youzi_synthesize_speech", ["text": "moon"])
        #expect(!image.isError && !speech.isError)
        #expect(f.loads == 0 && f.generations == 2 && f.tools.approval.pending == nil)
        let unknown = try await f.call("youzi_generate_image", ["model": "missing", "prompt": "moon"])
        #expect(unknown.content.contains("model_not_downloaded"))
        let wrongScene = try await f.call("youzi_generate_image", ["model": f.speech.alias, "prompt": "moon"])
        #expect(wrongScene.content.contains("capability_not_supported"))
        let blank = try await f.call("youzi_generate_image", ["model": "", "prompt": "moon"])
        #expect(blank.content.contains("invalid_arguments"))
        #expect(f.generations == 2)
        let discovery = try json(try await f.call("youzi_models"))
        let rows = try #require(discovery["models"] as? [[String: Any]])
        let row = try #require(rows.first { $0["model"] as? String == f.image.alias })
        #expect(row["loading_policy"] as? String == "automatic")
        #expect(row["automatic_for"] as? [String] == ["image"])
        #expect(row["preferred_for"] as? [String] == ["image"])
        #expect(row["default_for"] as? [String] == row["preferred_for"] as? [String])
    }

    @Test("Ready preferred models avoid allocations; explicit on-demand models remain exact")
    func reuseVersusExplicit() async throws {
        let f = Fixture()
        let resident = ModelEntry(alias: "already-loaded", hfRepo: "local/loaded", sizeOnDisk: "2 GiB", cached: true, kind: .image, imageCapability: .generation)
        f.additionalModels = [resident]
        f.ready = [resident.alias]
        YouziResidentServicePreference.setAliases([f.image.alias, resident.alias], for: .image, in: f.preferences)
        #expect(try await !f.call("youzi_generate_image", ["prompt": "moon"]).isError)
        #expect(f.generatedWith == [resident.alias] && f.loads == 0)
        // Remove the stopped model from the pool. An explicit request can still
        // use it, but only after approval, without replacing the pool member.
        YouziResidentServicePreference.setAliases([resident.alias], for: .image, in: f.preferences)
        let task = Task { try await f.call("youzi_generate_image", ["model": f.image.alias, "prompt": "moon"]) }
        let request = try await pending(f.tools.approval)
        #expect(request.alias == f.image.alias)
        f.tools.approval.resolve(id: request.id, allow: true)
        #expect(try await !task.value.isError)
        #expect(f.generatedWith == [resident.alias, f.image.alias])
        #expect(f.loads == 1 && f.ready.contains(resident.alias))
        #expect(YouziResidentServicePreference.aliases(for: .image, in: f.preferences) == [resident.alias])
    }

    @Test("Declining on-demand generation cannot cause fallback or repeated approval")
    func onDemandDenial() async throws {
        let f = Fixture()
        let args: [String: Any] = ["model": f.image.alias, "prompt": "moon"]
        let task = Task { try await f.call("youzi_generate_image", args) }
        let request = try await pending(f.tools.approval)
        f.tools.approval.resolve(id: request.id, allow: false)
        #expect(try await task.value.failureKind == .userDeclined)
        #expect(try await f.call("youzi_generate_image", args).failureKind == .userDeclined)
        #expect(f.loads == 0 && f.generations == 0 && f.tools.approval.pending == nil)
    }

    @Test("Invalid generation arguments never ask for startup")
    func invalidBeforeStartup() async throws {
        let f = Fixture()
        let invalid = try await f.call("youzi_generate_image", ["model": f.image.alias, "prompt": "moon", "approved": true])
        #expect(invalid.content.contains("invalid_arguments"))
        #expect(f.loads == 0 && f.tools.approval.pending == nil)
    }

    @Test("Human approval is required and cannot be supplied as a tool argument")
    func approval() async throws {
        let f = Fixture()
        let spoof = try await f.call("youzi_load_model", ["model": f.image.alias, "reason": "book", "approved": true])
        #expect(spoof.isError && f.loads == 0)
        let task = Task { try await f.call("youzi_load_model", ["model": f.image.alias, "reason": "Illustrations for your book"]) }
        let request = try await pending(f.tools.approval)
        #expect(f.loads == 0)
        f.tools.approval.resolve(id: request.id, allow: true)
        let result = try await task.value
        #expect(!result.isError && f.loads == 1)
        #expect(try json(result)["ready"] as? Bool == true)
        let again = try await f.call("youzi_load_model", ["model": f.image.alias, "reason": "same book"])
        #expect(!again.isError && f.loads == 1 && f.tools.approval.pending == nil)
    }

    @Test("Denial is not retried within the same user turn; a new turn may ask")
    func denial() async throws {
        let f = Fixture()
        let args: [String: Any] = ["model": f.speech.alias, "reason": "narration"]
        let task = Task { try await f.call("youzi_load_model", args) }
        let request = try await pending(f.tools.approval)
        f.tools.approval.resolve(id: request.id, allow: false)
        #expect(try await task.value.failureKind == .userDeclined)
        #expect(try await f.call("youzi_load_model", args).content.contains("user_declined"))
        #expect(f.loads == 0 && f.tools.approval.pending == nil)
        f.context.turnID = UUID()
        let next = Task { try await f.call("youzi_load_model", args) }
        let second = try await pending(f.tools.approval)
        f.tools.approval.resolve(id: second.id, allow: true)
        #expect(try await !next.value.isError)
    }

    @Test("Cancelling approval releases the tool and never loads a model")
    func cancellation() async throws {
        let f = Fixture()
        let task = Task { try await f.call("youzi_load_model", ["model": f.image.alias, "reason": "illustration"]) }
        _ = try await pending(f.tools.approval)
        task.cancel()
        #expect(try await task.value.content.contains("cancelled"))
        #expect(f.loads == 0 && f.tools.approval.pending == nil)
    }

    @Test("A delayed dismissal cannot deny a newer approval request")
    func staleApprovalDismissal() async throws {
        let store = YouziModelApprovalStore()
        let first = Task { await store.request(alias: "image", reason: "page", diskSize: nil) }
        let old = try await pending(store)
        store.resolve(id: old.id, allow: true)
        #expect(await first.value)
        let second = Task { await store.request(alias: "speech", reason: "narration", diskSize: nil) }
        let current = try await pending(store)
        store.resolve(id: old.id, allow: false)
        #expect(store.pending?.id == current.id)
        store.resolve(id: current.id, allow: true)
        #expect(await second.value)
    }

    @Test("A failed startup is never reported ready")
    func failedLoad() async throws {
        let f = Fixture(); f.loadFails = true
        let task = Task { try await f.call("youzi_load_model", ["model": f.image.alias, "reason": "illustration"]) }
        let request = try await pending(f.tools.approval)
        f.tools.approval.resolve(id: request.id, allow: true)
        #expect(try await task.value.content.contains("load_failed"))
        #expect(f.ready.isEmpty)
    }

    @Test("Native function dispatch produces image, narration and a real HTML artifact")
    func storybookWorkflow() async throws {
        let f = Fixture(); f.ready = [f.image.alias, f.speech.alias]
        let registry = BuiltinToolRegistry(); registry.localModels = f.tools
        let executor = NativeToolCallExecutor(registry: registry)
        func execute(_ name: String, _ args: [String: Any]) async throws -> ToolCallResult {
            let raw = String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)
            return await executor.execute(ToolCall(id: UUID().uuidString, name: name, arguments: raw), advertised: registry.definitions)
        }
        let image = try await execute("youzi_generate_image", ["model": f.image.alias, "prompt": "Tang poet looking at the moon, ink illustration"])
        let voice = try await execute("youzi_synthesize_speech", ["model": f.speech.alias, "text": "床前明月光，疑是地上霜。"])
        let imageID = try #require(try json(image)["artifact_id"] as? String)
        let voiceID = try #require(try json(voice)["artifact_id"] as? String)
        let book = try await execute("youzi_create_storybook", ["title": "静夜思", "pages": [["heading": "月光", "text": "床前明月光，疑是地上霜。", "image_id": imageID, "audio_id": voiceID]]])
        #expect(!image.isError && !voice.isError && !book.isError)
        #expect(f.generations == 2 && f.capturedSize == nil && f.capturedVoice == nil)
        let document = try #require(f.saved.values.first { $0.0.name.hasSuffix(".html") }?.0)
        let html = String(decoding: document.data, as: UTF8.self)
        #expect(html.contains("data:image/png;base64,"))
        #expect(html.contains("data:audio/wav;base64,"))
        #expect(html.contains("<audio controls"))
        #expect(html.contains("床前明月光"))
        #expect(html.contains("default-src 'none'"))
        #expect(f.saved.values.allSatisfy { $0.1.taskID == f.context.taskID })
    }

    @Test("Model text cannot inject scripts or remote resources into the published book")
    func safeHTML() throws {
        let book = YouziStorybook.Document(title: "<script>alert(1)</script>", pages: [
            .init(heading: "\" onload=\"evil()", text: "<img src=https://example.com/secret>", image_id: nil, audio_id: nil)
        ])
        let html = String(decoding: try YouziStorybook.render(book) { _ in throw YouziLocalModelTools.Failure.file_unavailable }, as: UTF8.self)
        #expect(!html.contains("<script>"))
        #expect(!html.contains("<img src=https"))
        #expect(html.contains("&lt;script&gt;"))
        #expect(html.contains("&quot; onload="))
        #expect(YouziLocalModelTools.safeName("../../private/test") == "privatetest")
    }

    @Test("Unknown and other-task artifact IDs cannot be used to read arbitrary files")
    func scopedArtifacts() async throws {
        let f = Fixture(); f.ready.insert(f.image.alias)
        let image = try await f.call("youzi_generate_image", ["model": f.image.alias, "prompt": "moon"])
        let id = try #require(try json(image)["artifact_id"] as? String)
        f.context = .init(taskID: UUID(), projectID: nil)
        let result = try await f.call("youzi_create_storybook", ["title": "book", "pages": [["heading": "moon", "text": "text", "image_id": id]]])
        #expect(result.isError && f.saved.count == 1)
        let path = try await f.call("youzi_create_storybook", ["title": "book", "pages": [["heading": "moon", "text": "text", "image_id": "/etc/passwd"]]])
        #expect(path.isError)
    }

    @Test("Inputs and book length are bounded")
    func bounds() async throws {
        let f = Fixture(); f.ready = [f.image.alias, f.speech.alias]
        #expect(try await f.call("youzi_generate_image", ["model": f.image.alias, "prompt": "moon", "size": "99999x99999"]).isError)
        #expect(try await f.call("youzi_synthesize_speech", ["model": f.speech.alias, "text": String(repeating: "a", count: 2001)]).isError)
        #expect(try await f.call("youzi_create_storybook", ["title": "book", "pages": []]).isError)
        #expect(try await f.call("youzi_generate_image", ["model": f.image.alias, "prompt": "moon", "size": "512xx512"]).isError)
        #expect(try await f.call("youzi_generate_image", ["model": f.image.alias, "prompt": "moon", "size": "512xbadx512"]).isError)
        #expect(f.generations == 0)
    }

    @Test("Late-attached native tools retain opt-outs after restart")
    func persistedOptOut() throws {
        let suite = "YouziLocalToolsTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = ChatViewModel(tools: BuiltinToolRegistry(), toolDefaults: defaults, persistsConversations: false)
        first.setToolEnabled("youzi_generate_image", false)
        let registry = BuiltinToolRegistry()
        let restarted = ChatViewModel(tools: registry, toolDefaults: defaults, persistsConversations: false)
        let fixture = Fixture()
        registry.localModels = fixture.tools
        restarted.reloadToolPreferences()
        #expect(!restarted.enabledDefinitions.contains { $0.function.name == "youzi_generate_image" })
        #expect(restarted.enabledDefinitions.contains { $0.function.name == "youzi_models" })
        #expect(YouziLocalModelTools.speechModelID(fixture.speech) == fixture.speech.hfRepo)
    }

    @Test("Speech voices are discoverable without loading or synthesizing")
    func voiceDiscovery() async throws {
        let f = Fixture()
        let result = try await f.call("youzi_speech_voices", ["model": f.speech.alias])
        #expect(!result.isError)
        #expect(f.loads == 0 && f.generations == 0)
        #expect(try json(result)["voices"] != nil)
        #expect(YouziLocalModelTools.failureMessage(content: #"{"error":"invalid_voice","secret":"do-not-display"}"#, chinese: true)?.contains("do-not-display") == false)
        #expect(YouziLocalModelTools.failureMessage(content: #"{"error":"private/path"}"#, chinese: false) == nil)
    }

    @Test("Schemas round-trip through OpenAI function format; local skill and budget are explicit")
    func schemasAndBudget() throws {
        let definitions = YouziLocalModelTools.definitions
        let encoded = try JSONEncoder().encode(definitions)
        #expect(try JSONDecoder().decode([ToolDefinition].self, from: encoded) == definitions)
        #expect(definitions.count == 6)
        #expect(ChatViewModel.toolExecutionBudget(enabled: definitions) == 24)
        #expect(ChatViewModel.toolExecutionBudget(enabled: [WebSearchTool.definition]) == 3)
        let messages = ChatViewModel.addingInstructionLayers(to: [ChatMessage(role: .user, content: "book")], ambientPreamble: nil,
            localToolContext: YouziLocalModelTools.skillInstructions, global: "", conversation: "")
        #expect(messages.first?.role == .system)
        #expect(messages.first?.content.contains("youzi_create_storybook") == true)
    }
}
