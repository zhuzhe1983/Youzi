import Foundation
import Observation

/// Orchestrates existing chat + windowed HTTP ASR + sentence-streamed PCM TTS.
/// AEC being enabled describes an API state, not an attended acoustic test.
@MainActor @Observable
final class YouziLiveVoiceController {
    enum Phase: Equatable { case stopped, preparing, listening, transcribing, responding }
    enum Problem: Equatable {
        case modelsMissing, chatBusy, microphone, voiceProcessing, recognition, speech
        case deviceChanged, replyChanged, replyTooLong, preparation, chatFailed
        case unsupportedSpeechModel, utteranceTooLong
    }
    private(set) var phase: Phase = .stopped
    private(set) var problem: Problem?
    private(set) var isMicrophoneOn = false
    private(set) var isStarting = false
    private(set) var isHalfDuplex = false
    private(set) var recognizedText = ""
    private(set) var assistantPreview = ""
    private(set) var selectedModels: LiveVoiceModels?
    private(set) var isUserSpeaking = false
    var isActive: Bool { lifetime.isActive }
    var canFinishUtterance: Bool { isMicrophoneOn && isUserSpeaking }

    @ObservationIgnored private let audio: any LiveVoiceAudioIO
    @ObservationIgnored private let transport: any LiveVoiceTransport
    @ObservationIgnored private let chat: any LiveVoiceChatSession
    @ObservationIgnored private let readiness: any LiveVoiceModelReadiness
    @ObservationIgnored private let defaults: ModelGenerationDefaults
    @ObservationIgnored private var lifetime = LiveVoiceTurnState()
    @ObservationIgnored private var detector = LiveVoiceUtteranceDetector()
    @ObservationIgnored private var captureID = UUID()
    @ObservationIgnored private var observedTurn: LiveVoiceChatTurn?
    @ObservationIgnored private var cancellingTurn: LiveVoiceChatTurn?
    @ObservationIgnored private var recognitionTask: Task<Void, Never>?
    @ObservationIgnored private var speechTask: Task<Void, Never>?
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    @ObservationIgnored private var voice: String?
    @ObservationIgnored private var pendingSpeech: [String] = []
    @ObservationIgnored private var playbackOutstanding = false
    @ObservationIgnored private var playbackPacing = LiveVoicePlaybackPacing()
    @ObservationIgnored private var historicalMessageIDs: Set<UUID> = []
    @ObservationIgnored private var textProgress: [UUID: TextProgress] = [:]

    private struct TextProgress {
        var text = ""
        var segmenter = LiveVoiceSentenceSegmenter()
        var finished = false
    }

    init(audio: any LiveVoiceAudioIO, transport: any LiveVoiceTransport,
         chat: any LiveVoiceChatSession, readiness: any LiveVoiceModelReadiness,
         defaults: ModelGenerationDefaults = ModelGenerationDefaults()) {
        self.audio = audio; self.transport = transport; self.chat = chat
        self.readiness = readiness; self.defaults = defaults
    }

