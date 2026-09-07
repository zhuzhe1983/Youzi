import Foundation

extension YouziLiveAudioEngine: LiveVoiceAudioIO {}
extension AudioClient: LiveVoiceTransport {}

@MainActor
final class LiveVoiceResidentModels: LiveVoiceModelReadiness {
    let server: ServerManager
    let chatAlias: String
    init(server: ServerManager, chatAlias: String) {
        self.server = server
        self.chatAlias = chatAlias
    }

    func refresh() async -> LiveVoiceModels? {
        guard await server.refreshResidency(), server.isModelResident(chatAlias),
              let stt = readyLane("stt"), let tts = readyLane("tts") else { return nil }
        return LiveVoiceModels(
            chatAlias: chatAlias,
            recognition: LiveVoiceEndpoint(model: stt, port: server.activePort, bearer: server.activeBearer),
            speech: LiveVoiceEndpoint(model: tts, port: server.activePort, bearer: server.activeBearer)
        )
    }

    func isStillReady(_ models: LiveVoiceModels) -> Bool {
        server.isModelResident(models.chatAlias)
            && server.activePort == models.recognition.port
            && server.activeBearer == models.recognition.bearer
            && readyLane("stt") == models.recognition.model
            && readyLane("tts") == models.speech.model
    }

    private func readyLane(_ lane: String) -> String? {
        server.residency.audioLanes.first {
            $0.lane == lane && ($0.state == "resident" || $0.state == "busy")
        }?.model
    }
}

@MainActor
final class LiveVoiceChatAdapter: LiveVoiceChatSession {
    let chat: ChatViewModel
    private let prepareTurn: ((String) -> [ChatFileAttachment]?)?
    init(chat: ChatViewModel, prepareTurn: ((String) -> [ChatFileAttachment]?)? = nil) {
        self.chat = chat
        self.prepareTurn = prepareTurn
    }
    var currentTurn: LiveVoiceChatTurn { chat.liveVoiceCurrentTurn }
    var isStreaming: Bool { chat.isStreaming }
    var hasError: Bool { chat.lastError != nil }
    var assistantText: [LiveVoiceAssistantText] {
        chat.messages.compactMap { message in
            guard message.role == .assistant else { return nil }
            return LiveVoiceAssistantText(
                id: message.id, text: message.content,
                isComplete: message.status != .streaming,
                isSpeakable: message.status != .failed && (message.toolCalls?.isEmpty ?? true)
            )
        }
    }
    func send(_ text: String, alias: String) -> LiveVoiceChatTurn? {
        guard !chat.isStreaming else { return nil }
        let files: [ChatFileAttachment]
        if let prepareTurn {
            guard let prepared = prepareTurn(text) else { return nil }
            files = prepared
        } else { files = [] }
        return chat.sendLiveVoice(text, alias: alias, fileAttachments: files)
    }
    func stopOwnedTurn(_ turn: LiveVoiceChatTurn) { chat.stopLiveVoiceTurn(turn) }
}
