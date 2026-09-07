import AppKit
import SwiftUI
import Foundation
import Testing
@testable import Rapid

@MainActor
@Suite("Youzi resident service preferences", .serialized)
struct YouziResidentServiceTests {
    @Test("Busy audio remains resident without fabricating a memory allocation")
    func busyAudio() {
        let lane = ResidentAudioLaneStatus(lane: "tts", model: "local/tts", state: "busy")
        #expect(lane.matches(modelPath: "local/tts"))
        let snapshot = ModelResidencySnapshot(memoryLimitBytes: 0, memoryUsedBytes: 0,
            memoryAvailableBytes: nil, idleTTLSeconds: 0, loadsTotal: 0, evictionsTotal: 0,
            models: [], audioLanes: [lane])
        let occupancy = YouziModelOccupancy.resolve(residency: snapshot, host: nil, voiceLaneResident: false)
        #expect(occupancy.voiceMemoryUnknown)
        #expect(occupancy.voiceBytes == 0)
    }

    @Test("Resident set is opt-in and preserves explicitly selected missing models")
    func preferences() throws {
        let suite = "YouziResidentServiceTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!YouziResidentServicePreference.enabled(in: defaults))
        #expect(YouziResidentServicePreference.selected(in: defaults).isEmpty)
        defaults.set(true, forKey: YouziResidentServicePreference.enabledKey)
        defaults.set("missing", forKey: YouziResidentServicePreference.Slot.speech.key)
        defaults.set("", forKey: YouziResidentServicePreference.Slot.image.key)
        #expect(YouziResidentServicePreference.enabled(in: defaults))
        let selected = YouziResidentServicePreference.selected(in: defaults)
        #expect(selected.count == 1)
        #expect(selected.first?.0 == .speech)
        #expect(selected.first?.1 == "missing")
    }

    @Test("Changing a single-lane policy replaces intent only; wire payload preserves pool order")
    func policyWireAndSingleLane() throws {
        let suite = "YouziResidentServiceTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        YouziResidentServicePreference.setAliases(["old"], for: .speech, in: defaults)
        YouziResidentServicePreference.setLoadingPolicy(.automatic, for: "new", slot: .speech, in: defaults)
        #expect(YouziResidentServicePreference.aliases(for: .speech, in: defaults) == ["new"])
        #expect(YouziResidentServicePreference.loadingPolicy(for: "old", slot: .speech, in: defaults) == .onDemand)
        YouziResidentServicePreference.setAliases(["b", "a"], for: .chat, in: defaults)
        let json = try #require(YouziResidentServicePreference.encodedPolicy(in: defaults))
        let decoded = try JSONDecoder().decode(ModelLoadingPolicyClient.Policy.self, from: Data(json.utf8))
        #expect(decoded.automatic["chat"] == ["b", "a"])
        #expect(decoded.automatic["image"] == [])
        let env = ServerManager.serveEnvironmentAdditions(bearer: "test-key", ambient: ["YOUZI_AUTOMATIC_MODEL_POOL": "untrusted"], automaticModelPolicy: json)
        #expect(env["YOUZI_AUTOMATIC_MODEL_POOL"] == json)
        #expect(ServerManager.serveEnvironmentAdditions(bearer: "test-key", ambient: ["YOUZI_AUTOMATIC_MODEL_POOL": "untrusted"])["YOUZI_AUTOMATIC_MODEL_POOL"] == nil)
    }

