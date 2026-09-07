import Foundation
import Testing
@testable import Rapid

@MainActor
@Suite("Youzi media co-loading", .serialized)
struct YouziMediaCoLoadTests {
    @Test("Audio selection preloads shared lane without replacing chat")
    func audioSelection() async throws {
        let server = makeServer(kind: .audio)
        defer { server._testClearChild() }
        #expect(await server.ensureServing(
            alias: "media", hfPath: "local/media", residencyEligible: true, requestIsMedia: true
        ))
        #expect(server.servingAlias == "chat")
        #expect(server.isVoiceLaneResident(for: "media", modelPath: "local/media"))
        #expect(MediaCoLoadProtocol.paths.contains("/v1/audio/models/load"))
        #expect(!MediaCoLoadProtocol.paths.contains("/v1/models/load"))
    }

    @Test("Media loads omit chat performance overrides and preserve primary")
    func imageSelection() async throws {
        let server = makeServer(kind: .image)
        defer { server._testClearChild() }
        server.perfConfigProvider = { _ in ModelPerfConfig(kvCacheMode: .turboquantK8V4) }
        #expect(await server.ensureServing(
            alias: "media", hfPath: "local/media", residencyEligible: true, requestIsMedia: true
        ))
        #expect(server.servingAlias == "chat")
        let data = try #require(MediaCoLoadProtocol.loadBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["performance"] == nil)
        #expect(body["model"] as? String == "media")
    }

    @Test("Rejected media preload leaves chat running and exposes the error")
    func rejectedAudio() async throws {
        let server = makeServer(kind: .audio)
        defer { server._testClearChild() }
        MediaCoLoadProtocol.reject = true
        #expect(!(await server.ensureServing(
            alias: "media", hfPath: "local/media", residencyEligible: true, requestIsMedia: true
        )))
        #expect(server.servingAlias == "chat")
        #expect(server.residentLoadFailures["media"]?.message == "insufficient memory")
    }

    @Test("Explicit audio modality works with the chat-only catalog")
    func explicitAudioKind() async {
        let server = makeServer(kind: .audio)
        defer { server._testClearChild() }
        server._testSetCatalogProvenStart([:])
        #expect(await server.ensureServing(
            alias: "media", hfPath: "local/media", residencyEligible: true,
            requestIsMedia: true, mediaKind: .audio
        ))
        #expect(MediaCoLoadProtocol.paths.contains("/v1/audio/models/load"))
        #expect(!MediaCoLoadProtocol.paths.contains("/v1/models/load"))
        #expect(server.servingAlias == "chat")
    }

    @Test("Resident image loads request pinning")
    func pinnedImage() async throws {
        let suite = "YouziMediaCoLoadTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: YouziResidentServicePreference.enabledKey)
        let server = makeServer(kind: .image, defaults: defaults)
        defer { server._testClearChild() }
        #expect(await server.ensureServing(
            alias: "media", hfPath: "local/media", residencyEligible: true,
            requestIsMedia: true, mediaKind: .image
        ))
        let data = try #require(MediaCoLoadProtocol.loadBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["pin"] as? Bool == true)
        #expect(server.servingAlias == "chat")
    }

    @Test("Restore reuses an already-ready speech model without duplicate loading")
    func restoreReadyAudio() async throws {
        let suite = "YouziMediaCoLoadTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: YouziResidentServicePreference.enabledKey)
        defaults.set("media", forKey: YouziResidentServicePreference.Slot.speech.key)
        let server = makeServer(kind: .audio, defaults: defaults, binaryPath: URL(fileURLWithPath: "/nonexistent/rapid-mlx"))
        defer { server._testClearChild() }
        MediaCoLoadProtocol.audioReady = true
        server.residentServiceCatalogProvider = { _ in [
            ModelEntry(alias: "media", hfRepo: "local/media", sizeOnDisk: nil, cached: true, kind: .audio, audioCapability: .speech)
        ] }
        await server.restoreResidentServices()
        #expect(server.isVoiceLaneResident(for: "media", modelPath: "local/media"))
        #expect(!MediaCoLoadProtocol.paths.contains("/v1/audio/models/load"))
    }

    @Test("Restore loads valid media and retains chat despite a missing sibling")
    func partialRestore() async throws {
        let suite = "YouziMediaCoLoadTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: YouziResidentServicePreference.enabledKey)
        defaults.set("media", forKey: YouziResidentServicePreference.Slot.speech.key)
        defaults.set("missing", forKey: YouziResidentServicePreference.Slot.image.key)
        let server = makeServer(kind: .audio, defaults: defaults, binaryPath: URL(fileURLWithPath: "/nonexistent/rapid-mlx"))
        defer { server._testClearChild() }
        server.residentServiceCatalogProvider = { _ in [
            ModelEntry(alias: "media", hfRepo: "local/media", sizeOnDisk: nil,
                       cached: true, kind: .audio, audioCapability: .speech)
        ] }
        await server.restoreResidentServices()
        #expect(server.isVoiceLaneResident(for: "media", modelPath: "local/media"))
        #expect(server.residentLoadFailures["missing"] != nil)
        #expect(server.servingAlias == "chat")
        #expect(!server.isRestoringResidentServices)
        #expect(MediaCoLoadProtocol.paths.contains("/v1/audio/models/load"))
    }

    private func makeServer(kind: ModelKind, defaults: UserDefaults? = nil, binaryPath: URL? = nil) -> ServerManager {
        MediaCoLoadProtocol.paths = []
        MediaCoLoadProtocol.loadBody = nil
        MediaCoLoadProtocol.reject = false
        MediaCoLoadProtocol.audioReady = false
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MediaCoLoadProtocol.self]
        var client = ServerResidencyClient()
        client.session = URLSession(configuration: configuration)
        let server = ServerManager(testingState: .ready(alias: "chat"), binaryPath: binaryPath, activeBearer: "test-key", sessionDefaults: defaults)
        server._testSetResidencyClient(client)
        server._testInstallChild(ProcessGroupChild.testStub())
        server._testSetCatalogProvenStart(["media": .init(
            entry: ModelEntry(alias: "media", hfRepo: "local/media", sizeOnDisk: nil, cached: true, kind: kind),
            generation: 0
        )])
        return server
    }
}

