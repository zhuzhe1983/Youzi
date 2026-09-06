import Foundation
import Testing
@testable import Rapid

/// Opt-in only: an explicitly owned loopback service, downloaded models and an
/// isolated output directory. Never starts/stops the user's desktop or engine.
@MainActor
@Suite("Local multimodal live contract", .serialized)
struct YouziMultimodalLiveTests {
    @Test("Real LLM selects native tools and publishes an illustrated narrated book",
          .enabled(if: ProcessInfo.processInfo.environment["YOUZI_MULTIMODAL_LIVE"] == "1"))
    func storybook() async throws {
        let env = ProcessInfo.processInfo.environment
        let port = try #require(env["YOUZI_LIVE_PORT"].flatMap(Int.init))
        try #require((1024...65535).contains(port) && port != 8000)
        let binary = try #require(env["YOUZI_LIVE_BINARY"])
        let key = try #require(env["YOUZI_LIVE_KEY"])
        let output = URL(fileURLWithPath: try #require(env["YOUZI_LIVE_OUTPUT"]), isDirectory: true)
        // Caller must explicitly provision a fresh directory; no user data writes.
        try #require(FileManager.default.fileExists(atPath: output.path))
        try #require(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
        let base = URL(string: "http://127.0.0.1:\(port)")!
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.connectionProxyDictionary = [:]
        sessionConfig.timeoutIntervalForRequest = 600
        let session = URLSession(configuration: sessionConfig)
        defer { session.invalidateAndCancel() }
        func request(_ path: String, body: [String: Any]? = nil) async throws -> Data {
            var req = URLRequest(url: base.appendingPathComponent(path))
            req.timeoutInterval = 600
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            if let body {
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
            let (data, response) = try await session.data(for: req)
            try #require((response as? HTTPURLResponse)?.statusCode == 200)
            return data
        }
        func snapshot() async throws -> ModelResidencySnapshot {
            try JSONDecoder().decode(ModelResidencySnapshot.self, from: await request("v1/models/residency"))
        }
        let catalog = try #require(await ModelCatalog.scenarioMediaEntries(binary: URL(fileURLWithPath: binary)))
        let image = try #require(catalog.first { $0.alias == "z-image-turbo" && $0.cached })
        let speech = try #require(catalog.first { $0.alias == "qwen3-tts-4bit" && $0.cached })
        let chatAlias = env["YOUZI_LIVE_CHAT"] ?? "qwen3.8-27b-4bit"
        let initial = try await snapshot()
        try #require(initial.models.contains { $0.matches(chatAlias) })
        try #require(!YouziScenarioModels.isReady(image, in: initial))
        try #require(!YouziScenarioModels.isReady(speech, in: initial))
        let context = YouziLocalModelTools.Context(taskID: UUID(), projectID: nil, turnID: UUID())
        var assets: [UUID: YouziLocalModelTools.Asset] = [:]
        var paths: [String] = []
        let tools = YouziLocalModelTools(dependencies: .init(
            catalog: { [image, speech] },
            snapshot: { (try? await snapshot()) ?? .empty },
            load: { entry in
                do {
                    if entry.kind == .audio {
                        _ = try await request("v1/audio/models/load", body: ["model": entry.hfRepo ?? entry.alias])
                    } else {
                        _ = try await request("v1/models/load", body: ["model": entry.alias, "estimated_size_gb": 8, "pin": true, "image_mode": "generation"])
                    }
                    return true
                } catch { return false }
            },
            image: { prompt, entry, size in
                let images = try await ImageClient().generate(prompt: prompt, model: entry.alias,
                    size: size ?? "512x512", count: 1, seed: 42, port: port, bearer: key)
                return try #require(images.first).pngData
            },
            speech: { text, entry, voice in
                try await YouziLocalModelTools.synthesizeLocally(text: text, entry: entry,
                    voice: voice ?? "vivian", port: port, bearer: key)
            },
            context: { context },
            save: { data, name, _, kind, owner in
                try #require(owner == context)
                let id = UUID()
                let filename = "\(id.uuidString)-\(name)"
                try data.write(to: output.appendingPathComponent(filename), options: .withoutOverwriting)
                assets[id] = .init(id: id, name: name, kind: kind,
                    mime: kind == .image ? "image/png" : "audio/wav", data: data)
                paths.append(filename)
                return .init(artifactID: id, fileID: UUID(), name: name)
            },
            read: { id, owner in
                try #require(owner == context)
                return try #require(assets[id])
            }
        ))
        let registry = BuiltinToolRegistry(); registry.localModels = tools
        let executor = NativeToolCallExecutor(registry: registry)
        // Only the test harness resolves requests. Production requires a button
        // click; no test switch exists in the production approval store.
        var approvals: [String] = []
        let approver = Task { @MainActor in
            while !Task.isCancelled {
                if let pending = tools.approval.pending {
                    approvals.append(pending.alias)
                    tools.approval.resolve(id: pending.id, allow: true)
                }
                try? await Task.sleep(for: .milliseconds(25))
            }
        }
        defer { approver.cancel() }
        let client = ChatStreamClient(baseURL: base, session: session)
        var messages = [
            ChatMessage(role: .system, content: YouziLocalModelTools.skillInstructions),
            ChatMessage(role: .user, content: "请直接制作《静夜思》的一页唐诗小人书：一张512x512水墨插图，一段vivian中文语音朗读四句原诗，网页正文含四句诗和一句赏析，最后保存离线HTML文件。不是只写方案或代码。")
        ]
        var callsSeen: [String] = []
        var finished = false
        for _ in 0..<12 {
            var text = ""
            var calls: [ToolCall] = []
            try await client.send(.init(alias: chatAlias, messages: messages,
                temperature: 0, maxTokens: 2048, tools: YouziLocalModelTools.definitions, enableThinking: false),
                bearerToken: key) { event in
                switch event {
                case .content(let delta): text += delta
                case .toolCalls(let batch): calls = batch
                default: break
                }
            }
            messages.append(.init(role: .assistant, content: text, toolCalls: calls.isEmpty ? nil : calls))
            if calls.isEmpty { finished = true; break }
            try #require(callsSeen.count + calls.count <= 16)
            for call in calls {
                callsSeen.append(call.function.name)
                let result = await executor.execute(call, advertised: YouziLocalModelTools.definitions)
                print("LIVE_TOOL \(call.function.name) success=\(!result.isError)")
                try #require(!result.isError)
                messages.append(.init(role: .tool, content: result.content, toolCallID: call.id))
            }
        }
        #expect(finished)
        #expect(Set(callsSeen).isSuperset(of: YouziLocalModelTools.definitions.map { $0.function.name }))
        #expect(Set(approvals) == [image.alias, speech.alias])
        let html = try #require(assets.values.first { $0.name.hasSuffix(".html") })
        let text = String(decoding: html.data, as: UTF8.self)
        #expect(text.contains("data:image/png;base64,") && text.contains("data:audio/wav;base64,"))
        #expect(text.contains("床前明月光") && text.contains("<audio controls"))
        let final = try await snapshot()
        #expect(final.models.contains { $0.matches(chatAlias) })
        #expect(YouziScenarioModels.isReady(image, in: final))
        #expect(YouziScenarioModels.isReady(speech, in: final))
        #expect(final.evictionsTotal == initial.evictionsTotal)
        let report: [String: Any] = ["calls": callsSeen, "approvals_simulated_by_test": approvals,
            "artifacts": paths, "evictions": final.evictionsTotal - initial.evictionsTotal,
            "html_bytes": html.data.count, "chat_image_speech_ready": true]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("verification.json"))
    }
}
