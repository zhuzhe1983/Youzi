import Foundation
import Testing
import AppKit
import SwiftUI
@testable import Rapid

private struct RemoteKeychainFixture: KeychainItemAccessing {
    let result: KeychainReadResult
    var writesSucceed = false
    func query(account: String, service: String) -> KeychainReadResult { result }
    func upsert(account: String, service: String, secret: String) -> Bool { writesSucceed }
    func remove(account: String, service: String) -> Bool { writesSucceed }
}

@Suite("Remote credential availability")
struct RemoteCredentialAvailabilityTests {
    @Test("Unavailable credentials fail closed instead of becoming an unauthenticated request")
    func unavailableIsNotMissing() throws {
        let id = UUID()
        let blocked = RemoteModelKeychain(items: RemoteKeychainFixture(result: .unavailable))
        #expect(throws: (any Error).self) { try blocked.read(id) }
        #expect(throws: (any Error).self) { try blocked.write("fixture", for: id) }
        #expect(throws: (any Error).self) { try blocked.write(nil, for: id) }
        #expect(try RemoteModelKeychain(items: RemoteKeychainFixture(result: .missing)).read(id) == nil)
        #expect(try RemoteModelKeychain(items: RemoteKeychainFixture(result: .found("fixture"))).read(id) == "fixture")
    }
}

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
    @Test func localNameFollowsModelUntilCustomizedAndPersists() throws {
        let (settings, defaults, suite, _) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        var draft = RemoteModelConfiguration(baseURL: "https://provider.example/v1")
        draft.selectModelID("provider-chat")
        #expect(draft.name == "provider-chat")
        draft.selectModelID("provider-chat-plus")
        #expect(draft.name == "provider-chat-plus")
        draft.name = "工作助手"
        draft.selectModelID("provider-chat-latest")
        #expect(draft.name == "工作助手")
        try settings.save(draft, key: "")
        let saved = try #require(settings.repository.load().model(alias: draft.alias))
        #expect(saved.displayName == "工作助手")
        #expect(saved.modelID == "provider-chat-latest")
        #expect(settings.entries(kind: .chat).map(\.alias) == [draft.alias])
        #expect(settings.entries(kind: .image).isEmpty)
        draft.name = "  "
        try settings.save(draft, key: nil)
        #expect(try settings.repository.load().model(alias: draft.alias)?.name == draft.modelID)
    }

    @Test func publicServiceCatalogueOnlyReadsLocalServer() async throws {
        let client = ModelServiceCatalogClient(session: session())
        RemoteFixtureProtocol.reset(#"{"data":[{"id":"local-chat","capabilities":["text"]},{"id":"local-image","capabilities":["image"]}]}"#)
        let models = try await client.models(port: 8123, bearer: "fixture-local-key")
        #expect(models.map(\.id) == ["local-chat", "local-image"])
        let request = try #require(RemoteFixtureProtocol.records.first?.request)
        #expect(request.url?.absoluteString == "http://127.0.0.1:8123/v1/models")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-local-key")
        RemoteFixtureProtocol.reset(#"{"data":[]}"#)
        #expect(try await client.models(port: 8123, bearer: "fixture-local-key").isEmpty)
        RemoteFixtureProtocol.reset("{}", status: 401)
        await #expect(throws: ModelServiceCatalogClient.Failure.self) {
            try await client.models(port: 8123, bearer: "fixture-local-key")
        }
        RemoteFixtureProtocol.reset("{}")
        await #expect(throws: ModelServiceCatalogClient.Failure.self) {
            try await client.models(port: 8123, bearer: "")
        }
        #expect(RemoteFixtureProtocol.records.isEmpty)
    }

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

    @Test("Reusing a service copies credentials only to a new model at the same base")
    func reuseService() throws {
        let (settings, defaults, name, secrets) = fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        let source = model(); try settings.save(source, key: "fixture-shared")
        var image = model(.image)
        #expect(try settings.discoveryEndpoint(image, key: nil, inheritingFrom: source.id).apiKey == "fixture-shared")
        #expect(try secrets.read(image.id) == nil) // Discovery does not persist the draft.
        image.baseURL = "https://provider.example/another-gateway"
        #expect(throws: (any Error).self) { try settings.discoveryEndpoint(image, key: nil, inheritingFrom: source.id) }
        #expect(throws: (any Error).self) { try settings.save(image, key: nil, inheritingFrom: source.id) }
        image.baseURL = source.baseURL + "/"
        #expect(throws: (any Error).self) { try settings.save(image, key: "other-key", inheritingFrom: source.id) }
        try settings.save(image, key: nil, inheritingFrom: source.id)
        #expect(try secrets.read(image.id) == "fixture-shared")
        #expect(throws: (any Error).self) { try settings.save(image, key: nil, inheritingFrom: source.id) }
        try settings.remove(source.id)
        #expect(try settings.repository.endpoint(alias: image.alias)?.apiKey == "fixture-shared")
        let video = model(.video)
        #expect(throws: (any Error).self) { try settings.save(video, key: nil, inheritingFrom: source.id) }
        #expect(!String(decoding: try #require(defaults.data(forKey: RemoteModelRepository.key)), as: UTF8.self).contains("fixture-shared"))
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

    @Test("One GUI preference controls default routing and only its local startup", arguments: RemoteModelSlot.allCases)
    func unifiedPreference(_ remoteSlot: RemoteModelSlot) throws {
        let (settings, defaults, suite, _) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let slot = try #require(YouziResidentServicePreference.Slot(rawValue: remoteSlot.rawValue))
        var remote = model(remoteSlot); remote.enabled = false
        try settings.save(remote, key: "")
        let local = ModelEntry(alias: "local-preferred", hfRepo: "fixture/local", sizeOnDisk: "1 GB", cached: true,
            kind: remoteSlot.kind, audioCapability: remote.entry.audioCapability, imageCapability: remote.entry.imageCapability)
        let server = ServerManager(testingState: .ready(alias: "already-loaded"), sessionDefaults: defaults)
        server.remoteModelSettings = settings
        defaults.set(["legacy-first", "legacy-second"], forKey: slot.selectionKey)
        try settings.prefer(local.alias, for: remoteSlot)
        #expect(YouziResidentServicePreference.aliases(for: slot, in: defaults) == [local.alias])
        #expect(YouziResidentServicePreference.startupEntry(entries: [local], in: defaults) == local)
        #expect(server.automaticModelAlias(for: slot, entries: [local]) == local.alias)
        try settings.prefer(remote.alias, for: remoteSlot)
        #expect(settings.document.model(alias: remote.alias)?.enabled == true)
        #expect(YouziResidentServicePreference.aliases(for: slot, in: defaults).isEmpty)
        #expect(YouziResidentServicePreference.startupEntry(entries: [local], in: defaults) == nil)
        #expect(server.automaticModelAlias(for: slot, entries: [local]) == remote.alias)
        #expect(server.servingAlias == "already-loaded")
        #expect(try settings.repository.load().preferredModels?[remoteSlot.rawValue] == remote.alias)
        #expect(defaults.stringArray(forKey: slot.selectionKey) == ["legacy-first", "legacy-second"])
        try settings.remove(remote.id)
        #expect(server.automaticModelAlias(for: slot, entries: [local]) == nil)
        #expect(YouziResidentServicePreference.aliases(for: slot, in: defaults).isEmpty)
        try settings.prefer(nil, for: remoteSlot)
        #expect(YouziResidentServicePreference.preferredAlias(for: slot, in: defaults) == nil)
    }

    @Test("Legacy routing migrates read-only to one preference and independent audio defaults")
    func unifiedLegacyPreference() throws {
        let (settings, defaults, suite, _) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let image = model(.image)
        try settings.save(image, key: "")
        defaults.set(["first", "second"], forKey: YouziResidentServicePreference.Slot.image.selectionKey)
        #expect(YouziResidentServicePreference.aliases(for: .image, in: defaults) == ["first"])
        try settings.update { $0.globalPriority = .remoteFirst }
        let original = defaults.data(forKey: RemoteModelRepository.key)
        #expect(YouziResidentServicePreference.preferredAlias(for: .image, in: defaults) == image.alias)
        #expect(YouziResidentServicePreference.aliases(for: .image, in: defaults).isEmpty)
        #expect(defaults.data(forKey: RemoteModelRepository.key) == original)
        try settings.prefer("local-asr", for: .transcription)
        let speech = model(.speech); try settings.save(speech, key: "")
        try settings.prefer(speech.alias, for: .speech)
        #expect(YouziResidentServicePreference.aliases(for: .transcription, in: defaults) == ["local-asr"])
        #expect(YouziResidentServicePreference.aliases(for: .speech, in: defaults).isEmpty)
        #expect(settings.document.automatic(for: .transcription, local: "local-asr") == "local-asr")
        #expect(settings.document.automatic(for: .speech, local: nil) == speech.alias)
    }

    @Test("Remote video tool capabilities need no local process and reject changed endpoints")
    func remoteVideoToolSession() async throws {
        let (settings, defaults, suite, _) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        var video = model(.video)
        try settings.save(video, key: "")
        let server = ServerManager(testingState: .stopped, sessionDefaults: defaults)
        server.remoteModelSettings = settings
        let runner = try YouziLocalModelTools.videoRunner(video.entry, server: server)
        let caps = try await runner.describe(video.entry)
        #expect(caps.model == video.modelID)
        #expect(server.servingAlias == nil)
        video.enabled = false
        try settings.save(video, key: nil)
        await #expect(throws: YouziLocalModelTools.Failure.model_not_ready) { try await runner.describe(video.entry) }
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
    @Test("CLIProxyAPI uses its explicit video compatibility route and preserves job metadata")
    func cliProxyVideo() async throws {
        var value = model(.video); value.modelID = "grok-imagine-video-1.5"
        value.videoAPI = .cliProxyAPI; value.supportsVideoImageInput = true
        value.baseURL = "https://provider.example/gateway/v1"
        let endpoint = try RemoteModelEndpoint(configuration: value, apiKey: "fixture-video")
        let transport = session(); defer { transport.invalidateAndCancel() }
        var client = VideoClient(remoteEndpoint: endpoint); client.remoteSession = transport
        RemoteFixtureProtocol.reset(jobJSON.replacingOccurrences(of: "provider-video", with: value.modelID))
        let job = try await client.create(.init(prompt: "fixture", model: value.alias, seconds: 4, size: "720x1280", seed: 42,
                                               reference: Data([1,2,3]), referenceFileName: "fixture.png", referenceMIMEType: "image/png"), port: 1, bearer: "local-only")
        let sent = try #require(RemoteFixtureProtocol.records.last)
        #expect(sent.request.url?.path == "/gateway/openai/v1/videos")
        #expect(sent.request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-video")
        #expect(sent.request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try jsonBody()
        #expect(body["seed"] == nil && body["model"] as? String == value.modelID)
        #expect((body["input_reference"] as? [String: String])?["image_url"] == "data:image/png;base64,AQID")
        let count = RemoteFixtureProtocol.records.count
        #expect(try await client.list(port: 1, bearer: nil).isEmpty)
        do { try await client.delete(id: job.id, port: 1, bearer: nil); Issue.record("Unsupported delete must not send") } catch {}
        #expect(RemoteFixtureProtocol.records.count == count)
        RemoteFixtureProtocol.reset(#"{"id":"video_fixture","model":"grok-imagine-video-1.5","status":"completed","seconds":4}"#)
        let completed = try await client.poll(job, port: 1, bearer: nil)
        #expect(completed.status == .completed && completed.progress == 100)
        #expect(completed.size == job.size && completed.createdAt == job.createdAt && completed.seconds == job.seconds)
        #expect(RemoteFixtureProtocol.records.last?.request.url?.path == "/gateway/openai/v1/videos/video_fixture")
        RemoteFixtureProtocol.reset(#"{"id":"another_job","status":"completed"}"#)
        do { _ = try await client.poll(job, port: 1, bearer: nil); Issue.record("Wrong job must fail") } catch {}
        value.modelID = "MiniMax-H3"
        #expect(throws: (any Error).self) { try value.validated() }
        value.modelID = "grok-imagine-video-1.5-lite"
        #expect(throws: (any Error).self) { try value.validated() }
        value.modelID = "grok-imagine-video"; value.baseURL = "https://provider.example/custom"
        #expect(throws: (any Error).self) { try value.validated() }
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(model(.video))) as? [String: Any])
        legacy.removeValue(forKey: "videoAPI")
        #expect(try JSONDecoder().decode(RemoteModelConfiguration.self, from: JSONSerialization.data(withJSONObject: legacy)).videoAPI == nil)
    }

    @Test("CLIProxyAPI refresh retains session jobs without calling unavailable history/delete routes")
    func cliProxySession() async throws {
        let (settings, defaults, name, _) = fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        var value = model(.video); value.modelID = "grok-imagine-video"; value.videoAPI = .cliProxyAPI
        try settings.save(value, key: "fixture-video")
        let server = ServerManager(testingState: .stopped, sessionDefaults: defaults); server.remoteModelSettings = settings
        let transport = session(); defer { transport.invalidateAndCancel() }
        let vm = VideoGenViewModel(server: server, generationDefaults: ModelGenerationDefaults(defaults: defaults), pollingInterval: .seconds(3600), catalogLoader: { _ in [] })
        vm.remoteSettings = settings
        vm.remoteClientFactory = { endpoint in var client = VideoClient(remoteEndpoint: endpoint); client.remoteSession = transport; return client }
        vm.selectedAlias = value.alias
        RemoteFixtureProtocol.reset("{}", status: 404)
        await vm.prepareSelectedModel()
        #expect(RemoteFixtureProtocol.records.isEmpty && vm.isServerReady && !vm.canDeleteProviderVideos)
        vm.prompt = "fixture"; #expect(vm.canSubmit)
        RemoteFixtureProtocol.reset(jobJSON.replacingOccurrences(of: "provider-video", with: value.modelID))
        await vm.submit()
        #expect(vm.jobs.count == 1 && vm.hasLiveActiveJobs)
        RemoteFixtureProtocol.reset(#"{"id":"video_fixture","status":"failed","error":{"message":"fixture failure"}}"#)
        await vm.pollJobs()
        #expect(!vm.hasLiveActiveJobs && vm.jobs.first?.status == .failed)
        let count = RemoteFixtureProtocol.records.count
        await vm.refreshServerData()
        #expect(vm.jobs.count == 1 && RemoteFixtureProtocol.records.count == count)
    }
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

    @Test("Discovery classifies output capabilities, never vision or video input")
    func discoveryMetadata() throws {
        let data = Data(#"""
        {"data":[
          {"id":"vision-chat","input_modalities":["image","video"],"output_modalities":["text"]},
          {"id":"input-only","capabilities":{"vision":true,"video_input":true,"image_generation":false}},
          {"id":"qwen-image-disabled","capabilities":{"image_generation":false}},
          {"id":"qwen-image-misleading","supported_endpoints":["/v1/chat/completions"]},
          {"id":"custom-image","architecture":{"input_modalities":["text"],"output_modalities":["image"]}},
          {"id":"custom-video","capabilities":{"video_generation":true}},
          {"id":"custom-asr","pipeline_tag":"automatic-speech-recognition","output_modalities":["text"]},
          {"id":"custom-tts","supported_endpoints":["audio/speech"]},
          {"id":"dual","capabilities":["text-to-image"]},
          {"id":"dual","supported_endpoints":["/v1/videos"]},
          {"id":"dual"},
          {"id":"gpt-embedding","supported_endpoints":["/v1/embeddings"]}
        ]}
        """#.utf8)
        let models = try RemoteDiscoveredModel.parse(data)
        let byID = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
        #expect(byID["vision-chat"]?.slots == [.chat])
        #expect(byID["input-only"]?.slots == [])
        #expect(byID["qwen-image-disabled"]?.slots == [])
        #expect(byID["qwen-image-misleading"]?.slots == [.chat])
        #expect(byID["custom-image"]?.slots == [.image])
        #expect(byID["custom-video"]?.slots == [.video])
        #expect(byID["custom-asr"]?.slots == [.transcription])
        #expect(byID["custom-tts"]?.slots == [.speech])
        #expect(byID["dual"]?.slots == [.image, .video])
        #expect(byID["dual"]?.evidence == .metadata)
        #expect(byID["gpt-embedding"]?.evidence == .other)
    }

    @Test("Name hints separate image/video/audio from chat; unknown aliases remain selectable")
    func discoveryNames() throws {
        let ids = ["localai/qwen-image-2.1", "gpt-image-2", "gemini-3.1-flash-image", "grok-imagine-image-2.0",
                   "tsingfly/MiniMax-H3", "minimax-h3-ref2va-q4", "grok-imagine-video-1.5-lite",
                   "Minimax-M3", "gemini-4-argon-high", "Qwen3-TTS-12Hz-1.7B-Base", "faster-qwen3-tts",
                   "qwen3-asr-1.7b", "localai/text-embedding-ada-002", "jina-reranker-v1-base-en", "silero-vad-ggml", "my-custom-alias"]
        let data = try JSONSerialization.data(withJSONObject: ["data": ids.map { ["id": $0] }])
        let models = try RemoteDiscoveredModel.parse(data)
        func selected(_ slot: RemoteModelSlot) -> [RemoteDiscoveredModel] {
            RemoteDiscoveredModel.filtered(models, slot: slot, query: "", showAll: false)
        }
        #expect(selected(.image).count == 4)
        #expect(selected(.video).count == 3)
        #expect(selected(.chat).count == 2)
        #expect(selected(.speech).count == 2)
        #expect(selected(.transcription).count == 1)
        #expect(selected(.image).allSatisfy { $0.evidence == .name })
        #expect(models.filter { $0.evidence == .other }.count == 3)
        #expect(RemoteDiscoveredModel.filtered(models, slot: .video, query: " QWEN ", showAll: false).isEmpty)
        #expect(RemoteDiscoveredModel.filtered(models, slot: .image, query: " QWEN ", showAll: false).map(\.id) == ["localai/qwen-image-2.1"])
        #expect(RemoteDiscoveredModel.filtered(models, slot: .image, query: "my-custom", showAll: true).map(\.id) == ["my-custom-alias"])
        #expect(RemoteDiscoveredModel.filtered(models, slot: .image, query: "", showAll: true).count == ids.count)
    }

    @Test("Discovery rejects invalid envelopes and drops malformed identifiers")
    func discoveryValidation() throws {
        #expect(throws: (any Error).self) { try RemoteDiscoveredModel.parse(Data(#"{"models":[]}"#.utf8)) }
        let data = try JSONSerialization.data(withJSONObject: ["data": [["id": ""], ["id": "bad\nID"], ["id": String(repeating: "a", count: 257)], ["id": "safe"], ["id": "safe"]]])
        #expect(try RemoteDiscoveredModel.parse(data).map(\.id) == ["safe"])
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
            let server = ServerManager(testingState: .idle, sessionDefaults: defaults)
            var cases: [(String, AnyView, CGSize)] = [
                ("chat", AnyView(ResidentServiceSlotList(defaults: defaults, slot: .chat, entries: [], settings: settings)
                    .environment(server).padding(20)), CGSize(width: 480, height: 680)),
                ("audio", AnyView(ResidentServiceSlotList(defaults: defaults, slot: .speech, entries: [], settings: settings)
                    .environment(server).padding(20)), CGSize(width: 860, height: 680)),
            ]
            for slot in RemoteModelSlot.allCases {
                cases.append(("editor-\(slot.rawValue)", AnyView(RemoteModelEditor(model: model(slot), settings: settings)), CGSize(width: 620, height: 650)))
                if slot == .image || slot == .video {
                    let catalog = try RemoteDiscoveredModel.parse(Data(#"{"data":[{"id":"Qwen-Image-2.1"},{"id":"grok-imagine-video-1.5"},{"id":"custom-alias"}]}"#.utf8))
                    cases.append(("discovery-\(slot.rawValue)", AnyView(RemoteModelEditor(model: model(slot), settings: settings, discovered: catalog)), CGSize(width: 620, height: 650)))
                }
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