    /// Called by an explicit user gesture only. Reading residency/voice metadata
    /// does not load weights. A failed AEC start NEVER silently retries without it.
    func start(halfDuplex: Bool = false) async {
        guard !isStarting, !isActive else { return }
        guard !chat.isStreaming else { problem = .chatBusy; return }
        isStarting = true
        defer { isStarting = false }
        problem = nil
        phase = .preparing
        let epoch = lifetime.start()
        observedTurn = chat.currentTurn
        let id = UUID()
        captureID = id
        guard let models = await readiness.refresh() else {
            if lifetime.accepts(epoch) { fail(.modelsMissing) }
            return
        }
        guard valid(epoch) else { return }
        selectedModels = models
        guard LiveVoiceModels.supportsStreamingSpeech(models.speech.model) else {
            fail(.unsupportedSpeechModel); return
        }
        do {
            let voices = try await transport.voices(model: models.speech.model,
                port: models.speech.port, bearer: models.speech.bearer)
            guard valid(epoch), readiness.isStillReady(models) else {
                if lifetime.accepts(epoch) { fail(.modelsMissing) }; return
            }
            guard let selectedVoice = defaults.voice(for: models.speech.model, available: voices) else {
                fail(.speech); return
            }
            voice = selectedVoice
        } catch {
            if valid(epoch) { fail(.speech) }
            return
        }
        audio.onInputFrame = { [weak self] samples in
            guard let self, self.captureID == id, self.isMicrophoneOn else { return }
            self.receive(samples)
        }
        audio.onFailure = { [weak self] _ in
            guard let self, self.captureID == id, self.isActive else { return }
            self.fail(.deviceChanged)
        }
        do {
            try await audio.start(voiceProcessing: !halfDuplex)
            guard valid(epoch), !Task.isCancelled else {
                // No new start is allowed while isStarting is true: a late
                // permission callback can safely close this old engine.
                audio.stop()
                if lifetime.accepts(epoch) { stop() }
                return
            }
            guard halfDuplex || audio.isVoiceProcessingEnabled else {
                fail(.voiceProcessing); return
            }
        } catch {
            if lifetime.accepts(epoch) { fail(halfDuplex ? .microphone : .voiceProcessing) }
            return
        }
        isHalfDuplex = halfDuplex
        isMicrophoneOn = true
        detector.reset()
        phase = .listening
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isActive else { return }
                self.pollChat()
                do { try await Task.sleep(for: .milliseconds(40)) } catch { return }
            }
        }
    }

    /// Dismissal/navigation/mic-off all use this path. Approval handoff is the
    /// one explicit exception: stop capture/playback but leave chat's original
    /// human confirmation continuation and persistence machinery in charge.
    func stop(cancelOwnedChat: Bool = true) {
        let target = lifetime.invalidate(currentTurn: chat.currentTurn,
            isStreaming: chat.isStreaming, stopping: true)
        if cancelOwnedChat, let target { chat.stopOwnedTurn(target) }
        recognitionTask?.cancel(); recognitionTask = nil
        speechTask?.cancel(); speechTask = nil
        monitorTask?.cancel(); monitorTask = nil
        captureID = UUID()
        audio.onInputFrame = nil; audio.onPlaybackDrained = nil; audio.onFailure = nil
        audio.stop()
        pendingSpeech = []; textProgress = [:]
        playbackOutstanding = false
        playbackPacing.drained()
        detector.reset()
        isUserSpeaking = false
        isMicrophoneOn = false
        phase = .stopped
    }

    func handoffToChat() { stop(cancelOwnedChat: false) }

    /// Explicit barge-in works in either mode. In half duplex, capture frames
    /// are ignored while replying; this button returns the session to listening.
    func interrupt() { interrupt(resetDetector: true) }

    private func interrupt(resetDetector: Bool) {
        guard isActive else { return }
        let target = lifetime.invalidate(currentTurn: chat.currentTurn, isStreaming: chat.isStreaming)
        if let target { cancellingTurn = target; chat.stopOwnedTurn(target) }
        recognitionTask?.cancel(); recognitionTask = nil
        speechTask?.cancel(); speechTask = nil
        audio.interruptPlayback()
        audio.onPlaybackDrained = nil
        pendingSpeech = []; textProgress = [:]
        playbackOutstanding = false; playbackPacing.drained()
        if resetDetector { detector.reset(); isUserSpeaking = false }
        phase = .listening
    }

    func finishUtterance() {
        guard isActive, let samples = detector.finish() else { return }
        isUserSpeaking = false
        recognize(samples)
    }

    private func receive(_ samples: [Float]) {
        guard checkContext() else { return }
        if isHalfDuplex && phase != .listening { detector.reset(); return }
        for event in detector.append(samples) {
            switch event {
            case .speechStarted:
                isUserSpeaking = true
                if phase == .responding || phase == .transcribing { interrupt(resetDetector: false) }
            case .limitReached:
                // Never transcribe/send a partial command at the duration cap.
                // Continuing speech must not race a prematurely submitted turn.
                fail(.utteranceTooLong)
                return
            case .utterance(let window):
                isUserSpeaking = false
                recognize(window)
            }
        }
    }

    private func recognize(_ samples: [Float]) {
        guard checkContext() else { return }
        let epoch = lifetime.epoch
        phase = .transcribing
        recognitionTask?.cancel()
        recognitionTask = Task { [weak self] in
            guard let self else { return }
            guard let models = await self.readiness.refresh() else {
                if self.valid(epoch) { self.fail(.modelsMissing) }; return
            }
            guard self.valid(epoch), !Task.isCancelled else { return }
            guard self.selectedModels == models else { self.fail(.modelsMissing); return }
            self.selectedModels = models
            do {
                let result = try await self.transport.transcribe(
                    audioData: LiveVoiceUtteranceDetector.wavData(samples),
                    model: models.recognition.model, context: nil,
                    port: models.recognition.port, bearer: models.recognition.bearer)
                guard self.valid(epoch), !Task.isCancelled else { return }
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { self.phase = .listening; return }
                self.recognizedText = text
                // stopOwnedTurn is asynchronous. Wait only for OUR cancelled
                // turn, never for or cancel a newly typed/background turn.
                let deadline = ProcessInfo.processInfo.systemUptime + 5
                while self.chat.isStreaming && self.chat.currentTurn == self.cancellingTurn {
                    guard self.valid(epoch), ProcessInfo.processInfo.systemUptime < deadline else { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                guard self.valid(epoch), !Task.isCancelled else { return }
                guard !self.chat.isStreaming else { self.fail(.chatBusy); return }
                guard self.readiness.isStillReady(models) else { self.fail(.modelsMissing); return }
                self.historicalMessageIDs = Set(self.chat.assistantText.map(\.id))
                self.textProgress = [:]; self.pendingSpeech = []
                guard let turn = self.chat.send(text, alias: models.chatAlias) else {
                    self.fail(.preparation); return
                }
                self.observedTurn = turn
                _ = self.lifetime.own(turn, at: epoch)
                self.phase = .responding
                self.beginSpeech(epoch: epoch, models: models)
            } catch {
                if self.valid(epoch), !Task.isCancelled { self.fail(.recognition) }
            }
        }
    }

    private func beginSpeech(epoch: UInt64, models: LiveVoiceModels) {
        audio.onPlaybackDrained = { [weak self] in
            guard let self, self.acceptsAudio(epoch) else { return }
            self.playbackOutstanding = false
            self.playbackPacing.drained()
        }
        speechTask = Task { [weak self] in
            guard let self else { return }
            do {
                while self.acceptsAudio(epoch), !Task.isCancelled {
                    self.pollChat()
                    guard self.acceptsAudio(epoch) else { return }
                    if !self.pendingSpeech.isEmpty {
                        let sentence = self.pendingSpeech.removeFirst()
                        try await self.transport.streamSpeech(text: sentence, model: models.speech.model,
                            voice: self.voice, port: models.speech.port, bearer: models.speech.bearer
                        ) { [weak self] data, sampleRate in
                            guard let self, self.acceptsAudio(epoch), !Task.isCancelled else { throw CancellationError() }
                            guard sampleRate == 24_000, !data.isEmpty, data.count.isMultiple(of: 2) else {
                                throw AudioClientError.invalidResponse
                            }
                            // Bound scheduled audio to ~1.5 s ahead. This is
                            // playback backpressure, NOT full-response buffering.
                            while self.playbackPacing.shouldWait(now: ProcessInfo.processInfo.systemUptime) {
                                try await Task.sleep(for: .milliseconds(20))
                                guard self.acceptsAudio(epoch) else { throw CancellationError() }
                            }
                            guard self.acceptsAudio(epoch), !Task.isCancelled else { throw CancellationError() }
                            self.playbackOutstanding = true
                            self.playbackPacing.scheduled(byteCount: data.count, sampleRate: sampleRate,
                                now: ProcessInfo.processInfo.systemUptime)
                            try self.audio.enqueuePCM(data, sampleRate: sampleRate)
                        }
                        // Serial speech requests; next sentence starts only when
                        // this one's native buffers drain. Chat deltas continue.
                        let deadline = ProcessInfo.processInfo.systemUptime + 60
                        while self.playbackOutstanding {
                            guard self.acceptsAudio(epoch), ProcessInfo.processInfo.systemUptime < deadline else { throw CancellationError() }
                            try await Task.sleep(for: .milliseconds(20))
                        }
                    } else if !self.chat.isStreaming {
                        self.lifetime.releaseTurn()
                        self.phase = .listening
                        self.detector.reset()
                        return
                    } else {
                        try await Task.sleep(for: .milliseconds(40))
                    }
                }
            } catch {
                if self.acceptsAudio(epoch), !Task.isCancelled {
                    // Text/tools may continue even when audio transport fails.
                    self.problem = .speech
                    self.handoffToChat()
                }
            }
        }
    }

    /// Also used as a deterministic test seam. Polls only incremental content
    /// changes; no new LLM request or hidden voice instruction is introduced.
    func pollChat() {
        guard checkContext(), let models = selectedModels else { return }
        guard readiness.isStillReady(models) else { fail(.modelsMissing); return }
        guard lifetime.ownedTurn != nil else { return }
        if chat.hasError { problem = .chatFailed; handoffToChat(); return }
        let messages = chat.assistantText
        let currentIDs = Set(messages.map(\.id))
        // A tool-grounding retry can replace/remove even a completed message
        // without ending the owning chat turn. Never keep its queued PCM alive.
        if textProgress.contains(where: { !currentIDs.contains($0.key) && !$0.value.text.isEmpty }) {
            problem = .replyChanged; handoffToChat(); return
        }
        for message in messages where !historicalMessageIDs.contains(message.id) {
            var progress = textProgress[message.id] ?? TextProgress()
            if progress.finished {
                guard message.text == progress.text, message.isSpeakable,
                      message.isComplete || !chat.isStreaming else {
                    problem = .replyChanged; handoffToChat(); return
                }
                continue
            }
            guard message.isSpeakable else {
                if !progress.text.isEmpty {
                    problem = .replyChanged; handoffToChat(); return
                }
                textProgress[message.id] = progress; continue
            }
            guard message.text.hasPrefix(progress.text) else {
                // Some recovery paths rewrite a reply rather than append. Old
                // audio cannot be taken back: stop instead of speaking a splice.
                problem = .replyChanged; handoffToChat(); return
            }
            let delta = String(message.text.dropFirst(progress.text.count))
            pendingSpeech += progress.segmenter.append(delta)
            progress.text = message.text
            if message.isComplete || !chat.isStreaming {
                pendingSpeech += progress.segmenter.finish()
                progress.finished = true
            }
            textProgress[message.id] = progress
            if !message.text.isEmpty { assistantPreview = String(message.text.suffix(2000)) }
            // Headings, poetry and short Chinese sentences can produce many
            // small segments. Bound text and count without rejecting an
            // ordinary explanation merely because it exceeds 24 lines.
            if pendingSpeech.count > 96 || pendingSpeech.reduce(0, { $0 + $1.count }) > 6000 {
                problem = .replyTooLong; handoffToChat(); return
            }
        }
    }

    private func valid(_ epoch: UInt64) -> Bool {
        guard lifetime.accepts(epoch) else { return false }
        guard observedTurn == chat.currentTurn else { stop(); return false }
        return true
    }
    private func acceptsAudio(_ epoch: UInt64) -> Bool {
        lifetime.accepts(epoch, currentTurn: chat.currentTurn) && observedTurn == chat.currentTurn
    }
    private func checkContext() -> Bool {
        guard isActive else { return false }
        guard observedTurn == chat.currentTurn else { stop(); return false }
        if lifetime.ownedTurn == nil && chat.isStreaming && chat.currentTurn != cancellingTurn {
            fail(.chatBusy); return false
        }
        return true
    }
    private func fail(_ problem: Problem) {
        self.problem = problem
        stop()
    }
}