    @Test("App launch never resurrects manual history or legacy defaults outside the automatic pool")
    func startupPoolOnly() throws {
        let suite = "YouziResidentServiceTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manual = ModelEntry(alias: "manual", hfRepo: "local/manual", sizeOnDisk: nil, cached: true, kind: .chat)
        let automatic = ModelEntry(alias: "automatic", hfRepo: "local/automatic", sizeOnDisk: nil, cached: true, kind: .chat)
        let entries = [manual, automatic]
        defaults.set("manual", forKey: SessionModelRestore.chatAliasStorageKey)
        defaults.set("manual", forKey: YouziResidentServicePreference.Slot.chat.legacyDefaultKey)
        defaults.set(true, forKey: YouziResidentServicePreference.enabledKey)
        #expect(YouziResidentServicePreference.startupChatAlias(entries: entries, in: defaults) == nil)
        YouziResidentServicePreference.setAliases(["automatic"], for: .chat, in: defaults)
        #expect(YouziResidentServicePreference.startupChatAlias(entries: entries, in: defaults) == "automatic")
        defaults.set(false, forKey: YouziResidentServicePreference.enabledKey)
        #expect(YouziResidentServicePreference.startupChatAlias(entries: entries, in: defaults) == nil)
        #expect(YouziResidentServicePreference.automaticAlias(for: .chat, entries: entries, snapshot: nil, in: defaults) == "automatic")
        defaults.set(true, forKey: YouziResidentServicePreference.enabledKey)
        #expect(YouziResidentServicePreference.startupChatAlias(entries: [manual], in: defaults) == nil)
        #expect(defaults.string(forKey: SessionModelRestore.chatAliasStorageKey) == "manual")
    }

    @Test("Only cached models with a supported capability are offered")
    func filtering() {
        let tts = ModelEntry(alias: "tts", hfRepo: "local/tts", sizeOnDisk: nil, cached: true, kind: .audio, audioCapability: .speech)
        let stt = ModelEntry(alias: "stt", hfRepo: "local/stt", sizeOnDisk: nil, cached: true, kind: .audio, audioCapability: .transcription)
        let image = ModelEntry(alias: "image", hfRepo: "local/image", sizeOnDisk: nil, cached: true, kind: .image, imageCapability: .generation)
        let missing = ModelEntry(alias: "missing", hfRepo: "local/missing", sizeOnDisk: nil, cached: false, kind: .image, imageCapability: .generation)
        let unknown = ModelEntry(alias: "unknown", hfRepo: "local/unknown", sizeOnDisk: nil, cached: true, kind: .image)
        #expect(YouziResidentServicePreference.Slot.speech.accepts(tts))
        #expect(!YouziResidentServicePreference.Slot.transcription.accepts(tts))
        #expect(YouziResidentServicePreference.Slot.transcription.accepts(stt))
        #expect(YouziResidentServicePreference.Slot.image.accepts(image))
        #expect(!YouziResidentServicePreference.Slot.image.accepts(missing))
        #expect(!YouziResidentServicePreference.Slot.image.accepts(unknown))
    }

    @Test("Missing resident selections report each failure without stopping chat")
    func missingSelections() async throws {
        let suite = "YouziResidentServiceTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: YouziResidentServicePreference.enabledKey)
        defaults.set("missing-audio", forKey: YouziResidentServicePreference.Slot.speech.key)
        defaults.set("missing-image", forKey: YouziResidentServicePreference.Slot.image.key)
        let server = ServerManager(testingState: .ready(alias: "chat"), binaryPath: URL(fileURLWithPath: "/nonexistent/rapid-mlx"), sessionDefaults: defaults)
        server._testInstallChild(ProcessGroupChild.testStub())
        defer { server._testClearChild() }
        server.residentServiceCatalogProvider = { _ in [] }
        await server.restoreResidentServices()
        #expect(server.residentLoadFailures["missing-audio"] != nil)
        #expect(server.residentLoadFailures["missing-image"] != nil)
        #expect(server.servingAlias == "chat")
        #expect(!server.isRestoringResidentServices)
    }

    @Test("A process replacement during catalog discovery supersedes the restore")
    func supersededRestore() async throws {
        let suite = "YouziResidentServiceTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: YouziResidentServicePreference.enabledKey)
        defaults.set("missing", forKey: YouziResidentServicePreference.Slot.speech.key)
        let server = ServerManager(testingState: .ready(alias: "chat"), binaryPath: URL(fileURLWithPath: "/nonexistent/rapid-mlx"), sessionDefaults: defaults)
        server._testInstallChild(ProcessGroupChild.testStub())
        defer { server._testClearChild() }
        server.residentServiceCatalogProvider = { [weak server] _ in
            server?._testInstallChild(ProcessGroupChild.testStub())
            return []
        }
        await server.restoreResidentServices()
        #expect(server.residentLoadFailures.isEmpty)
        #expect(!server.isRestoringResidentServices)
    }
}

