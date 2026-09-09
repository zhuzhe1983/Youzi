import Foundation
import Testing
import AppKit
import SwiftUI
@testable import Rapid

/// Fake credentials and isolated defaults only: never inspect the user's Keychain.
private final class RemoteTestSecrets: RemoteModelSecrets, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: String] = [:]
    var failWrites = false
    func read(_ id: UUID) throws -> String? { lock.withLock { values[id] } }
    func write(_ value: String?, for id: UUID) throws {
        try lock.withLock {
            if failWrites { throw RemoteModelError.keychain(-1) }
            values[id] = value?.isEmpty == false ? value : nil
        }
    }
}

/// All accesses are locked; this class is used only by this serialized suite.
private final class RemoteFixtureProtocol: URLProtocol, @unchecked Sendable {
    struct Record { let request: URLRequest; let body: Data }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var captured: [Record] = []
    nonisolated(unsafe) private static var reply: (Int, String, Data) = (200, "application/json", Data())
    static var records: [Record] { lock.withLock { captured } }
    static func reset(_ text: String, status: Int = 200, type: String = "application/json") {
        lock.withLock { captured = []; reply = (status, type, Data(text.utf8)) }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(contentsOf: buffer.prefix(n))
            }
        }
        let result = Self.lock.withLock {
            Self.captured.append(Record(request: request, body: body)); return Self.reply
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: result.0, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": result.1])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: result.2)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("RemoteModel contracts", .serialized)
@MainActor
struct RemoteModelTests {
    private func fixture() -> (RemoteModelSettings, UserDefaults, String, RemoteTestSecrets) {
        let name = "RemoteModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let secrets = RemoteTestSecrets()
        let settings = RemoteModelSettings(repository: .init(defaults: defaults, secrets: secrets))
        return (settings, defaults, name, secrets)
    }
    private func model(_ slot: RemoteModelSlot = .chat) -> RemoteModelConfiguration {
        var model = RemoteModelConfiguration()
        model.name = "Fixture \(slot.rawValue)"
        model.modelID = "provider-\(slot.rawValue)"
        model.baseURL = "https://provider.example/v1"
        model.slot = slot
        return model
    }
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RemoteFixtureProtocol.self]
        return URLSession(configuration: config)
    }
    private func jsonBody() throws -> [String: Any] {
        let record = try #require(RemoteFixtureProtocol.records.last)
        return try #require(JSONSerialization.jsonObject(with: record.body) as? [String: Any])
    }
    private func request(_ alias: String) -> ChatStreamClient.Request {
        .init(alias: alias, messages: [ChatMessage(role: .user, content: "Fixture only")])
    }

    @Test("Root URLs gain /v1; custom gateway prefixes and optional HTTP are preserved")
    func urls() throws {
        #expect(try RemoteModelEndpoint.normalizedBaseURL(" https://provider.example/ ", allowHTTP: false).absoluteString == "https://provider.example/v1")
        #expect(try RemoteModelEndpoint.normalizedBaseURL("https://provider.example/gateway/v1/", allowHTTP: false).path == "/gateway/v1")
        #expect(try RemoteModelEndpoint.normalizedBaseURL("http://127.0.0.1:9123/v1", allowHTTP: true).port == 9123)
        let endpoint = try RemoteModelEndpoint(configuration: model(), apiKey: "fixture-key")
        #expect(endpoint.url("v1/videos").path == "/v1/videos")
        #expect(endpoint.request("models").value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
        #expect(!String(reflecting: endpoint).contains("fixture-key"))
    }

    @Test("Reject ambiguous URLs and endpoint names", arguments: [
        "https://user:pass@provider.example/v1", "https://provider.example/v1?key=secret",
        "https://provider.example/#frag", "ftp://provider.example/v1", "https://provider.example:0/v1",
        "https://provider.example:65536/v1", "https://provider.example/v1/models", "https://provider.example/v1/images/edits",
        "https://provider.example/a/../v1", "https://provider.example/%2e%2e/v1", "https://provider.example/a//b",
        "http://127.0.0.1:9123/v1", "https://provider.example/v1/audio/speech", "https://provider.example/%250a/v1"
    ])
    func badURLs(_ text: String) {
        #expect(throws: (any Error).self) { try RemoteModelEndpoint.normalizedBaseURL(text, allowHTTP: false) }
    }

    @Test("Keys stay outside JSON; preserve, clear, remove and failure are explicit")
    func persistence() throws {
        let (settings, defaults, name, secrets) = fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        var value = model()
        try settings.save(value, key: "fixture-key")
        let saved = try #require(defaults.data(forKey: RemoteModelRepository.key))
        #expect(!String(decoding: saved, as: UTF8.self).contains("fixture-key"))
        value.name = "Renamed"
        try settings.save(value, key: nil)
        #expect(try settings.repository.endpoint(alias: value.alias)?.apiKey == "fixture-key")
        secrets.failWrites = true
        value.name = "Must not persist"
        #expect(throws: (any Error).self) { try settings.save(value, key: "replacement") }
        #expect(settings.document.models.first?.name == "Renamed")
        #expect(try settings.repository.load().models.first?.name == "Renamed")
        secrets.failWrites = false
        try settings.save(value, key: "")
        #expect(try secrets.read(value.id) == nil)
        try settings.remove(value.id)
        #expect(settings.document.models.isEmpty)
    }

    @Test("Corrupt or future metadata is preserved, never silently reset", arguments: ["bad-json", "{\"version\":99,\"models\":[],\"globalPriority\":\"localFirst\",\"overrides\":{},\"preferred\":{}}"])
    func corrupt(_ text: String) throws {
        let (_, defaults, name, secrets) = fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        let data = Data(text.utf8)
        defaults.set(data, forKey: RemoteModelRepository.key)
        let settings = RemoteModelSettings(repository: .init(defaults: defaults, secrets: secrets))
        #expect(settings.loadError != nil)
        #expect(throws: (any Error).self) { try settings.save(model(), key: "fixture-key") }
        #expect(defaults.data(forKey: RemoteModelRepository.key) == data)
    }

    @Test("Host/path changes require explicit credentials for save AND discovery")
    func changedEndpoint() throws {
        let (settings, defaults, name, _) = fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        var value = model(.speech)
        try settings.save(value, key: "fixture-key")
        value.baseURL = "https://different.example/gateway"
        #expect(throws: (any Error).self) { try settings.save(value, key: nil) }
        #expect(throws: (any Error).self) { try settings.discoveryEndpoint(value, key: nil) }
        // Discovery isn't inference: invalid voice presets shouldn't block a list probe.
        value.voices = ""
        let probe = try settings.discoveryEndpoint(value, key: "")
        #expect(probe.apiKey == nil)
        #expect(probe.baseURL.host == "different.example")
        #expect(throws: (any Error).self) { try RemoteModelEndpoint(configuration: model(), apiKey: "bad\r\nkey") }
    }

    @Test("Global and per-kind priorities cover all slots; explicit routing never falls back", arguments: RemoteModelSlot.allCases)
    func priorities(_ slot: RemoteModelSlot) throws {
        var first = model(slot)
        var second = model(slot); second.modelID = "second"
        var doc = RemoteModelDocument(models: [first, second])
        #expect(doc.automatic(for: slot, local: "local-ready") == "local-ready")
        #expect(doc.automatic(for: slot, local: nil) == first.alias)
        doc.globalPriority = .remoteFirst
        #expect(doc.automatic(for: slot, local: "local-ready") == first.alias)
        doc.preferred[slot.rawValue] = second.id
        #expect(doc.automatic(for: slot, local: "local-ready") == second.alias)
        second.enabled = false; doc.models = [first, second]
        #expect(doc.automatic(for: slot, local: "local-ready") == first.alias)
        doc.overrides[slot.kind.rawValue] = .localFirst
        #expect(doc.automatic(for: slot, local: "local-ready") == "local-ready")
        first.enabled = false; doc.models = [first, second]
        #expect(doc.automatic(for: slot, local: nil) == nil)
        #expect(RemoteModelDocument().automatic(for: slot, local: "existing-local") == "existing-local")
    }

    @Test("Remote routing does not start a process or claim downloads/residency")
    func noLocalStartup() async throws {
        let (settings, defaults, name, _) = fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        let server = ServerManager(testingState: .stopped, sessionDefaults: defaults)
        server.remoteModelSettings = settings
        for slot in RemoteModelSlot.allCases {
            let value = model(slot); try settings.save(value, key: "")
            #expect(!value.entry.cached && value.entry.isRemote && value.entry.sizeOnDisk == nil)
            #expect(!server.isModelResident(value.alias))
            #expect(await server.ensureServing(alias: value.alias))
            #expect(try settings.repository.endpoint(alias: value.alias, slot: slot)?.modelID == value.modelID)
            let wrong: RemoteModelSlot = slot == .chat ? .speech : .chat
            #expect(throws: (any Error).self) { try settings.repository.endpoint(alias: value.alias, slot: wrong) }
        }
        #expect(server.servingAlias == nil)
        if case .stopped = server.state {} else { Issue.record("Remote routing changed local process state") }
    }

    @Test("OpenAI chat SSE, tools and usage use provider ID/key without local extensions")
    func chat() async throws {
        let (settings, defaults, name, _) = fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        let value = model(); try settings.save(value, key: "fixture-key")
        let transport = session(); defer { transport.invalidateAndCancel() }
        var client = ChatStreamClient(session: transport); client.remoteRepository = settings.repository
        RemoteFixtureProtocol.reset("""
        data: {"choices":[{"index":0,"delta":{"content":"hello "}}]}

        data: {"choices":[{"index":0,"delta":{"content":"world"},"finish_reason":"stop"}]}

        data: {"choices":[],"usage":{"prompt_tokens":7,"completion_tokens":2}}

        data: [DONE]


        """, type: "text/event-stream")
        var text = ""; var usage = 0; var finished = false
        try await client.send(request(value.alias), bearerToken: "local-only") { event in
            switch event {
            case .content(let delta): text += delta
            case .usage(let p, let c): usage = p + c
            case .finished: finished = true
            default: break
            }
        }
        #expect(text == "hello world" && usage == 9 && finished)
        let body = try jsonBody()
        #expect(body["model"] as? String == value.modelID)
        #expect(body["chat_template_kwargs"] == nil && body["repetition_penalty"] == nil)
        #expect(RemoteFixtureProtocol.records.first?.request.url?.path == "/v1/chat/completions")
        #expect(RemoteFixtureProtocol.records.first?.request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
        RemoteFixtureProtocol.reset("""
        data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_fixture","type":"function","function":{"name":"fixture_tool","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}

        data: [DONE]


        """, type: "text/event-stream")
        var toolCount = 0
        try await client.send(request(value.alias)) { if case .toolCalls(let calls) = $0 { toolCount = calls.count } }
        #expect(toolCount == 1)
    }

    @Test("Remote errors are not retried and anonymous requests never inherit local keys")
    func noRetryOrCredentialLeak() async throws {
        let (settings, defaults, name, _) = fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        var value = model(); try settings.save(value, key: "")
        let transport = session(); defer { transport.invalidateAndCancel() }
        var client = ChatStreamClient(session: transport); client.remoteRepository = settings.repository
        RemoteFixtureProtocol.reset("do-not-echo-provider-error", status: 503)
        do { try await client.send(request(value.alias), bearerToken: "local-only") { _ in }; Issue.record("Expected error") }
        catch { #expect(!error.localizedDescription.contains("do-not-echo")) }
        #expect(RemoteFixtureProtocol.records.count == 1)
        #expect(RemoteFixtureProtocol.records.first?.request.value(forHTTPHeaderField: "Authorization") == nil)
        value.enabled = false; try settings.save(value, key: nil)
        RemoteFixtureProtocol.reset("{}")
        do { try await client.send(request(value.alias)) { _ in }; Issue.record("Disabled remote must fail") } catch {}
        #expect(RemoteFixtureProtocol.records.isEmpty)
    }

    @Test("ASR uses standard multipart prompt/model; TTS uses WAV and configured voices")
    func audio() async throws {
        let (settings, defaults, name, _) = fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        let asr = model(.transcription); var tts = model(.speech); tts.voices = "alloy,nova"
        try settings.save(asr, key: "fixture-asr"); try settings.save(tts, key: "")
        let transport = session(); defer { transport.invalidateAndCancel() }
        var client = AudioClient(); client.remoteRepository = settings.repository; client.remoteSession = transport
        RemoteFixtureProtocol.reset(#"{"text":"hello"}"#)
        let result = try await client.transcribe(audioData: Data("RIFFfixture".utf8), model: asr.alias, context: "names", port: 1, bearer: "local-only")
        #expect(result.text == "hello")
        let record = try #require(RemoteFixtureProtocol.records.first)
        let body = String(decoding: record.body, as: UTF8.self)
        #expect(body.contains("name=\"prompt\"\r\n\r\nnames"))
        #expect(!body.contains("name=\"context\""))
        #expect(body.contains(asr.modelID))
        #expect(record.request.url?.path == "/v1/audio/transcriptions")
        #expect(record.request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-asr")
        RemoteFixtureProtocol.reset("RIFFfixture", type: "audio/wav")
        #expect(try await client.voices(model: tts.alias, port: 1, bearer: "local-only") == ["alloy", "nova"])
        #expect(RemoteFixtureProtocol.records.isEmpty)
        let audio = try await client.synthesize(text: "hello", model: tts.alias, voice: "nova", speed: 1.1, port: 1, bearer: "local-only")
        #expect(audio.data == Data("RIFFfixture".utf8))
        let speechBody = try jsonBody()
        #expect(speechBody["model"] as? String == tts.modelID && speechBody["voice"] as? String == "nova")
        #expect(speechBody["response_format"] as? String == "wav")
        #expect(RemoteFixtureProtocol.records.first?.request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("Images support provider-default/base64 and edits without local-only fields")
    func images() async throws {
        let (settings, defaults, name, _) = fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        var value = model(.image); value.supportsImageEditing = true
        try settings.save(value, key: "fixture-image")
        let transport = session(); defer { transport.invalidateAndCancel() }
        var client = ImageClient(); client.remoteRepository = settings.repository; client.remoteSession = transport
        RemoteFixtureProtocol.reset(#"{"data":[{"b64_json":"aW1hZ2U="}]}"#)
        let output = try await client.generate(prompt: "fixture", model: value.alias, size: "1024x1024", count: 1, seed: 42, port: 1, bearer: "local-only")
        #expect(output.first?.pngData == Data("image".utf8))
        var body = try jsonBody()
        #expect(body["model"] as? String == value.modelID && body["seed"] == nil && body["response_format"] == nil)
        value.imageResponseFormat = "b64_json"; try settings.save(value, key: nil)
        _ = try await client.generate(prompt: "fixture", model: value.alias, count: 1, seed: 42, port: 1, bearer: nil)
        body = try jsonBody(); #expect(body["response_format"] as? String == "b64_json")
        _ = try await client.edit(imagePNG: Data("fixture".utf8), prompt: "fixture", model: value.alias, count: 1, seed: 42, port: 1, bearer: "local-only")
        let edit = try #require(RemoteFixtureProtocol.records.last)
        let multipart = String(decoding: edit.body, as: UTF8.self)
        #expect(edit.request.url?.path == "/v1/images/edits")
        #expect(!multipart.contains("name=\"seed\""))
        #expect(multipart.contains(value.modelID))
        #expect(edit.request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-image")
        let count = RemoteFixtureProtocol.records.count
        #expect(await client.fetchProgress(model: value.alias, port: 1, bearer: nil) == nil)
        await client.cancel(model: value.alias, port: 1, bearer: nil)
        #expect(RemoteFixtureProtocol.records.count == count)
    }

    @Test("Provider image URLs use a separate credential-free downloader")
    func imageURLs() async throws {
        let (settings, defaults, name, _) = fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        let value = model(.image); try settings.save(value, key: "fixture-image")
        let transport = session(); defer { transport.invalidateAndCancel() }
        var client = ImageClient(); client.remoteRepository = settings.repository; client.remoteSession = transport
        client.remoteImageDownload = { url in
            #expect(url.host == "cdn.example")
            return Data("downloaded-fixture".utf8)
        }
        RemoteFixtureProtocol.reset(#"{"data":[{"url":"https://cdn.example/image.png"}]}"#)
        let result = try await client.generate(prompt: "fixture", model: value.alias, count: 1, seed: nil, port: 1, bearer: nil)
        #expect(result.first?.pngData == Data("downloaded-fixture".utf8))
        for text in ["http://cdn.example/a", "https://user:pass@cdn.example/a", "https://cdn.example/a#frag"] {
            #expect(throws: (any Error).self) { try RemoteImageDownload.validateURL(URL(string: text)!) }
        }
        do { _ = try await RemoteImageDownload.fetch(URL(string: "https://127.0.0.1/private")!); Issue.record("Private IP must fail") } catch {}
    }

    private var jobJSON: String { #"{"id":"video_fixture","model":"provider-video","prompt":null,"seconds":"4","size":"720x1280","status":"queued","progress":0,"created_at":1}"# }
    @Test("Video create/poll use OpenAI fields, not local seed/capabilities/cancel extensions")
    func video() async throws {
        let value = model(.video)
        let endpoint = try RemoteModelEndpoint(configuration: value, apiKey: "fixture-video")
        let transport = session(); defer { transport.invalidateAndCancel() }
        var client = VideoClient(remoteEndpoint: endpoint); client.remoteSession = transport
        RemoteFixtureProtocol.reset(jobJSON)
        let presets = try await client.capabilities(model: value.alias, port: 1, bearer: "local-only")
        #expect(presets.sizePresets == value.sizes)
        #expect(presets.durationPresets(for: value.sizes[0]) == [4, 8, 12])
        #expect(RemoteFixtureProtocol.records.isEmpty)
        let job = try await client.create(.init(prompt: "fixture", model: value.alias, seconds: 4, size: "720x1280", seed: 42, reference: nil, referenceFileName: nil, referenceMIMEType: nil), port: 1, bearer: "local-only")
        #expect(job.prompt.isEmpty)
        let record = try #require(RemoteFixtureProtocol.records.last)
        let body = String(decoding: record.body, as: UTF8.self)
        #expect(body.contains(value.modelID) && !body.contains("name=\"seed\""))
        #expect(record.request.url?.path == "/v1/videos")
        #expect(record.request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-video")
        _ = try await client.retrieve(id: job.id, port: 1, bearer: "local-only")
        #expect(RemoteFixtureProtocol.records.last?.request.url?.path == "/v1/videos/video_fixture")
        RemoteFixtureProtocol.reset("{\"data\":[\(jobJSON)]}")
        #expect(try await client.list(port: 1, bearer: nil).count == 1)
        let count = RemoteFixtureProtocol.records.count
        do { try await client.cancelPending(id: job.id, port: 1, bearer: nil); Issue.record("Remote queued cancellation must not delete") } catch {}
        do { _ = try await client.videoData(id: job.id, maximumBytes: 100, port: 1, bearer: nil); Issue.record("Local tool API must reject remote") } catch {}
        #expect(RemoteFixtureProtocol.records.count == count)
    }

    @Test("Discovery reads only /models and deduplicates IDs without inference")
    func discovery() async throws {
        let endpoint = try RemoteModelEndpoint(configuration: model(), apiKey: nil)
        let transport = session(); defer { transport.invalidateAndCancel() }
        RemoteFixtureProtocol.reset(#"{"object":"list","data":[{"id":"z","object":"model"},{"id":"a"},{"id":"z"}]}"#)
        #expect(try await endpoint.discover(session: transport) == ["a", "z"])
        #expect(RemoteFixtureProtocol.records.count == 1)
        #expect(RemoteFixtureProtocol.records.first?.request.url?.path == "/v1/models")
        #expect(RemoteFixtureProtocol.records.first?.request.httpMethod == "GET")
    }

    @Test("Video pins a provider until reconnect; disabling blocks new work, not active polling")
    func videoSessionPinning() async throws {
        let (settings, defaults, name, _) = fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        var value = model(.video)
        try settings.save(value, key: "fixture-original")
        let server = ServerManager(testingState: .stopped, sessionDefaults: defaults)
        server.remoteModelSettings = settings
        let transport = session()
        defer { transport.invalidateAndCancel() }
        let vm = VideoGenViewModel(server: server, generationDefaults: ModelGenerationDefaults(defaults: defaults), pollingInterval: .seconds(3600), catalogLoader: { _ in [] })
        vm.remoteSettings = settings
        vm.remoteClientFactory = { endpoint in
            var client = VideoClient(remoteEndpoint: endpoint)
            client.remoteSession = transport
            return client
        }
        vm.selectedAlias = value.alias
        RemoteFixtureProtocol.reset(#"{"data":[]}"#)
        await vm.prepareSelectedModel()
        #expect(vm.isServerReady)
        vm.prompt = "fixture video"
        #expect(vm.canSubmit)

        value.baseURL = "https://replacement.example/v1"
        try settings.save(value, key: "fixture-replacement")
        RemoteFixtureProtocol.reset(jobJSON)
        await vm.submit()
        #expect(RemoteFixtureProtocol.records.last?.request.url?.host == "provider.example")
        #expect(RemoteFixtureProtocol.records.last?.request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-original")
        #expect(vm.hasLiveActiveJobs && !vm.canSwitchModels)
        let submittedCount = RemoteFixtureProtocol.records.count
        await vm.prepareSelectedModel()
        #expect(RemoteFixtureProtocol.records.count == submittedCount)

        value.enabled = false
        try settings.save(value, key: nil)
        vm.prompt = "must not send"
        #expect(!vm.canSubmit)
        await vm.submit()
        #expect(RemoteFixtureProtocol.records.count == submittedCount)
        await vm.pollJobs()
        #expect(RemoteFixtureProtocol.records.last?.request.url?.host == "provider.example")
        #expect(RemoteFixtureProtocol.records.last?.request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-original")
        #expect(vm.selectedModel?.alias == value.alias)
        // Finish without a content download, which also tears down the polling task.
        RemoteFixtureProtocol.reset(jobJSON.replacingOccurrences(of: "queued", with: "failed"))
        await vm.pollJobs()
        #expect(!vm.hasLiveActiveJobs && vm.canSwitchModels)
        value.enabled = true
        try settings.save(value, key: nil)
        RemoteFixtureProtocol.reset(#"{"data":[]}"#)
        await vm.prepareSelectedModel()
        #expect(RemoteFixtureProtocol.records.last?.request.url?.host == "replacement.example")
        #expect(RemoteFixtureProtocol.records.last?.request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-replacement")
    }

    @Test("Remote settings and editor render with isolated synthetic data", .enabled(if: ProcessInfo.processInfo.environment["YOUZI_REMOTE_VISUAL_QA"] == "1"))
    func visualSettings() async throws {
        let (settings, defaults, name, _) = fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        let i18n = YouziI18nConfig(defaults: defaults)
        for slot in RemoteModelSlot.allCases { try settings.save(model(slot), key: "") }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("youzi-remote-visual-qa")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        host.sizingOptions = []
        let window = NSWindow(contentRect: CGRect(x: 50, y: 50, width: 860, height: 680),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Youzi Remote Models QA — synthetic data"
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }
        for english in [false, true] {
            i18n.language = english ? .en : .zhHans
            window.appearance = NSAppearance(named: english ? .aqua : .darkAqua)
            var cases: [(String, AnyView, CGSize)] = [
                ("collapsed", AnyView(SettingsRemoteModelsPanel(settings: settings).padding(20)), CGSize(width: 860, height: 680)),
                ("expanded", AnyView(SettingsRemoteModelsPanel(settings: settings, expanded: true).padding(20)), CGSize(width: 860, height: 680)),
                ("audio", AnyView(SettingsRemoteModelsPanel(kind: .audio, settings: settings, expanded: true).padding(20)), CGSize(width: 860, height: 680)),
            ]
            for slot in RemoteModelSlot.allCases {
                cases.append(("editor-\(slot.rawValue)", AnyView(RemoteModelEditor(model: model(slot), settings: settings)), CGSize(width: 620, height: 650)))
            }
            for (label, view, size) in cases {
                let identity = "\(english ? "en" : "zh")-\(label)"
                window.setContentSize(size)
                host.rootView = AnyView(view.id(identity).environment(i18n).defaultAppStorage(defaults)
                    .frame(width: size.width, height: size.height)
                    .background(Color(nsColor: .windowBackgroundColor)))
                try await Task.sleep(for: .milliseconds(300))
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("\(identity).png"))
            }
        }
    }
}
