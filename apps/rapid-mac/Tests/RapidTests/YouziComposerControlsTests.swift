import AppKit
import SwiftUI
import Testing
@testable import Rapid

@Suite("Youzi composer controls")
@MainActor
struct YouziComposerControlsTests {
    private func model(_ alias: String, kind: ModelKind = .chat, state: String = "resident") -> ResidentModelStatus {
        .init(id: alias, modelPath: "fixture/" + alias, aliases: [alias], modality: kind == .chat ? "text" : "image",
              state: state, pinned: false, primary: false, activeRequests: 0,
              estimatedBytes: 1024, measuredBytes: nil, idleSeconds: 0)
    }
    private func snapshot(_ models: [ResidentModelStatus], audio: [ResidentAudioLaneStatus] = []) -> ModelResidencySnapshot {
        .init(memoryLimitBytes: 4096, memoryUsedBytes: 1024, memoryAvailableBytes: 3072,
              idleTTLSeconds: 0, loadsTotal: 0, evictionsTotal: 0, models: models, audioLanes: audio)
    }

    @Test("Only exact selected resident models count; stopped and downloaded-only models do not",
          arguments: ["resident", "busy", "loaded", "registered", "loading", "failed", "evicting"])
    func readiness(state: String) {
        let entry = ModelEntry(alias: "chosen", hfRepo: "fixture/chosen", sizeOnDisk: "8 GB", cached: true)
        let ready = YouziModelAvailability.readySlots(selections: [.chat: "chosen", .image: "other"], entries: [entry],
            residency: snapshot([model("chosen", state: state), model("unselected", kind: .image)]),
            localReachable: true, remoteOnline: [])
        #expect(ready == (["resident", "busy", "loaded"].contains(state) ? [.chat] : []))
        #expect(YouziModelAvailability.readySlots(selections: [.chat: "chosen"], entries: [entry],
            residency: snapshot([model("chosen")]), localReachable: false, remoteOnline: []).isEmpty)
        #expect(YouziModelAvailability.readySlots(selections: [.chat: "chosen"], entries: [entry],
            residency: .empty, localReachable: true, remoteOnline: []).isEmpty)
    }

    @Test("Remote readiness is exact and independent of local runtime; audio is a single sector")
    func remoteAndAudio() {
        let alias = "youzi-remote/fixture"
        let ready = YouziModelAvailability.readySlots(selections: [.chat: alias, .image: "youzi-remote/other"],
            entries: [], residency: .empty, localReachable: false, remoteOnline: [alias])
        #expect(ready == [.chat])
        #expect(YouziModelAvailability.lanes(for: [.chat, .speech, .transcription, .image, .video]) == [.chat, .image, .voice, .video])
        let audio = ModelEntry(alias: "tts", hfRepo: "fixture/tts", sizeOnDisk: nil, cached: true, kind: .audio, audioCapability: .speech)
        #expect(YouziModelAvailability.readySlots(selections: [.speech: "tts"], entries: [audio],
            residency: snapshot([], audio: [.init(lane: "tts", model: "fixture/tts", state: "busy")]),
            localReachable: true, remoteOnline: []) == [.speech])
    }

    @Test("Sphere sectors divide evenly for one through four capabilities")
    func sectors() {
        let rect = CGRect(x: 0, y: 0, width: 28, height: 28)
        #expect(YouziOrbSector(index: 0, count: 0).path(in: rect).isEmpty)
        for count in 1...4 {
            var total: Double = 0
            for index in 0..<count {
                let sector = YouziOrbSector(index: index, count: count)
                total += sector.degrees
                #expect(!sector.path(in: rect).isEmpty)
                let angle = (-90 + (Double(index) + 0.5) * sector.degrees) * .pi / 180
                #expect(sector.path(in: rect).contains(.init(x: 14 + 8 * cos(angle), y: 14 + 8 * sin(angle))))
            }
            #expect(abs(total - 360) < 0.0001)
        }
    }

    @Test("Composer keeps voice last, removes runtime badge, and shares send-stop-voice visuals")
    func wiring() throws {
        let composer = try source("UI/YouziSimple/YouziSimpleTaskView.swift")
        let start = try #require(composer.range(of: "                    modelQuickPicker"))
        let context = try #require(composer.range(of: "YouziContextUsageRing(messages:"))
        let send = try #require(composer.range(of: "YouziComposerIconButton("))
        let voice = try #require(composer.range(of: "YouziLiveVoiceButton(isPresented: $showsLiveVoice, compact: true)"))
        #expect(start.lowerBound < context.lowerBound && context.lowerBound < send.lowerBound && send.lowerBound < voice.lowerBound)
        #expect(!composer.contains("已在本机就绪") && !composer.contains("Label(runtimeStatus"))
        #expect(composer.contains("chat.isStreaming ? \"stop.fill\" : \"arrow.up\""))
        #expect(try source("LiveVoice/YouziLiveVoiceSheet.swift").contains("YouziComposerIconButton(symbol: \"waveform\""))
        let picker = try source("UI/YouziScenarioModelPicker.swift")
        #expect(!picker.contains("远程模型（可选）") && !picker.contains("按优先级选择") && !picker.contains("更多模型设置"))
        #expect(picker.contains("Button(i18n.text(zh: \"模型设置\""))
        #expect(picker.contains("return selections[slot] == entry.alias"))
        #expect(picker.contains("select(entry.alias, slot: slot)"))
        #expect(!picker.contains("RemoteModelSettings.shared.readiness("))
    }

    private func source(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/Rapid/" + path), encoding: .utf8)
    }
}

