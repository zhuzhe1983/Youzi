import Foundation
import Testing
@testable import Rapid

@Suite("Youzi scenario model catalog")
struct YouziScenarioModelsTests {
    @Test("Downloaded media is merged with chat-only cache, preserving uncached status")
    func merge() {
        let chat = ModelEntry(alias: "chat", hfRepo: "local/chat", sizeOnDisk: nil, cached: true)
        let voice = ModelEntry(alias: "voice", hfRepo: "local/voice", sizeOnDisk: nil, cached: true, kind: .audio)
        let missing = ModelEntry(alias: "missing", hfRepo: nil, sizeOnDisk: nil, cached: false, kind: .image)
        let result = YouziScenarioModels.merge(chat: [chat], media: [voice, missing])
        #expect(result.filter { $0.cached }.map(\.alias) == ["chat", "voice"])
        #expect(result.filter { $0.kind == .audio && $0.cached } == [voice])
    }

    @Test("Checkmarks follow canonical paths and aliases, not registered/loading preferences")
    func ready() {
        let entry = ModelEntry(alias: "short", hfRepo: "local/full", sizeOnDisk: nil, cached: true)
        for state in ["resident", "busy", "registered", "loading", "evicting", "failed"] {
            let model = ResidentModelStatus(id: "canonical", modelPath: "local/full", aliases: ["short"],
                modality: "text", state: state, pinned: true, primary: true, activeRequests: 0,
                estimatedBytes: 1, measuredBytes: nil, idleSeconds: 0)
            let snapshot = ModelResidencySnapshot(memoryLimitBytes: 100, memoryUsedBytes: 1, memoryAvailableBytes: 99,
                idleTTLSeconds: 0, loadsTotal: 0, evictionsTotal: 0, models: [model], audioLanes: [])
            #expect(YouziScenarioModels.isReady(entry, in: snapshot) == ["resident", "busy"].contains(state))
        }
        #expect(!YouziScenarioModels.isReady(entry, in: .empty))
    }

    @Test("Busy audio is ready under canonical HF identity")
    func audio() {
        let entry = ModelEntry(alias: "voice", hfRepo: "local/voice", sizeOnDisk: nil, cached: true, kind: .audio)
        let snapshot = ModelResidencySnapshot(memoryLimitBytes: 0, memoryUsedBytes: 0, memoryAvailableBytes: nil,
            idleTTLSeconds: 0, loadsTotal: 0, evictionsTotal: 0, models: [],
            audioLanes: [.init(lane: "tts", model: "local/voice", state: "busy")])
        #expect(YouziScenarioModels.isReady(entry, in: snapshot))
        let occupancy = YouziModelOccupancy.resolve(residency: snapshot, host: nil, voiceLaneResident: false)
        #expect(occupancy.voiceMemoryUnknown && occupancy.voiceBytes == 0)
    }

    @Test("CLI probe reads media downloads rather than only chat; old video API does not hide audio")
    func cli() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("youzi-catalog-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("rapid-mlx")
        let script = """
        #!/bin/sh
        if [ "$1" = "models" ]; then
          if [ "$2" = "--json" ]; then exit 2; fi
          echo 'kokoro 338.9 MiB [audio:tts] kokoro mlx-community/Kokoro-82M-bf16'
          echo 'flux2-klein-4b 4.3 GiB [image:gen] Runpod/FLUX.2-klein-4B-mflux-4bit'
          echo 'whisper-large-v3-turbo 71.0 MiB [audio:stt] whisper mlx-community/whisper-large-v3-turbo-mlx'
        else
          echo '(unmapped) mlx-community/Kokoro-82M-bf16 338.9 MiB'
          echo 'flux2-klein-4b Runpod/FLUX.2-klein-4B-mflux-4bit 4.3 GiB'
        fi
        """
        try Data(script.utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let entries = try #require(await ModelCatalog.scenarioMediaEntries(binary: binary, hubCacheOverride: nil))
        #expect(entries.first { $0.alias == "kokoro" }?.cached == true)
        #expect(entries.first { $0.alias == "flux2-klein-4b" }?.cached == true)
        #expect(entries.first { $0.alias == "whisper-large-v3-turbo" }?.cached == false)
        #expect(entries.first { $0.alias == "kokoro" }?.audioCapability == .speech)
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: binary)
        #expect(await ModelCatalog.scenarioMediaEntries(binary: binary, hubCacheOverride: nil) == nil)
    }
}