private final class MediaCoLoadProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var paths: [String] = []
    nonisolated(unsafe) static var loadBody: Data?
    nonisolated(unsafe) static var reject = false
    nonisolated(unsafe) static var audioReady = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        Self.paths.append(path)
        let payload: String
        var status = 200
        if path == "/v1/models/residency" {
            let lanes = Self.audioReady ? #"[{"lane":"tts","model":"local/media","state":"resident"}]"# : "[]"
            payload = "{\"supports_preserve_loaded\":true,\"memory_limit_bytes\":0,\"memory_used_bytes\":0,\"memory_available_bytes\":null,\"idle_ttl_seconds\":0,\"loads_total\":1,\"evictions_total\":0,\"models\":[],\"audio_lanes\":" + lanes + "}"
        } else if Self.reject {
            status = 507
            payload = #"{"error":{"message":"insufficient memory","type":"capacity_error"}}"#
        } else if path == "/v1/audio/models/load" {
            Self.audioReady = true
            payload = #"{"lane":"tts","model":"local/media","state":"resident"}"#
        } else {
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var body = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    body.append(buffer, count: count)
                }
                Self.loadBody = body
            } else {
                Self.loadBody = request.httpBody
            }
            payload = #"{"id":"media","model_path":"local/media","aliases":[],"modality":"image-gen","state":"resident","pinned":false,"primary":false,"active_requests":0,"estimated_bytes":1,"measured_bytes":null,"idle_seconds":0}"#
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
