import Foundation

/// The conversational identity currently wearing Youzi's ears and voice.
/// A global session behaves like a system-wide assistant; an assistant-scoped
/// session keeps the exact helper identity selected by the user.
enum YouziVoiceSessionScope: Equatable, Sendable {
    case global
    case assistant(id: UUID)
}

/// Switching helpers is explicit about transcript ownership. This prevents a
/// global session from silently leaking prior turns into an unrelated helper.
enum YouziVoiceContextHandoffPolicy: Equatable, Sendable {
    case continueCurrentConversation
    case adoptDestinationConversation
}

struct YouziLocalVoiceProfile: Equatable, Sendable {
    let transcriptionAlias: String
    let transcriptionModelPath: String?
    let transcriptionContext: String?
    let speechAlias: String
    let speechModelPath: String?
    let voice: String
    let speed: Double

    init(
        transcriptionAlias: String,
        transcriptionModelPath: String? = nil,
        transcriptionContext: String? = nil,
        speechAlias: String,
        speechModelPath: String? = nil,
        voice: String,
        speed: Double = 1
    ) {
        self.transcriptionAlias = transcriptionAlias
        self.transcriptionModelPath = transcriptionModelPath
        self.transcriptionContext = transcriptionContext
        self.speechAlias = speechAlias
        self.speechModelPath = speechModelPath
        self.voice = voice
        self.speed = speed
    }

    var isValid: Bool {
        Self.isValidIdentifier(transcriptionAlias)
            && Self.isValidIdentifier(speechAlias)
            && Self.isValidIdentifier(voice)
            && speed.isFinite
            && (0.5...2).contains(speed)
            && (transcriptionContext?.utf8.count ?? 0) <= 8_192
            && Self.isValidOptionalModelPath(transcriptionModelPath)
            && Self.isValidOptionalModelPath(speechModelPath)
    }