@MainActor
@Suite("Youzi unified model choices")
struct YouziUnifiedModelChoiceTests {
    @Test("Legacy choices migrate lazily and cleared v2 lists stay empty")
    func migration() throws {
        let name = "YouziStartupMigration." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let slot = YouziResidentServicePreference.Slot.image
        defaults.set("old", forKey: slot.key)
        #expect(YouziResidentServicePreference.aliases(for: slot, in: defaults) == ["old"])
        YouziResidentServicePreference.setAliases(["old", "new", "old", ""], for: slot, in: defaults)
        #expect(YouziResidentServicePreference.aliases(for: slot, in: defaults) == ["old", "new"])
        YouziResidentServicePreference.setAliases([], for: slot, in: defaults)
        #expect(YouziResidentServicePreference.aliases(for: slot, in: defaults).isEmpty)
        #expect(defaults.string(forKey: slot.key) == "old")
    }

    @Test("Legacy default is retained for rollback but never competes with the automatic pool")
    func legacyDefaultDoesNotRoute() throws {
        let name = "YouziModelDefault." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let manual = ModelEntry(alias: "manual", hfRepo: nil, sizeOnDisk: nil, cached: true, kind: .image, imageCapability: .generation)
        let automatic = ModelEntry(alias: "automatic", hfRepo: nil, sizeOnDisk: nil, cached: true, kind: .image, imageCapability: .generation)
        let slot = YouziResidentServicePreference.Slot.image
        defaults.set(manual.alias, forKey: slot.legacyDefaultKey)
        #expect(YouziResidentServicePreference.automaticAlias(for: slot, entries: [manual], in: defaults) == nil)
        #expect(!YouziResidentServicePreference.enabled(in: defaults))
        YouziResidentServicePreference.setAliases([automatic.alias], for: slot, in: defaults)
        #expect(YouziResidentServicePreference.automaticAlias(for: slot, entries: [manual, automatic], in: defaults) == automatic.alias)
        #expect(defaults.string(forKey: slot.legacyDefaultKey) == manual.alias)
        #expect(YouziResidentServicePreference.loadingPolicy(for: manual.alias, slot: slot, in: defaults) == .onDemand)
    }

    @Test("Automatic routing reuses ready pool members, never unrelated ready models")
    func automaticPriority() throws {
        let name = "YouziModelPool." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let entries = ["first", "second", "manual"].map {
            ModelEntry(alias: $0, hfRepo: "local/" + $0, sizeOnDisk: nil, cached: true, kind: .image, imageCapability: .generation)
        }
        let slot = YouziResidentServicePreference.Slot.image
        YouziResidentServicePreference.setAliases(["missing", "first", "second"], for: slot, in: defaults)
        func snapshot(_ names: [String]) -> ModelResidencySnapshot {
            ModelResidencySnapshot(memoryLimitBytes: 0, memoryUsedBytes: 0, memoryAvailableBytes: nil,
                idleTTLSeconds: 0, loadsTotal: 0, evictionsTotal: 0, models: names.map {
                    ResidentModelStatus(id: $0, modelPath: "local/" + $0, aliases: [$0], modality: "image-gen",
                        state: "resident", pinned: true, primary: false, activeRequests: 0, estimatedBytes: 1, measuredBytes: nil, idleSeconds: 0)
                })
        }
        #expect(YouziResidentServicePreference.automaticAlias(for: slot, entries: entries.reversed(), in: defaults) == "first")
        #expect(YouziResidentServicePreference.automaticAlias(for: slot, entries: entries, snapshot: snapshot(["manual", "second"]), in: defaults) == "second")
        #expect(YouziResidentServicePreference.automaticAlias(for: slot, entries: entries, snapshot: snapshot(["manual"]), in: defaults) == "first")
        #expect(YouziResidentServicePreference.resolveAlias(requested: "manual", for: slot, entries: entries, snapshot: snapshot(["first"]), in: defaults) == "manual")
        #expect(YouziResidentServicePreference.resolveAlias(requested: "missing", for: slot, entries: entries, in: defaults) == nil)
        #expect(YouziResidentServicePreference.resolveAlias(requested: "", for: slot, entries: entries, in: defaults) == nil)
        YouziResidentServicePreference.promote("second", for: slot, in: defaults)
        #expect(YouziResidentServicePreference.automaticAlias(for: slot, entries: entries, snapshot: snapshot(["first", "second"]), in: defaults) == "second")
        YouziResidentServicePreference.promote("manual", for: slot, in: defaults)
        #expect(!YouziResidentServicePreference.aliases(for: slot, in: defaults).contains("manual"))
        YouziResidentServicePreference.setAliases([], for: slot, in: defaults)
        #expect(YouziResidentServicePreference.automaticAlias(for: slot, entries: entries, snapshot: snapshot(["first"]), in: defaults) == nil)
    }

