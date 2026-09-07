import AVFoundation
import AppKit
import SwiftUI
import Foundation
import Testing
@testable import Rapid

/// Explicitly opt-in real native HTTP orchestration with synthetic microphone
/// capture and speaker drain; this must not be called acoustic QA. The default
/// probe also supplies a readiness fixture. Enable YOUZI_LIVE_PRODUCTION_READINESS
/// to exercise authenticated ServerManager residency and production model selection.
/// Uses synthetic input and an isolated conversation store. No model lifecycle,
/// real microphone, keychain or user conversation mutations.
@MainActor
@Suite("YouziLiveVoiceHTTPTests", .serialized)
struct YouziLiveVoiceHTTPTests {
    @Test("Native controller uses real ASR, ChatViewModel streaming and incremental TTS",
          .enabled(if: ProcessInfo.processInfo.environment["YOUZI_LIVE_VOICE_HTTP"] == "1"))
    func realHTTPChain() async throws {
        let env = ProcessInfo.processInfo.environment
        let input = URL(fileURLWithPath: try #require(env["YOUZI_LIVE_VOICE_INPUT"]))
        let output = URL(fileURLWithPath: try #require(env["YOUZI_LIVE_VOICE_OUTPUT"]), isDirectory: true)
        try #require(FileManager.default.fileExists(atPath: output.path))
        try #require(try FileManager.default.contentsOfDirectory(atPath: output.path).isEmpty)
        let chatPort = try #require(env["YOUZI_LIVE_CHAT_PORT"].flatMap(Int.init))
        let speechPort = try #require(env["YOUZI_LIVE_TTS_PORT"].flatMap(Int.init))
        try #require((1024...65535).contains(chatPort) && (1024...65535).contains(speechPort))
        let alias = env["YOUZI_LIVE_CHAT_MODEL"] ?? "qwen3.8-27b-4bit"
        let key = env["YOUZI_PROBE_API_KEY"]
        let productionReadiness = env["YOUZI_LIVE_PRODUCTION_READINESS"] == "1"
        if productionReadiness {
            try #require(chatPort == speechPort, "Production readiness selects lanes on one service")
        }
        let suite = "YouziLiveVoiceHTTPTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = 120
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        // Use the public model listing: residency is an admin endpoint and must
        // remain protected even when inference allows an empty API key.
        var residencyRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(chatPort)/v1/models")!)
        if let key { residencyRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let (residencyData, response) = try await session.data(for: residencyRequest)
        try #require((response as? HTTPURLResponse)?.statusCode == 200)
        let listing = try #require(JSONSerialization.jsonObject(with: residencyData) as? [String: Any])
        let entries = try #require(listing["data"] as? [[String: Any]])
        try #require(entries.contains { ($0["id"] as? String) == alias })
        // Isolated server ownership fixture: never spawn/stop the user service.
        // Production-readiness mode still fetches the actual authenticated
        // residency snapshot; the default mode supports split-port probes.
        let server = ServerManager(testingState: .ready(alias: alias), residency: .empty,
                                   activePort: chatPort, activeBearer: key, sessionDefaults: defaults)
        let sampling = SamplingConfig(defaults: defaults)
        sampling.maxTokens = 640
        sampling.enableThinking = false
        let instructions = CustomInstructionsConfig(defaults: defaults)
        let store = output.appendingPathComponent("conversations.json")
        let chat = ChatViewModel(client: ChatStreamClient(session: session),
                                 toolDefaults: defaults, sampling: sampling,
                                 customInstructions: instructions, server: server,
                                 conversationStoreURL: store)
        defer { chat.stopAndPersist() }
        // Include the actual simple transcript layout when investigating a GUI
        // stall. Previously this HTTP test never mounted SwiftUI and therefore
        // could pass even while the application's main-thread layout spun.
        let renderTranscript = env["YOUZI_LIVE_RENDER_TRANSCRIPT"] == "1"
        let transcriptWindow: NSWindow?
        if renderTranscript {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: HTTPProbeTranscript(chat: chat))
            transcriptWindow = window
        } else { transcriptWindow = nil }
        defer { transcriptWindow?.close() }
        let models = LiveVoiceModels(chatAlias: alias,
            recognition: LiveVoiceEndpoint(model: env["YOUZI_LIVE_ASR_MODEL"] ?? "whisper-large-v3-turbo",
                                           port: chatPort, bearer: key),
            speech: LiveVoiceEndpoint(model: env["YOUZI_LIVE_TTS_MODEL"] ?? "qwen3-tts",
                                      port: speechPort, bearer: key))
        let audio = HTTPProbeAudio()
        var transport = AudioClient(session: session)
        transport.generationDefaults = ModelGenerationDefaults(defaults: defaults)
        let readiness: any LiveVoiceModelReadiness = productionReadiness
            ? LiveVoiceResidentModels(server: server, chatAlias: alias)
            : HTTPProbeReadiness(models: models)
        let controller = YouziLiveVoiceController(audio: audio, transport: transport,
            chat: LiveVoiceChatAdapter(chat: chat), readiness: readiness,
            defaults: ModelGenerationDefaults(defaults: defaults))
        defer { controller.stop() }
        var firstPCMWhileChatStreaming = false
        var firstPCMSeconds: Double?
        let started = Date()
        audio.onFirstPCM = {
            firstPCMWhileChatStreaming = chat.isStreaming
            firstPCMSeconds = Date().timeIntervalSince(started)
        }
        await controller.start()
        try #require(controller.phase == .listening)
        try #require(audio.starts == 1)
        // Decode an explicitly provided synthetic WAV, without AVAudioEngine.
        let file = try AVAudioFile(forReading: input)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                  frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channel = try #require(buffer.floatChannelData?[0])
        let ratio = file.processingFormat.sampleRate / 16_000
        let count = Int(Double(buffer.frameLength) / ratio)
        try #require(count > 3200 && count < 16_000 * 14)
        let samples = (0..<count).map { channel[min(Int(Double($0) * ratio), Int(buffer.frameLength) - 1)] }
        // Preserve real capture cadence; delivering an entire multi-pause WAV
        // in one callback would cancel successive ASR windows in the same tick.
        for offset in stride(from: 0, to: samples.count, by: 320) {
            audio.onInputFrame?(Array(samples[offset..<min(offset + 320, samples.count)]))
            try await Task.sleep(for: .milliseconds(20))
        }
        let captureFinishedSeconds = Date().timeIntervalSince(started)
        controller.finishUtterance()
        let deadline = Date().addingTimeInterval(120)
        var lastHeartbeat = ProcessInfo.processInfo.systemUptime
        var maxHeartbeatGap: TimeInterval = 0
        var chatCompletedSeconds: TimeInterval?
        while Date() < deadline {
            let now = ProcessInfo.processInfo.systemUptime
            maxHeartbeatGap = max(maxHeartbeatGap, now - lastHeartbeat)
            lastHeartbeat = now
            if !chat.isStreaming && !controller.recognizedText.isEmpty && chatCompletedSeconds == nil {
                chatCompletedSeconds = Date().timeIntervalSince(started)
            }
            transcriptWindow?.contentView?.layoutSubtreeIfNeeded()
            if controller.problem != nil { break }
            if audio.chunks > 0 && controller.phase == .listening && !chat.isStreaming { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        // Keep diagnostics even on a timeout/failure, not only on successful runs.
        let diagnostics: [String: Any] = [
            "phase": String(describing: controller.phase), "chat_streaming": chat.isStreaming,
            "problem": String(describing: controller.problem), "pcm_chunks": audio.chunks,
            "pcm_bytes": audio.byteCount, "first_pcm_seconds": firstPCMSeconds ?? -1,
            "first_pcm_while_chat_streaming": firstPCMWhileChatStreaming,
            "capture_finished_seconds": captureFinishedSeconds,
            "first_pcm_after_capture_seconds": firstPCMSeconds.map { $0 - captureFinishedSeconds } ?? -1,
            "total_seconds": Date().timeIntervalSince(started), "mic_activated": false,
            "transcript_rendered": renderTranscript, "max_main_actor_gap_seconds": maxHeartbeatGap,
            "first_text_after_chat_send_seconds": controller.firstTextSeconds ?? -1,
            "first_pcm_after_chat_send_seconds": controller.firstPCMSeconds ?? -1,
            "chat_completed_seconds": chatCompletedSeconds ?? -1,
        ]
        try JSONSerialization.data(withJSONObject: diagnostics, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("diagnostics.json"))
        try #require(controller.problem == nil, "Native controller problem: \(String(describing: controller.problem))")
        try #require(controller.phase == .listening && !chat.isStreaming)
        #expect(audio.chunks > 1)
        #expect(firstPCMWhileChatStreaming)
        #expect(chat.messages.contains { $0.role == .user && $0.content == controller.recognizedText })
        #expect(chat.messages.contains { $0.role == .assistant && !$0.content.isEmpty })
        controller.stop()
        chat.stopAndPersist()
        let reloaded = ChatViewModel(toolDefaults: defaults, customInstructions: instructions,
                                     conversationStoreURL: store)
        try #require(reloaded.conversations.contains { conversation in
            conversation.messages.contains { $0.role == .user && $0.content == controller.recognizedText }
        })
        let report: [String: Any] = [
            "scope": "real native controller/ASR/chat/TTS HTTP; synthetic capture and playback drain, NOT acoustic AEC",
            "first_pcm_while_chat_streaming": firstPCMWhileChatStreaming,
            "first_pcm_seconds": firstPCMSeconds ?? -1,
            "capture_finished_seconds": captureFinishedSeconds,
            "first_pcm_after_capture_seconds": firstPCMSeconds.map { $0 - captureFinishedSeconds } ?? -1,
            "pcm_chunks": audio.chunks, "pcm_bytes": audio.byteCount,
            "total_seconds": Date().timeIntervalSince(started),
            "transcript": controller.recognizedText,
            "reply": chat.messages.filter { $0.role == .assistant }.map(\.content).joined(separator: "\n"),
            "conversation_persisted": true, "mic_activated": false,
            "production_readiness": productionReadiness,
            "readiness_scope": productionReadiness
                ? "real authenticated residency and production model selection; synthetic server ownership"
                : "explicit test-only readiness fixture",
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("result.json"))
    }
}

@MainActor
private final class HTTPProbeAudio: LiveVoiceAudioIO {
    var onInputFrame: (([Float]) -> Void)?
    var onPlaybackDrained: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var onFirstPCM: (() -> Void)?
    var isVoiceProcessingEnabled = false
    var starts = 0
    var chunks = 0
    var byteCount = 0
    func start(voiceProcessing: Bool) async throws {
        starts += 1
        isVoiceProcessingEnabled = voiceProcessing // synthetic API state, not hardware
    }
    func enqueuePCM(_ data: Data, sampleRate: Double) throws {
        guard sampleRate == 24_000, !data.isEmpty, data.count.isMultiple(of: 2) else {
            throw AudioClientError.invalidResponse
        }
        if chunks == 0 { onFirstPCM?() }
        chunks += 1; byteCount += data.count
        onPlaybackDrained?() // fast deterministic sink; engine queue has separate tests
    }
    func interruptPlayback() {}
    func stop() { isVoiceProcessingEnabled = false }
}

@MainActor
private final class HTTPProbeReadiness: LiveVoiceModelReadiness {
    let models: LiveVoiceModels
    init(models: LiveVoiceModels) { self.models = models }
    func refresh() async -> LiveVoiceModels? { models }
    func isStillReady(_ models: LiveVoiceModels) -> Bool { self.models == models }
}

@MainActor
private struct HTTPProbeTranscript: View {
    let chat: ChatViewModel
    var body: some View {
        YouziSimpleTranscript(messages: chat.messages, followsReply: false) { message in
            HStack(alignment: .top) {
                Text(message.role == .assistant ? "AI" : "You")
                if message.status == .streaming || message.role != .assistant {
                    Text(message.content).textSelection(.enabled)
                } else {
                    TextKitMarkdownView(content: message.content).textSelection(.enabled)
                }
            }
        }
    }
}