    private static func isValidIdentifier(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.utf8.count <= 256
            && !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func isValidOptionalModelPath(_ value: String?) -> Bool {
        guard let value else { return true }
        return !value.isEmpty && value.utf8.count <= 1_024
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}

/// Exact assistant turn inputs for a voice session. The controller builds a
/// normal ``AssistantTurnRunner.Request`` from this value; voice has no second
/// LLM or tool execution path.
struct YouziVoiceAssistantContext {
    let scope: YouziVoiceSessionScope
    let conversationID: UUID
    let messages: [ChatMessage]
    let assistantAlias: String
    let supportsImageInput: Bool
    let startupHFPath: String?
    let definitions: [ToolDefinition]
    let sampling: AssistantTurnRunner.Sampling
    let contextWindow: Int?
    let globalInstruction: String
    let assistantInstruction: String
    let memoryContext: String?
    let executionContext: YouziScopedChatTurnContext?
    let dispatchAuthorizer: (any YouziToolDispatchAuthorizing)?
    let voiceProfile: YouziLocalVoiceProfile

    init(
        scope: YouziVoiceSessionScope,
        conversationID: UUID,
        messages: [ChatMessage] = [],
        assistantAlias: String,
        supportsImageInput: Bool = false,
        startupHFPath: String? = nil,
        definitions: [ToolDefinition] = [],
        sampling: AssistantTurnRunner.Sampling = .standard,
        contextWindow: Int? = nil,
        globalInstruction: String = "",
        assistantInstruction: String = "",
        memoryContext: String? = nil,
        executionContext: YouziScopedChatTurnContext? = nil,
        dispatchAuthorizer: (any YouziToolDispatchAuthorizing)? = nil,
        voiceProfile: YouziLocalVoiceProfile
    ) {
        self.scope = scope
        self.conversationID = conversationID
        self.messages = messages
        self.assistantAlias = assistantAlias
        self.supportsImageInput = supportsImageInput
        self.startupHFPath = startupHFPath
        self.definitions = definitions
        self.sampling = sampling
        self.contextWindow = contextWindow
        self.globalInstruction = globalInstruction
        self.assistantInstruction = assistantInstruction
        self.memoryContext = memoryContext
        self.executionContext = executionContext
        self.dispatchAuthorizer = dispatchAuthorizer
        self.voiceProfile = voiceProfile
    }

    var isValid: Bool {
        let alias = assistantAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        return !alias.isEmpty && alias.utf8.count <= 256
            && !alias.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && voiceProfile.isValid
            && (contextWindow.map { $0 > 0 } ?? true)
    }

    func replacingConversation(
        id: UUID,
        messages: [ChatMessage]
    ) -> YouziVoiceAssistantContext {
        YouziVoiceAssistantContext(
            scope: scope,
            conversationID: id,
            messages: messages,
            assistantAlias: assistantAlias,
            supportsImageInput: supportsImageInput,
            startupHFPath: startupHFPath,
            definitions: definitions,
            sampling: sampling,
            contextWindow: contextWindow,
            globalInstruction: globalInstruction,
            assistantInstruction: assistantInstruction,
            memoryContext: memoryContext,
            executionContext: executionContext,
            dispatchAuthorizer: dispatchAuthorizer,
            voiceProfile: voiceProfile
        )
    }

    func appendingUserTranscript(_ transcript: String) -> YouziVoiceAssistantContext {
        var next = messages
        next.append(ChatMessage(
            role: .user,
            content: transcript,
            parentID: next.last?.id
        ))
        return replacingConversation(id: conversationID, messages: next)
    }

    func replacingMessages(_ messages: [ChatMessage]) -> YouziVoiceAssistantContext {
        replacingConversation(id: conversationID, messages: messages)
    }

    func makeTurnRequest() -> AssistantTurnRunner.Request {
        AssistantTurnRunner.Request(
            conversationID: conversationID,
            alias: assistantAlias,
            messages: messages,
            supportsImageInput: supportsImageInput,
            startupHFPath: startupHFPath,
            definitions: definitions,
            sampling: sampling,
            contextWindow: contextWindow,
            globalInstruction: globalInstruction,
            conversationInstruction: assistantInstruction,
            memoryContext: memoryContext,
            executionContext: executionContext,
            dispatchAuthorizer: dispatchAuthorizer,
            announcesForVoiceOver: false
        )
    }
}

/// Voice never infers authority from microphone TCC alone. Composition must
/// supply the exact Youzi domain decision and explicit local-processing
/// consent. Policies that permit cloud speech or raw-audio persistence are
/// rejected by this runtime even if the caller otherwise grants access.
struct YouziVoicePrivacyAuthorization: Equatable, Sendable {
    let domainMicrophoneAuthorized: Bool
    let localProcessingConsented: Bool
    let speechPlaybackAuthorized: Bool
    let permitsRemoteSpeechProcessing: Bool
    let permitsRawAudioPersistence: Bool

    init(
        domainMicrophoneAuthorized: Bool,
        localProcessingConsented: Bool,
        speechPlaybackAuthorized: Bool,
        permitsRemoteSpeechProcessing: Bool = false,
        permitsRawAudioPersistence: Bool = false
    ) {
        self.domainMicrophoneAuthorized = domainMicrophoneAuthorized
        self.localProcessingConsented = localProcessingConsented
        self.speechPlaybackAuthorized = speechPlaybackAuthorized
        self.permitsRemoteSpeechProcessing = permitsRemoteSpeechProcessing
        self.permitsRawAudioPersistence = permitsRawAudioPersistence
    }

    var denial: YouziVoicePermissionDenial? {
        if !domainMicrophoneAuthorized { return .domainMicrophonePermissionRequired }
        if !localProcessingConsented { return .localProcessingConsentRequired }
        if !speechPlaybackAuthorized { return .speechPlaybackNotAuthorized }
        if permitsRemoteSpeechProcessing { return .remoteSpeechPolicyRejected }
        if permitsRawAudioPersistence { return .rawAudioPersistencePolicyRejected }
        return nil
    }
}

enum YouziVoicePermissionDenial: Equatable, Sendable {
    case domainMicrophonePermissionRequired
    case localProcessingConsentRequired
    case systemMicrophonePermissionRequired
    case speechPlaybackNotAuthorized
    case remoteSpeechPolicyRejected
    case rawAudioPersistencePolicyRejected
}

enum YouziVoiceSessionFailure: Equatable, Sendable {
    case permissionDenied(YouziVoicePermissionDenial)
    case invalidConfiguration
    case captureUnavailable
    case audioRuntimeUnavailable
    case transcriptionFailed
    case assistantFailed
    case synthesisFailed
    case playbackFailed
}

/// The only state intended for the immersive voice surface. It deliberately
/// contains no transcript, label, error copy, settings, or tool detail.
struct YouziVoiceOrbPresentation: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case hidden
        case awakening
        case listening
        case hearing
        case thinking
        case speaking
        case interrupted
        case failed
    }