private struct AvailabilitySecrets: RemoteModelSecrets {
    func read(_ id: UUID) throws -> String? { "fixture-provider-key" }
    func write(_ value: String?, for id: UUID) throws {}
}
private actor AvailabilityProbeRecorder {
    var calls = 0
    func record() { calls += 1 }
}

@Suite("Youzi remote availability", .serialized)
@MainActor
struct YouziRemoteAvailabilityTests {
    @Test("Only listed models become online; TTL, config changes, disable and missing IDs are conservative")
    func cache() async throws {
        let suite = "youzi-availability-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = RemoteModelSettings(repository: .init(defaults: defaults, secrets: AvailabilitySecrets()))
        var model = RemoteModelConfiguration(name: "Fixture", modelID: "fixture-model", baseURL: "https://example.invalid/v1")
        try settings.save(model, key: nil)
        let recorder = AvailabilityProbeRecorder()
        let probe = YouziRemoteModelAvailability { endpoint in
            #expect(endpoint.apiKey == "fixture-provider-key")
            await recorder.record()
            return ["fixture-model"]
        }
        #expect(probe.status(model.alias, revision: settings.revision) == .unchecked)
        await probe.refresh(aliases: [model.alias], settings: settings)
        #expect(probe.status(model.alias, revision: settings.revision) == .online)
        await probe.refresh(aliases: [model.alias], settings: settings)
        #expect(await recorder.calls == 1)
        #expect(probe.status(model.alias, revision: settings.revision, now: .now.addingTimeInterval(61)) == .unchecked)
        await probe.refresh(aliases: [model.alias], settings: settings, force: true)
        #expect(await recorder.calls == 2)
        model.modelID = "not-listed"
        try settings.save(model, key: nil)
        #expect(probe.status(model.alias, revision: settings.revision) == .unchecked)
        await probe.refresh(aliases: [model.alias], settings: settings)
        #expect(probe.status(model.alias, revision: settings.revision) == .offline)
        model.enabled = false
        try settings.save(model, key: nil)
        await probe.refresh(aliases: [model.alias], settings: settings)
        #expect(probe.status(model.alias, revision: settings.revision) == .unchecked)
        #expect(await recorder.calls == 3)
    }

    @Test("Cancelled probes and late responses after edits cannot mark old configuration online")
    func cancellation() async throws {
        let suite = "youzi-availability-cancel-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = RemoteModelSettings(repository: .init(defaults: defaults, secrets: AvailabilitySecrets()))
        var model = RemoteModelConfiguration(name: "Fixture", modelID: "fixture-model", baseURL: "https://example.invalid/v1")
        try settings.save(model, key: nil)
        let probe = YouziRemoteModelAvailability { _ in
            try await Task.sleep(for: .milliseconds(80))
            return ["fixture-model"]
        }
        let task = Task { await probe.refresh(aliases: [model.alias], settings: settings) }
        await Task.yield()
        task.cancel(); await task.value
        #expect(probe.status(model.alias, revision: settings.revision) == .unchecked)
        let next = Task { await probe.refresh(aliases: [model.alias], settings: settings) }
        try await Task.sleep(for: .milliseconds(10))
        model.modelID = "new-model"; try settings.save(model, key: nil)
        await next.value
        #expect(probe.status(model.alias, revision: settings.revision) == .unchecked)
        let failing = YouziRemoteModelAvailability { _ in throw URLError(.userAuthenticationRequired) }
        await failing.refresh(aliases: [model.alias], settings: settings)
        #expect(failing.status(model.alias, revision: settings.revision) == .offline)
    }
}