    @Test("Chat and video offer multiple startup entries, audio is honest about its single slot")
    func multiple() throws {
        let name = "YouziMultipleStartup." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        for slot in YouziResidentServicePreference.Slot.allCases {
            YouziResidentServicePreference.setAliases(["one", "two"], for: slot, in: defaults)
            #expect(YouziResidentServicePreference.aliases(for: slot, in: defaults).count == (slot.allowsMultiple ? 2 : 1))
        }
        let video = ModelEntry(alias: "video", hfRepo: nil, sizeOnDisk: nil, cached: true, kind: .video)
        let chat = ModelEntry(alias: "chat", hfRepo: nil, sizeOnDisk: nil, cached: true, kind: .chat)
        #expect(YouziResidentServicePreference.Slot.video.accepts(video))
        #expect(YouziResidentServicePreference.Slot.chat.accepts(chat))
        #expect(!YouziResidentServicePreference.Slot.chat.accepts(video))
    }

    @Test("Manual load processes the list with auto-restore disabled")
    func manualLoad() async throws {
        let name = "YouziManualStartup." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        YouziResidentServicePreference.setAliases(["missing"], for: .video, in: defaults)
        let server = ServerManager(testingState: .ready(alias: "chat"), binaryPath: URL(fileURLWithPath: "/nonexistent/rapid-mlx"), sessionDefaults: defaults)
        server._testInstallChild(ProcessGroupChild.testStub())
        defer { server._testClearChild() }
        server.residentServiceCatalogProvider = { _ in [] }
        await server.restoreResidentServices()
        #expect(server.residentLoadFailures.isEmpty)
        await server.restoreResidentServices(manually: true)
        #expect(server.residentLoadFailures["missing"] != nil)
        #expect(server.servingAlias == "chat")
        #expect(!YouziResidentServicePreference.enabled(in: defaults))
    }
}

@MainActor
@Suite("Startup list transport", .serialized)
struct YouziStartupTransportTests {
    @Test("Old runtimes cannot receive a silently ignored preservation request")
    func oldRuntime() async throws {
        StartupListProtocol.configure(supported: false)
        let (server, session) = makeServer()
        defer { server._testClearChild(); session.invalidateAndCancel() }
        let entry = ModelEntry(alias: "image", hfRepo: "local/image", sizeOnDisk: "1 GB", cached: true, kind: .image, imageCapability: .generation)
        #expect(await server.loadStartupModel(entry) == false)
        #expect(StartupListProtocol.loadBody == nil)
        #expect(server.residentLoadFailures["image"] != nil)
        #expect(server.servingAlias == "chat")
    }

