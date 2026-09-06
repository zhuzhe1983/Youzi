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