    enum Motion: Equatable, Sendable {
        case still
        case breathe
        case attend
        case orbit
        case resonate
        case recoil
    }

    let phase: Phase
    let motion: Motion
    let energy: Float
    let scope: YouziVoiceSessionScope?

    static let hidden = YouziVoiceOrbPresentation(
        phase: .hidden,
        motion: .still,
        energy: 0,
        scope: nil
    )
}

enum YouziVoiceSessionEvent {
    case started(scope: YouziVoiceSessionScope, conversationID: UUID)
    case contextHandedOff(
        from: YouziVoiceSessionScope,
        to: YouziVoiceSessionScope,
        conversationID: UUID
    )
    case transcriptRecognized(text: String, conversationID: UUID)
    case assistantTurnUpdated(AssistantTurnRunner.Event)
    case assistantTurnCompleted(AssistantTurnRunner.Outcome)
    case interrupted
    case stopped
    case failed(YouziVoiceSessionFailure)
}

struct YouziVoiceActivityDetector: Sendable {
    struct Configuration: Equatable, Sendable {
        let speechStartLevel: Float
        let speechContinueLevel: Float
        let minimumSpeechDuration: TimeInterval
        let endSilenceDuration: TimeInterval
        let maximumUtteranceDuration: TimeInterval

        static let conversational = Configuration(
            speechStartLevel: 0.045,
            speechContinueLevel: 0.018,
            minimumSpeechDuration: 0.16,
            endSilenceDuration: 0.68,
            maximumUtteranceDuration: 45
        )

        /// Playback is present in the microphone signal until the product can
        /// rely on hardware echo cancellation. A higher sustained threshold
        /// prevents ordinary speaker bleed from interrupting every response,
        /// while still allowing a deliberate nearby voice to barge in.
        static let bargeIn = Configuration(
            speechStartLevel: 0.12,
            speechContinueLevel: 0.055,
            minimumSpeechDuration: 0.22,
            endSilenceDuration: 0.58,
            maximumUtteranceDuration: 45
        )

        var isValid: Bool {
            speechStartLevel.isFinite && speechContinueLevel.isFinite
                && speechStartLevel > speechContinueLevel
                && speechContinueLevel >= 0
                && minimumSpeechDuration > 0
                && endSilenceDuration > 0
                && maximumUtteranceDuration > minimumSpeechDuration
        }
    }

    enum Event: Equatable, Sendable {
        case none
        case speechBegan
        case utteranceEnded
        case maximumDurationReached
    }

    private let configuration: Configuration
    private var candidateBeganAt: TimeInterval?
    private var speechBeganAt: TimeInterval?
    private var lastSpeechAt: TimeInterval?

    init(configuration: Configuration = .conversational) {
        precondition(configuration.isValid)
        self.configuration = configuration
    }

    mutating func reset() {
        candidateBeganAt = nil
        speechBeganAt = nil
        lastSpeechAt = nil
    }

    mutating func process(level rawLevel: Float, at now: TimeInterval) -> Event {
        guard now.isFinite else { return .none }
        let level = max(0, min(1, rawLevel.isFinite ? rawLevel : 0))

        if let speechBeganAt {
            if level >= configuration.speechContinueLevel { lastSpeechAt = now }
            if now - speechBeganAt >= configuration.maximumUtteranceDuration {
                reset()
                return .maximumDurationReached
            }
            if let lastSpeechAt,
               now - lastSpeechAt >= configuration.endSilenceDuration {
                reset()
                return .utteranceEnded
            }
            return .none
        }

        if level >= configuration.speechStartLevel {
            let beganAt = candidateBeganAt ?? now
            candidateBeganAt = beganAt
            lastSpeechAt = now
            if now - beganAt >= configuration.minimumSpeechDuration {
                speechBeganAt = beganAt
                return .speechBegan
            }
        } else if level < configuration.speechContinueLevel {
            candidateBeganAt = nil
            lastSpeechAt = nil
        }
        return .none
    }
}