    @Test("Startup loads pin without replacement and verify actual ready status")
    func safeLoad() async throws {
        StartupListProtocol.configure(supported: true)
        let (server, session) = makeServer()
        defer { server._testClearChild(); session.invalidateAndCancel() }
        let entry = ModelEntry(alias: "image", hfRepo: "local/image", sizeOnDisk: "1 GB", cached: true, kind: .image, imageCapability: .generation)
        #expect(await server.loadStartupModel(entry))
        let data = try #require(StartupListProtocol.loadBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["preserve_loaded"] as? Bool == true)
        #expect(body["pin"] as? Bool == true)
        #expect(body["replace_group"] == nil)
        #expect(body["model_path"] as? String == "local/image")
        #expect(body["memory_policy"] as? String == "keep_then_commit")
        #expect(server.servingAlias == "chat")
        #expect(server.residentLoadFailures.isEmpty)
    }

    private func makeServer() -> (ServerManager, URLSession) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StartupListProtocol.self]
        let session = URLSession(configuration: configuration)
        let server = ServerManager(testingState: .ready(alias: "chat"), binaryPath: URL(fileURLWithPath: "/nonexistent/rapid-mlx"))
        server._testInstallChild(ProcessGroupChild.testStub())
        server._testSetResidencyClient(ServerResidencyClient(session: session))
        return (server, session)
    }
}

private final class StartupListProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var supported = false
    nonisolated(unsafe) private static var body: Data?
    static var loadBody: Data? { lock.withLock { body } }
    static func configure(supported value: Bool) { lock.withLock { supported = value; body = nil } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let model: [String: Any] = ["id": "image", "model_path": "local/image", "aliases": ["image"],
            "modality": "image-gen", "state": "resident", "pinned": true, "primary": false,
            "active_requests": 0, "estimated_bytes": 1, "idle_seconds": 0]
        let payload: [String: Any] = Self.lock.withLock {
            if request.httpMethod == "POST" {
                var data = request.httpBody ?? Data()
                if data.isEmpty, let stream = request.httpBodyStream {
                    stream.open()
                    defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while true {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        if count <= 0 { break }
                        data.append(buffer, count: count)
                    }
                }
                Self.body = data
                return model
            }
            return ["memory_limit_bytes": 0, "memory_used_bytes": 0,
                "idle_ttl_seconds": 0, "loads_total": 0, "evictions_total": 0,
                "models": Self.body == nil ? [] : [model], "supports_preserve_loaded": Self.supported]
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: payload))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
@Suite("Unified model selection visual QA", .serialized)
struct YouziModelSelectionVisualTests {
    @Test("Render the shared list without using personal settings", .enabled(if: ProcessInfo.processInfo.environment["YOUZI_MODEL_SELECTION_VISUAL_QA"] == "1"))
    func render() async throws {
        let suite = "YouziModelSelectionVisualTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let i18n = YouziI18nConfig(defaults: defaults)
        let server = ServerManager(testingState: .idle, sessionDefaults: defaults)
        let entries = (1...8).map { index in
            ModelEntry(alias: "Qwen3.5-\(index)-Long-Model-Name-4bit", hfRepo: nil,
                sizeOnDisk: "8.2 GB", cached: true, kind: .chat)
        }
        defaults.set(entries[0].alias, forKey: YouziResidentServicePreference.Slot.chat.legacyDefaultKey)
        YouziResidentServicePreference.setAliases(Array(entries.prefix(2)).map(\.alias), for: .chat, in: defaults)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("youzi-model-selection-qa")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for chinese in [true, false] {
            i18n.language = chinese ? .zhHans : .en
            let view = ResidentServiceSlotList(defaults: defaults, slot: .chat, entries: entries)
                .padding(16).background(Color(nsColor: .windowBackgroundColor))
                .environment(i18n).environment(server).defaultAppStorage(defaults)
            let host = NSHostingView(rootView: view)
            host.appearance = NSAppearance(named: .aqua)
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 560, height: 460),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(250))
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:]))
                .write(to: output.appendingPathComponent(chinese ? "models-zh.png" : "models-en.png"))
            #expect(host.bounds.width == 560)
        }
    }
}
