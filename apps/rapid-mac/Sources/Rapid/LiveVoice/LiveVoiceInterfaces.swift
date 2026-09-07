import Foundation

/// Test seams never activate AVFoundation. The production adapter alone owns
/// the native engine, and only an explicit Start gesture invokes start().
@MainActor
protocol LiveVoiceAudioIO: AnyObject {
    var onInputFrame: (([Float]) -> Void)? { get set }
    var onPlaybackDrained: (() -> Void)? { get set }
    var onFailure: ((String) -> Void)? { get set }
    var isVoiceProcessingEnabled: Bool { get }
    func start(voiceProcessing: Bool) async throws
    func enqueuePCM(_ data: Data, sampleRate: Double) throws
    func interruptPlayback()
    func stop()
}

protocol LiveVoiceTransport: Sendable {
    func transcribe(audioData: Data, model: String, context: String?, port: Int, bearer: String?) async throws -> AudioTranscriptionResult
    func voices(model: String, port: Int, bearer: String?) async throws -> [String]
    func streamSpeech(text: String, model: String, voice: String?, port: Int, bearer: String?,
                      onChunk: @escaping @MainActor (Data, Double) async throws -> Void) async throws
}

struct LiveVoiceEndpoint: Equatable, Sendable {
    let model: String
    let port: Int
    let bearer: String?
}

struct LiveVoiceModels: Equatable, Sendable {
    let chatAlias: String
    let recognition: LiveVoiceEndpoint
    let speech: LiveVoiceEndpoint

    /// This UI has no reference-audio or voice-design flow. Match the only
    /// reference-free named-speaker family supported by incremental PCM today.
    static func supportsStreamingSpeech(_ model: String) -> Bool {
        let name = model.lowercased().replacingOccurrences(of: "_", with: "-")
        guard name.contains("qwen3-tts"), !name.contains("voicedesign"), !name.contains("base") else { return false }
        return name.contains("customvoice") || ["qwen3-tts", "qwen3-tts-4bit", "qwen3-tts-6bit"].contains(name)
    }
}

@MainActor
protocol LiveVoiceModelReadiness: AnyObject {
    func refresh() async -> LiveVoiceModels?
    func isStillReady(_ models: LiveVoiceModels) -> Bool
}

/// Only assistant content is projected by the adapter. No reasoning field,
/// tool result, tool-call arguments, or hidden prompts cross this boundary.
struct LiveVoiceAssistantText: Equatable, Sendable {
    let id: UUID
    let text: String
    let isComplete: Bool
    let isSpeakable: Bool
}

@MainActor
protocol LiveVoiceChatSession: AnyObject {
    var currentTurn: LiveVoiceChatTurn { get }
    var isStreaming: Bool { get }
    var hasError: Bool { get }
    var assistantText: [LiveVoiceAssistantText] { get }
    func send(_ text: String, alias: String) -> LiveVoiceChatTurn?
    func stopOwnedTurn(_ turn: LiveVoiceChatTurn)
}
