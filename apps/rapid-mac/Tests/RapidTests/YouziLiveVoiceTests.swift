import Foundation
import Testing
@testable import Rapid

@Suite("Live voice speech projection")
struct LiveVoiceSegmentationTests {
    private func project(_ text: String, width: Int) -> [String] {
        var segmenter = LiveVoiceSentenceSegmenter()
        let chars = Array(text)
        var result: [String] = []
        for start in stride(from: 0, to: chars.count, by: width) {
            result += segmenter.append(String(chars[start..<min(start + width, chars.count)]))
        }
        return result + segmenter.finish()
    }

    @Test("Every delta split suppresses fenced code, inline code, JSON and reasoning", arguments: [1, 2, 3, 7, 41, 4096])
    func splitSyntax(width: Int) {
        let text = "Hello. ```swift\nprint(\"SECRET.\")\n``` Use `hiddenCode()` safely. <think>SECRET thought.</think> {\"tool\":{\"args\":\"SECRET } \\\"\"}} Done! "
        let spoken = project(text, width: width).joined(separator: " ")
        #expect(spoken == "Hello. Use safely. Done!")
        #expect(!spoken.contains("SECRET"))
        #expect(!spoken.contains("hiddenCode"))
    }

    @Test("Chinese boundaries stream without waiting for whitespace")
    func chinese() {
        var parser = LiveVoiceSentenceSegmenter()
        #expect(parser.append("你好。可以") == ["你好。"])
        #expect(parser.append("开始了！下一") == ["可以开始了！"])
        #expect(parser.finish() == ["下一"])
    }

    @Test("English waits for complete sentences and preserves abbreviations/decimals")
    func english() {
        var parser = LiveVoiceSentenceSegmenter()
        #expect(parser.append("Dr. Lee measured 3.14") == [])
        #expect(parser.append(" meters. ") == ["Dr. Lee measured 3.14 meters."])
        #expect(parser.append("Next sentence!") == [])
        #expect(parser.finish() == ["Next sentence!"])
    }

    @Test("Unterminated markup cannot leak code or hidden analysis on final flush")
    func unfinished() {
        for marker in ["```swift\n", "`", "<analysis>", "<reasoning>", "{\"key\":\"", "[\"", "[link]("] {
            #expect(project("Safe. " + marker + "SECRET payload.", width: 1) == ["Safe."])
        }
    }

    @Test("Links, markdown chrome and tilde fences are not spoken as syntax")
    func markdown() {
        let spoken = project("# Hello **friend**. Visit [the guide](https://example.com/a). ~~~py\nSECRET\n~~~ Finished.", width: 1)
        #expect(spoken == ["Hello friend.", "Visit the guide.", "Finished."])
    }

    @Test("JSON literal arrays are hidden without eating ordinary Markdown labels", arguments: [1, 2, 7, 4096])
    func arrayLiterals(width: Int) {
        let text = "Use [the guide](https://example.com). [false, true, null] [null] [true] Read [facts](https://example.com) and [notes](https://example.com)."
        #expect(project(text, width: width) == ["Use the guide.", "Read facts and notes."])
    }

    @Test("Long responses are bounded and malformed markup is dropped")
    func bounds() {
        var parser = LiveVoiceSentenceSegmenter(maximumCharacters: 80)
        let result = parser.append(String(repeating: "word ", count: 200)) + parser.finish()
        #expect(result.count > 5)
        #expect(result.allSatisfy { $0.count <= 80 })
        var malformed = LiveVoiceSentenceSegmenter()
        #expect(malformed.append("<" + String(repeating: "SECRET", count: 1000)).isEmpty)
        #expect(malformed.discardedOversizeInput)
        #expect(malformed.finish().isEmpty)
    }
}

@Suite("Live voice utterance windows and ownership")
struct LiveVoicePureStateTests {
    @Test("Silence, nonfinite values and short noise spikes do not open a turn")
    func noise() {
        var detector = LiveVoiceUtteranceDetector()
        #expect(detector.append(Array(repeating: 0, count: 16_000 * 2)).isEmpty)
        #expect(detector.append(Array(repeating: .nan, count: 320)).isEmpty)
        #expect(detector.append(Array(repeating: 0.7, count: 320 * 3)).isEmpty)
        #expect(detector.append(Array(repeating: 0.002, count: 16_000)).isEmpty)
        #expect(detector.finish() == nil)
        #expect(detector.bufferedSampleCount == 0)
    }

    @Test("Sustained voice emits one start, then one silence-ended HTTP window")
    func utterance() {
        var detector = LiveVoiceUtteranceDetector()
        #expect(detector.append(Array(repeating: 0.08, count: 320 * 12)) == [.speechStarted])
        let events = detector.append(Array(repeating: 0, count: 320 * 33))
        #expect(events.count == 1)
        guard case .utterance(let samples) = events.first else { Issue.record("Missing utterance"); return }
        #expect(samples.count == 320 * 45)
        #expect(!detector.isSpeaking)
        #expect(detector.bufferedSampleCount == 0)
    }

    @Test("Arbitrary frame splits give identical decisions and max 15-second windows")
    func frameBounds() {
        let samples = Array(repeating: Float(0.1), count: 16_000 * 31)
        var whole = LiveVoiceUtteranceDetector()
        let expected = whole.append(samples)
        var split = LiveVoiceUtteranceDetector()
        var actual: [LiveVoiceUtteranceDetector.Event] = []
        for start in stride(from: 0, to: samples.count, by: 137) {
            actual += split.append(Array(samples[start..<min(start + 137, samples.count)]))
        }
        #expect(actual == expected)
        let windows = actual.compactMap { event -> [Float]? in
            if case .utterance(let window) = event { return window }; return nil
        }
        #expect(windows.isEmpty, "Continuous speech is not a completed command")
        #expect(actual.filter { $0 == .limitReached }.count == 2)
        #expect(split.bufferedSampleCount <= 16_000 * 15 + 320)
    }

    @Test("Successful turn completion retires its epoch even without a stop or interrupt")
    func completedEpoch() {
        var state = LiveVoiceTurnState()
        let first = state.start()
        let turn = LiveVoiceChatTurn(conversationID: UUID(), turnID: UUID())
        let owned = state.own(turn, at: first)
        #expect(owned)
        state.releaseTurn()
        #expect(state.isActive)
        #expect(!state.accepts(first))
        let nextEpoch = state.epoch
        let next = LiveVoiceChatTurn(conversationID: turn.conversationID, turnID: UUID())
        let nextOwned = state.own(next, at: nextEpoch)
        #expect(nextOwned)
        #expect(!state.accepts(first, currentTurn: next))
        #expect(state.accepts(nextEpoch, currentTurn: next))
    }

    @Test("WAV encoding is mono 16 kHz PCM16 with finite clamping")
    func wav() {
        let data = LiveVoiceUtteranceDetector.wavData([0, 1, -1, .infinity, .nan, 99])
        #expect(data.count == 56)
        #expect(String(decoding: data[0..<4], as: UTF8.self) == "RIFF")
        #expect(Array(data[24..<28]) == [0x80, 0x3e, 0, 0])
        #expect(Array(data[44..<56]) == [0, 0, 0xff, 0x7f, 1, 0x80, 0, 0, 0, 0, 0xff, 0x7f])
    }

    @Test("Playback pacing follows emitted PCM duration, not generation speed or wall-clock completion")
    func playbackPacing() {
        var normal = LiveVoicePlaybackPacing()
        normal.scheduled(byteCount: 48_000, sampleRate: 24_000, now: 100)
        #expect(normal.scheduledUntil == 101)
        var faster = LiveVoicePlaybackPacing()
        faster.scheduled(byteCount: 24_000, sampleRate: 24_000, now: 100)
        #expect(faster.scheduledUntil == 100.5)
        normal.scheduled(byteCount: 48_000, sampleRate: 24_000, now: 100)
        #expect(normal.shouldWait(now: 100))
        #expect(!normal.shouldWait(now: 100.5))
        #expect(!normal.shouldWait(now: 500))
        // Expiry is only an estimate for backpressure; it does not mutate the
        // native drain state. A late chunk starts from NOW rather than the past.
        #expect(normal.scheduledUntil == 102)
        normal.scheduled(byteCount: 24_000, sampleRate: 24_000, now: 500)
        #expect(normal.scheduledUntil == 500.5)
        normal.drained()
        #expect(normal.scheduledUntil == 0)
        normal.scheduled(byteCount: 0, sampleRate: 24_000, now: 600)
        normal.scheduled(byteCount: 100, sampleRate: .nan, now: 600)
        #expect(normal.scheduledUntil == 0)
    }

    @Test("Only the current owned streaming turn can be cancelled")
    func epochs() {
        let own = LiveVoiceChatTurn(conversationID: UUID(), turnID: UUID())
        let typed = LiveVoiceChatTurn(conversationID: own.conversationID, turnID: UUID())
        var state = LiveVoiceTurnState()
        let first = state.start()
        let initiallyOwned = state.own(own, at: first)
        #expect(initiallyOwned)
        #expect(!state.accepts(first, currentTurn: typed))
        #expect(state.invalidate(currentTurn: typed, isStreaming: true) == nil)
        #expect(!state.accepts(first))
        let staleOwned = state.own(own, at: first)
        #expect(!staleOwned)
        let next = state.epoch
        let nextOwned = state.own(own, at: next)
        #expect(nextOwned)
        #expect(state.invalidate(currentTurn: own, isStreaming: false) == nil)
        let currentEpoch = state.epoch
        let currentOwned = state.own(own, at: currentEpoch)
        #expect(currentOwned)
        #expect(state.invalidate(currentTurn: own, isStreaming: true, stopping: true) == own)
        #expect(!state.isActive)
        #expect(!state.accepts(state.epoch))
    }
}

@MainActor
private final class VoiceTestAudio: LiveVoiceAudioIO {
    var onInputFrame: (([Float]) -> Void)?
    var onPlaybackDrained: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var isVoiceProcessingEnabled = false
    var starts: [Bool] = []
    var stops = 0
    var interruptions = 0
    var chunks: [Data] = []
    var failAEC = false
    var autoDrain = true
    func start(voiceProcessing: Bool) async throws {
        starts.append(voiceProcessing)
        if voiceProcessing && failAEC { throw VoiceTestFailure.injected }
        isVoiceProcessingEnabled = voiceProcessing
    }
    func enqueuePCM(_ data: Data, sampleRate: Double) throws {
        chunks.append(data)
        if autoDrain { onPlaybackDrained?() }
    }
    func interruptPlayback() { interruptions += 1 }
    func stop() { stops += 1 }
    func voice(windows: Int = 12) { onInputFrame?(Array(repeating: 0.08, count: windows * 320)) }
    func silence(windows: Int = 33) { onInputFrame?(Array(repeating: 0, count: windows * 320)) }
    func utterance() { voice(); silence() }
}

private enum VoiceTestFailure: Error { case injected, timeout }

private actor VoiceTestTransport: LiveVoiceTransport {
    var transcript = "A spoken request"
    var recognitionRequests: [Data] = []
    var speechTexts: [String] = []
    var speechVoices: [String?] = []
    var voiceOptions = ["Vivian", "Ryan"]
    var voiceRequests = 0
    var failRecognition = false
    var failSpeech = false
    var holdRecognition = false
    var holdSpeech = false
    var cancelledSpeech = 0
    var recognitionContinuation: CheckedContinuation<Void, Never>?
    var lateChunk: (@MainActor (Data, Double) async throws -> Void)?
    func configure(transcript: String? = nil, holdRecognition: Bool = false,
                   holdSpeech: Bool = false, failRecognition: Bool = false, failSpeech: Bool = false) {
        if let transcript { self.transcript = transcript }
        self.holdRecognition = holdRecognition; self.holdSpeech = holdSpeech
        self.failRecognition = failRecognition; self.failSpeech = failSpeech
    }
    func transcribe(audioData: Data, model: String, context: String?, port: Int, bearer: String?) async throws -> AudioTranscriptionResult {
        recognitionRequests.append(audioData)
        if holdRecognition { await withCheckedContinuation { recognitionContinuation = $0 } }
        if failRecognition { throw VoiceTestFailure.injected }
        // Deliberately ignores cancellation; controller epochs must reject it.
        return AudioTranscriptionResult(text: transcript, language: nil, duration: 0.9)
    }
    func resumeRecognition() { recognitionContinuation?.resume(); recognitionContinuation = nil }
    func voices(model: String, port: Int, bearer: String?) async throws -> [String] { voiceRequests += 1; return voiceOptions }
    func streamSpeech(text: String, model: String, voice: String?, port: Int, bearer: String?,
                      onChunk: @escaping @MainActor (Data, Double) async throws -> Void) async throws {
        speechTexts.append(text); speechVoices.append(voice); lateChunk = onChunk
        if failSpeech { throw VoiceTestFailure.injected }
        try await onChunk(Data([1, 0, 2, 0]), 24_000)
        if holdSpeech {
            do { try await Task.sleep(for: .seconds(60)) }
            catch { cancelledSpeech += 1; throw error }
        }
    }
    func attemptLateChunk() async -> Bool {
        do { try await lateChunk?(Data([99, 0]), 24_000); return true }
        catch { return false }
    }
}

@MainActor
private final class VoiceTestReadiness: LiveVoiceModelReadiness {
    var available = true
    var models = LiveVoiceModels(chatAlias: "fake-alias",
        recognition: .init(model: "loaded-asr", port: 52_000, bearer: nil),
        speech: .init(model: "qwen3-tts", port: 52_000, bearer: nil))
    func refresh() async -> LiveVoiceModels? { available ? models : nil }
    func isStillReady(_ models: LiveVoiceModels) -> Bool { available && models == self.models }
}

@MainActor
private final class VoiceTestChat: LiveVoiceChatSession {
    var currentTurn = LiveVoiceChatTurn(conversationID: UUID(), turnID: UUID())
    var isStreaming = false
    var hasError = false
    var assistantText: [LiveVoiceAssistantText] = []
    var sent: [String] = []
    var stopped: [LiveVoiceChatTurn] = []
    func send(_ text: String, alias: String) -> LiveVoiceChatTurn? {
        guard !isStreaming else { return nil }
        sent.append(text)
        currentTurn = LiveVoiceChatTurn(conversationID: currentTurn.conversationID, turnID: UUID())
        isStreaming = true
        assistantText.append(.init(id: UUID(), text: "", isComplete: false, isSpeakable: true))
        return currentTurn
    }
    func delta(_ text: String, finish: Bool = false) {
        let last = assistantText.removeLast()
        assistantText.append(.init(id: last.id, text: last.text + text, isComplete: finish, isSpeakable: true))
        if finish { isStreaming = false }
    }
    func stopOwnedTurn(_ turn: LiveVoiceChatTurn) {
        if turn == currentTurn && isStreaming { stopped.append(turn); isStreaming = false }
    }
    func typedTurn() {
        currentTurn = .init(conversationID: currentTurn.conversationID, turnID: UUID())
        isStreaming = true
    }
}

@MainActor
private func voiceEventually(_ condition: @MainActor () async -> Bool) async throws {
    for _ in 0..<1000 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw VoiceTestFailure.timeout
}

@MainActor
private struct VoiceTestRig {
    let audio = VoiceTestAudio()
    let transport = VoiceTestTransport()
    let chat = VoiceTestChat()
    let readiness = VoiceTestReadiness()
    let controller: YouziLiveVoiceController
    init() {
        controller = YouziLiveVoiceController(audio: audio, transport: transport, chat: chat, readiness: readiness)
    }
    func sendUtterance() async throws {
        await controller.start()
        audio.utterance()
        try await voiceEventually { chat.sent.count == 1 }
    }
}

@MainActor @Suite("Live voice injectable orchestration (no microphone)")
struct LiveVoiceOrchestrationTests {
    @Test("Capture → utterance ASR → chat deltas → early sentence PCM → drain")
    func chain() async throws {
        let rig = VoiceTestRig()
        defer { rig.controller.stop() }
        #expect(rig.audio.starts.isEmpty)
        await rig.controller.start()
        rig.audio.silence(windows: 100)
        #expect(await rig.transport.recognitionRequests.isEmpty)
        rig.audio.utterance()
        try await voiceEventually { rig.chat.sent == ["A spoken request"] }
        rig.chat.delta("First sentence. Next")
        rig.controller.pollChat()
        try await voiceEventually { !rig.audio.chunks.isEmpty }
        #expect(rig.chat.isStreaming, "PCM must arrive before the chat turn finishes")
        #expect(rig.controller.firstTextSeconds != nil)
        #expect(rig.controller.firstPCMSeconds != nil)
        #expect(rig.controller.firstPCMWhileChatStreaming)
        #expect(await rig.transport.speechTexts == ["First sentence."])
        rig.chat.delta(" sentence.", finish: true)
        try await voiceEventually { rig.controller.phase == .listening }
        #expect(await rig.transport.speechTexts == ["First sentence.", "Next sentence."])
        #expect(rig.audio.chunks.count == 2)
        #expect(rig.controller.isMicrophoneOn)
    }

    @Test("Waiting for LLM text and a sentence is not reported as already speaking")
    func replyStages() async throws {
        let rig = VoiceTestRig()
        rig.audio.autoDrain = false
        defer { rig.controller.stop() }
        try await rig.sendUtterance()
        #expect(rig.controller.replyStage == .waitingForText)
        #expect(rig.controller.firstTextSeconds == nil)
        #expect(rig.controller.firstPCMSeconds == nil)
        rig.chat.delta("An unfinished sentence")
        rig.controller.pollChat()
        #expect(rig.controller.replyStage == .waitingForSentence)
        #expect(rig.controller.firstTextSeconds != nil)
        #expect(rig.controller.firstPCMSeconds == nil)
        #expect(await rig.transport.speechTexts.isEmpty)
        rig.chat.delta(". Next")
        rig.controller.pollChat()
        try await voiceEventually { !rig.audio.chunks.isEmpty }
        #expect(rig.controller.replyStage == .speaking)
        #expect(rig.controller.firstPCMWhileChatStreaming)
    }

    @Test("Short-line explanations are accepted; runaway speech queues still hand off safely", arguments: [35, 100])
    func boundedShortSentenceQueue(count: Int) async throws {
        let rig = VoiceTestRig()
        defer { rig.controller.stop() }
        await rig.transport.configure(holdSpeech: true)
        try await rig.sendUtterance()
        rig.chat.delta(String(repeating: "这是一句解释。", count: count))
        rig.controller.pollChat()
        if count <= 96 {
            #expect(rig.controller.problem == nil)
            try await voiceEventually { !rig.audio.chunks.isEmpty }
            #expect(rig.controller.isMicrophoneOn)
        } else {
            #expect(rig.controller.problem == .replyTooLong)
            #expect(!rig.controller.isMicrophoneOn)
            #expect(rig.chat.isStreaming, "Text generation continues after audio handoff")
            #expect(rig.chat.stopped.isEmpty)
        }
    }

    @Test("AEC barge-in cancels owned chat/TTS; delayed old PCM is rejected")
    func bargeIn() async throws {
        let rig = VoiceTestRig()
        defer { rig.controller.stop() }
        await rig.transport.configure(holdSpeech: true)
        try await rig.sendUtterance()
        rig.chat.delta("An old reply. "); rig.controller.pollChat()
        try await voiceEventually { rig.audio.chunks.count == 1 }
        let epochTurn = rig.chat.currentTurn
        rig.audio.voice()
        #expect(rig.chat.stopped == [epochTurn])
        #expect(rig.controller.phase == .listening)
        #expect(rig.controller.isMicrophoneOn)
        try await voiceEventually { await rig.transport.cancelledSpeech == 1 }
        #expect(await !rig.transport.attemptLateChunk())
        #expect(rig.audio.chunks.count == 1)
        rig.audio.silence()
        try await voiceEventually { rig.chat.sent.count == 2 }
    }

    @Test("Cancelled ASR cannot send after mic-off, navigation, or restart", arguments: [false, true])
    func staleRecognition(navigation: Bool) async throws {
        let rig = VoiceTestRig()
        defer { rig.controller.stop() }
        await rig.transport.configure(holdRecognition: true)
        await rig.controller.start(); rig.audio.utterance()
        try await voiceEventually { await rig.transport.recognitionContinuation != nil }
        if navigation {
            rig.chat.currentTurn = .init(conversationID: UUID(), turnID: UUID())
            rig.controller.pollChat()
        } else { rig.controller.stop() }
        await rig.transport.resumeRecognition()
        await rig.controller.start()
        for _ in 0..<20 { await Task.yield() }
        #expect(rig.chat.sent.isEmpty)
        #expect(rig.audio.chunks.isEmpty)
    }

    @Test("A newly typed turn is never cancelled or spoken by the old voice session")
    func unrelatedTurn() async throws {
        let rig = VoiceTestRig()
        try await rig.sendUtterance()
        rig.chat.typedTurn()
        rig.controller.pollChat()
        #expect(rig.chat.stopped.isEmpty)
        #expect(rig.chat.isStreaming)
        #expect(!rig.controller.isMicrophoneOn)
    }

    @Test("Half duplex ignores reply capture and requires explicit interruption")
    func halfDuplex() async throws {
        let rig = VoiceTestRig()
        defer { rig.controller.stop() }
        await rig.controller.start(halfDuplex: true)
        rig.audio.utterance()
        try await voiceEventually { rig.chat.sent.count == 1 }
        rig.audio.utterance()
        #expect(await rig.transport.recognitionRequests.count == 1)
        #expect(rig.chat.stopped.isEmpty)
        rig.controller.interrupt()
        rig.audio.utterance()
        try await voiceEventually { rig.chat.sent.count == 2 }
        #expect(rig.audio.starts == [false])
    }

    @Test("Missing resident models never start capture")
    func missingModels() async {
        let rig = VoiceTestRig()
        rig.readiness.available = false
        await rig.controller.start()
        #expect(rig.controller.problem == .modelsMissing)
        #expect(rig.audio.starts.isEmpty)
        #expect(!rig.controller.isActive)
    }

    @Test("Unsupported resident TTS is rejected before voice lookup or microphone start",
          arguments: ["kokoro", "mlx-community/Kokoro-82M-bf16", "Qwen3-TTS-12Hz-1.7B-Base", "Qwen3-TTS-12Hz-1.7B-VoiceDesign", "other-tts"])
    func unsupportedSpeech(model: String) async {
        let rig = VoiceTestRig()
        rig.readiness.models = LiveVoiceModels(chatAlias: "fake-alias",
            recognition: rig.readiness.models.recognition,
            speech: .init(model: model, port: 52_000, bearer: nil))
        await rig.controller.start()
        #expect(rig.controller.problem == .unsupportedSpeechModel)
        #expect(!rig.controller.isMicrophoneOn)
        #expect(!rig.controller.isActive)
        #expect(rig.audio.starts.isEmpty)
        #expect(await rig.transport.voiceRequests == 0)
        #expect(await rig.transport.recognitionRequests.isEmpty)
    }

    @Test("Named-speaker Qwen aliases and CustomVoice repositories are supported",
          arguments: ["qwen3-tts", "qwen3-tts-4bit", "qwen3-tts-6bit", "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-4bit"])
    func supportedSpeech(model: String) {
        #expect(LiveVoiceModels.supportsStreamingSpeech(model))
    }

    @Test("15-second continuous speech shuts mic off and never submits a partial command")
    func utteranceOverflow() async throws {
        let rig = VoiceTestRig()
        defer { rig.controller.stop() }
        await rig.controller.start()
        let staleInput = rig.audio.onInputFrame
        rig.audio.voice(windows: 749)
        #expect(rig.controller.canFinishUtterance)
        #expect(await rig.transport.recognitionRequests.isEmpty)
        rig.audio.voice(windows: 1)
        #expect(rig.controller.problem == .utteranceTooLong)
        #expect(rig.controller.phase == .stopped)
        #expect(!rig.controller.isMicrophoneOn)
        #expect(!rig.controller.canFinishUtterance)
        #expect(rig.audio.onInputFrame == nil)
        // Reproduce the original edge: continued voice followed by a real tail
        // must neither restart ASR nor silently send the first 15-second prefix.
        staleInput?(Array(repeating: 0.08, count: 320 * 20))
        staleInput?(Array(repeating: 0, count: 320 * 40))
        rig.controller.finishUtterance()
        try await Task.sleep(for: .milliseconds(60))
        #expect(await rig.transport.recognitionRequests.isEmpty)
        #expect(rig.chat.sent.isEmpty)
        #expect(rig.audio.chunks.isEmpty)
        await rig.controller.start()
        rig.audio.voice()
        rig.controller.finishUtterance()
        try await voiceEventually { rig.chat.sent.count == 1 }
        #expect(await rig.transport.recognitionRequests.count == 1)
    }

    @Test("Completed speech is invalidated when a continuing chat turn revises its message",
          arguments: ["rewrite", "truncate", "append", "reopen", "unspeakable", "remove"])
    func completedMessageRevision(change: String) async throws {
        let rig = VoiceTestRig()
        defer { rig.controller.stop() }
        await rig.transport.configure(holdSpeech: true)
        try await rig.sendUtterance()
        let id = try #require(rig.chat.assistantText.last?.id)
        let old = "Old ungrounded answer. "
        // A finish_reason completes the message before a tool correction ends
        // the whole turn. Keep chat streaming, as the production retry does.
        rig.chat.assistantText = [.init(id: id, text: old, isComplete: true, isSpeakable: true)]
        rig.controller.pollChat()
        try await voiceEventually { rig.audio.chunks.count == 1 }
        switch change {
        case "rewrite":
            rig.chat.assistantText = [.init(id: id, text: "Corrected answer. ", isComplete: false, isSpeakable: true)]
        case "truncate":
            rig.chat.assistantText = [.init(id: id, text: "", isComplete: false, isSpeakable: true)]
        case "append":
            rig.chat.assistantText = [.init(id: id, text: old + "A correction.", isComplete: true, isSpeakable: true)]
        case "reopen":
            rig.chat.assistantText = [.init(id: id, text: old, isComplete: false, isSpeakable: true)]
        case "unspeakable":
            rig.chat.assistantText = [.init(id: id, text: old, isComplete: true, isSpeakable: false)]
        default:
            rig.chat.assistantText = []
        }
        rig.controller.pollChat()
        #expect(rig.controller.problem == .replyChanged)
        #expect(!rig.controller.isMicrophoneOn)
        #expect(rig.chat.isStreaming, "Grounding correction must continue in text chat")
        #expect(rig.chat.stopped.isEmpty)
        #expect(await !rig.transport.attemptLateChunk())
    }

    @Test("Unchanged completed messages do not replay; revoked partial speech stops safely")
    func completedProjectionIdempotentAndPartialRevocation() async throws {
        let rig = VoiceTestRig()
        defer { rig.controller.stop() }
        await rig.transport.configure(holdSpeech: true)
        try await rig.sendUtterance()
        let id = try #require(rig.chat.assistantText.last?.id)
        let text = "Stable answer. "
        rig.chat.assistantText = [.init(id: id, text: text, isComplete: true, isSpeakable: true)]
        rig.controller.pollChat()
        try await voiceEventually { rig.audio.chunks.count == 1 }
        for _ in 0..<5 { rig.controller.pollChat() }
        #expect(rig.controller.problem == nil)
        #expect(rig.controller.isMicrophoneOn)
        #expect(await rig.transport.speechTexts == ["Stable answer."])
        rig.controller.stop()

        let partial = VoiceTestRig()
        defer { partial.controller.stop() }
        await partial.transport.configure(holdSpeech: true)
        try await partial.sendUtterance()
        partial.chat.delta("Partial answer. ")
        partial.controller.pollChat()
        try await voiceEventually { partial.audio.chunks.count == 1 }
        let pending = try #require(partial.chat.assistantText.last)
        partial.chat.assistantText = [.init(id: pending.id, text: pending.text, isComplete: false, isSpeakable: false)]
        partial.controller.pollChat()
        #expect(partial.controller.problem == .replyChanged)
        #expect(!partial.controller.isMicrophoneOn)
        #expect(partial.chat.isStreaming)
        #expect(partial.chat.stopped.isEmpty)
        #expect(await !partial.transport.attemptLateChunk())
    }

    @Test("Estimated PCM duration cannot advance sentences or finish before actual drain")
    func delayedDrain() async throws {
        let rig = VoiceTestRig()
        defer { rig.controller.stop() }
        rig.audio.autoDrain = false
        try await rig.sendUtterance()
        rig.chat.delta("First sentence. Second sentence.", finish: true)
        rig.controller.pollChat()
        try await voiceEventually { rig.audio.chunks.count == 1 }
        // Four bytes represent <0.1 ms. Waiting 100 ms intentionally exceeds
        // that estimate, while the synthetic device withholds played-back.
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.controller.phase == .responding)
        #expect(await rig.transport.speechTexts == ["First sentence."])
        rig.audio.onPlaybackDrained?()
        try await voiceEventually { rig.audio.chunks.count == 2 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.controller.phase == .responding)
        rig.audio.onPlaybackDrained?()
        try await voiceEventually { rig.controller.phase == .listening }
        #expect(await rig.transport.speechTexts == ["First sentence.", "Second sentence."])
    }

    @Test("Stop while draining clears playback; old drain cannot finish a new epoch")
    func staleDrainAfterStop() async throws {
        let rig = VoiceTestRig()
        defer { rig.controller.stop() }
        rig.audio.autoDrain = false
        try await rig.sendUtterance()
        rig.chat.delta("Old sentence. Never synthesize this.", finish: true)
        rig.controller.pollChat()
        try await voiceEventually { rig.audio.chunks.count == 1 }
        let oldDrain = rig.audio.onPlaybackDrained
        rig.controller.stop()
        #expect(rig.audio.onPlaybackDrained == nil)
        #expect(!rig.controller.isMicrophoneOn)
        oldDrain?()
        #expect(rig.controller.phase == .stopped)
        await rig.controller.start()
        rig.audio.utterance()
        try await voiceEventually { rig.chat.sent.count == 2 }
        rig.chat.delta("New sentence.", finish: true)
        rig.controller.pollChat()
        try await voiceEventually { rig.audio.chunks.count == 2 }
        oldDrain?()
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.controller.phase == .responding)
        #expect(await rig.transport.speechTexts == ["Old sentence.", "New sentence."])
        rig.audio.onPlaybackDrained?()
        try await voiceEventually { rig.controller.phase == .listening }
    }

    @Test("Late callbacks from a normally completed turn cannot affect the next spoken turn")
    func completedTurnCallbacks() async throws {
        let rig = VoiceTestRig()
        defer { rig.controller.stop() }
        try await rig.sendUtterance()
        rig.chat.delta("First turn.", finish: true)
        rig.controller.pollChat()
        try await voiceEventually { rig.controller.phase == .listening }
        let oldChunk = await rig.transport.lateChunk
        let oldDrain = rig.audio.onPlaybackDrained
        rig.audio.autoDrain = false
        rig.audio.utterance()
        try await voiceEventually { rig.chat.sent.count == 2 }
        rig.chat.delta("Second turn.", finish: true)
        rig.controller.pollChat()
        try await voiceEventually { rig.audio.chunks.count == 2 }
        do {
            try await oldChunk?(Data([99, 0]), 24_000)
            Issue.record("A completed turn's PCM callback was accepted by its successor")
        } catch { /* Expected stale-epoch cancellation. */ }
        oldDrain?()
        try await Task.sleep(for: .milliseconds(80))
        #expect(rig.audio.chunks.count == 2)
        #expect(rig.controller.phase == .responding)
        rig.audio.onPlaybackDrained?()
        try await voiceEventually { rig.controller.phase == .listening }
    }

    @Test("Saved voice default is used without loading a model")
    func selectedVoice() async throws {
        let suite = "live-voice-defaults-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["qwen3-tts": "Ryan"], forKey: ModelGenerationDefaults.Key.voices)
        let audio = VoiceTestAudio(), chat = VoiceTestChat()
        let transport = VoiceTestTransport()
        let controller = YouziLiveVoiceController(audio: audio, transport: transport, chat: chat,
            readiness: VoiceTestReadiness(), defaults: ModelGenerationDefaults(defaults: defaults))
        defer { controller.stop() }
        await controller.start(); audio.utterance()
        try await voiceEventually { chat.sent.count == 1 }
        chat.delta("Hello.", finish: true)
        try await voiceEventually { controller.phase == .listening }
        #expect(await transport.speechVoices == ["Ryan"])
    }

    @Test("AEC failure never silently falls back; explicit half duplex can restart")
    func explicitFallback() async {
        let rig = VoiceTestRig()
        defer { rig.controller.stop() }
        rig.audio.failAEC = true
        await rig.controller.start()
        #expect(rig.audio.starts == [true])
        #expect(rig.controller.problem == .voiceProcessing)
        #expect(!rig.controller.isMicrophoneOn)
        await rig.controller.start(halfDuplex: true)
        #expect(rig.audio.starts == [true, false])
        #expect(rig.controller.isHalfDuplex)
        #expect(rig.controller.isMicrophoneOn)
    }

    @Test("Recognition failure closes the microphone without a chat turn")
    func recognitionFailure() async throws {
        let rig = VoiceTestRig()
        await rig.transport.configure(failRecognition: true)
        await rig.controller.start(); rig.audio.utterance()
        try await voiceEventually { rig.controller.problem == .recognition }
        #expect(!rig.controller.isMicrophoneOn)
        #expect(rig.chat.sent.isEmpty)
    }

    @Test("Speech failure hands off text chat, never cancels its remaining tools")
    func speechFailure() async throws {
        let rig = VoiceTestRig()
        await rig.transport.configure(failSpeech: true)
        try await rig.sendUtterance()
        rig.chat.delta("Hello. "); rig.controller.pollChat()
        try await voiceEventually { rig.controller.problem == .speech }
        #expect(!rig.controller.isMicrophoneOn)
        #expect(rig.chat.isStreaming)
        #expect(rig.chat.stopped.isEmpty)
    }

    @Test("Device failure closes capture, cancels owned turn and clears callbacks")
    func deviceFailure() async throws {
        let rig = VoiceTestRig()
        try await rig.sendUtterance()
        rig.audio.onFailure?("synthetic device change")
        #expect(rig.controller.problem == .deviceChanged)
        #expect(!rig.controller.isMicrophoneOn)
        #expect(rig.chat.stopped.count == 1)
        #expect(rig.audio.onInputFrame == nil)
    }

    @Test("Approval handoff relinquishes ownership while original chat continues")
    func approvalHandoff() async throws {
        let rig = VoiceTestRig()
        try await rig.sendUtterance()
        rig.controller.handoffToChat()
        rig.controller.stop() // sheet dismissal after handoff must be harmless
        #expect(rig.chat.isStreaming)
        #expect(rig.chat.stopped.isEmpty)
        #expect(!rig.controller.isMicrophoneOn)
    }

    @Test("Readiness loss and chat errors stop stale speech")
    func runtimeAndChatFailures() async throws {
        let rig = VoiceTestRig()
        try await rig.sendUtterance()
        rig.readiness.available = false
        rig.controller.pollChat()
        #expect(rig.controller.problem == .modelsMissing)
        #expect(rig.chat.stopped.count == 1)
        let other = VoiceTestRig()
        try await other.sendUtterance()
        other.chat.hasError = true
        other.controller.pollChat()
        #expect(other.controller.problem == .chatFailed)
        #expect(!other.controller.isMicrophoneOn)
    }
}

#if !LIVEVOICE_ISOLATED
@MainActor @Suite("Live voice real ChatViewModel route (synthetic HTTP, no mic)", .serialized)
struct LiveVoiceNativeChatRouteTests {
    @Test("Real send, SSE deltas, tool budget, speech projection and persisted conversation")
    func realChatToolsPersistence() async throws {
        let fake = GoldenChatFake()
        fake.interChunkDelay = 0.001
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("live-voice-chat-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("conversations.json")
        let suite = "live-voice-chat-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let server = ServerManager(testingState: .ready(alias: "fake-alias"), activePort: fake.port, sessionDefaults: defaults)
        var executions = 0
        let registry = BuiltinToolRegistry(webSearchRunner: { _, _, _ in
            executions += 1
            return ToolCallResult(toolCallID: "", content: #"{"results":[{"title":"Synthetic evidence","snippet":"Do not speak tool JSON."}]}"#)
        })
        let chat = ChatViewModel(client: ChatStreamClient(baseURL: fake.baseURL, session: fake.session()),
            tools: registry, toolDefaults: defaults, server: server,
            persistsConversations: true, conversationStoreURL: storeURL)
        let audio = VoiceTestAudio()
        let transport = VoiceTestTransport()
        await transport.configure(transcript: "shape:tool-loop investigate this topic")
        let controller = YouziLiveVoiceController(audio: audio, transport: transport,
            chat: LiveVoiceChatAdapter(chat: chat), readiness: VoiceTestReadiness())
        defer { controller.stop(); chat.stop() }
        await controller.start(); audio.utterance()
        try await voiceEventually { chat.messages.contains { $0.role == .user } }
        await chat._testingWaitForCurrentTurn()
        try await voiceEventually { controller.phase == .listening }
        #expect(executions == 3)
        #expect(chat.messages.filter { $0.role == .user }.count == 1)
        #expect(chat.messages.filter { $0.role == .tool }.count == 3)
        #expect(fake.events().contains(.toolLoopSynthesis(toolResults: 3)))
        let spoken = await transport.speechTexts.joined(separator: " ")
        #expect(spoken.contains(GoldenChatFake.toolLoopSynthesisText))
        #expect(!spoken.contains("Do not speak tool JSON"))
        #expect(!spoken.contains("Let me think"))
        #expect(!audio.chunks.isEmpty)
        ConversationStore.flush()
        let restored = ChatViewModel(toolDefaults: defaults, persistsConversations: true, conversationStoreURL: storeURL)
        #expect(restored.conversations.contains { $0.id == chat.activeConversationID })
        let saved = ConversationStore.load(from: storeURL).first { $0.id == chat.activeConversationID }
        #expect(saved?.messages.contains { $0.role == .user && $0.content.contains("shape:tool-loop") } == true)
        #expect(saved?.messages.filter { $0.role == .tool }.count == 3)
    }

    @Test("Real tool approval survives voice handoff and persists only the explicit answer", arguments: [true, false])
    func realApprovalContinuation(allow: Bool) async throws {
        let fake = GoldenChatFake()
        fake.interChunkDelay = 0.001
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("live-voice-approval-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("conversations.json")
        let suite = "live-voice-approval-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let server = ServerManager(testingState: .ready(alias: "fake-alias"), activePort: fake.port, sessionDefaults: defaults)
        let approval = BrowseApprovalStore(defaults: defaults)
        var executions = 0
        var decisions: [BrowseApprovalStore.Decision] = []
        let registry = BuiltinToolRegistry(browseApproval: approval, webSearchRunner: { _, _, _ in
            executions += 1
            if executions == 1 {
                // The real chat tool runner suspends on the original approval
                // continuation. Only external search I/O is synthetic here.
                let decision = await approval.requestApproval(url: "https://example.com/voice-test", host: "example.com")
                decisions.append(decision)
                return ToolCallResult(toolCallID: "", content: decision == .allowOnce ? "explicitly-approved-evidence" : "explicitly-denied-evidence",
                    isError: decision != .allowOnce)
            }
            return ToolCallResult(toolCallID: "", content: "synthetic-followup-evidence")
        })
        let chat = ChatViewModel(client: ChatStreamClient(baseURL: fake.baseURL, session: fake.session()),
            tools: registry, toolDefaults: defaults, server: server,
            persistsConversations: true, conversationStoreURL: storeURL)
        let audio = VoiceTestAudio(), transport = VoiceTestTransport()
        await transport.configure(transcript: "shape:tool-loop approval request")
        let controller = YouziLiveVoiceController(audio: audio, transport: transport,
            chat: LiveVoiceChatAdapter(chat: chat), readiness: VoiceTestReadiness())
        defer { controller.stop(); approval.answer(.deny); chat.stop() }
        await controller.start(); audio.utterance()
        try await voiceEventually { approval.pendingRequest != nil }
        let pending = approval.pendingRequest
        let ownedTurn = chat.liveVoiceCurrentTurn
        #expect(chat.isStreaming)
        #expect(executions == 1)
        #expect(decisions.isEmpty)
        controller.handoffToChat()
        controller.stop() // SwiftUI onDisappear after handoff must be harmless.
        try await Task.sleep(for: .milliseconds(80))
        #expect(approval.pendingRequest == pending)
        #expect(decisions.isEmpty, "Voice must never answer or cancel a human approval")
        #expect(chat.isStreaming)
        #expect(chat.liveVoiceCurrentTurn == ownedTurn)
        #expect(!controller.isMicrophoneOn)
        #expect(audio.onInputFrame == nil)
        approval.answer(allow ? .allowOnce : .deny)
        await chat._testingWaitForCurrentTurn()
        #expect(decisions == [allow ? .allowOnce : .deny])
        #expect(approval.pendingRequest == nil)
        #expect(fake.events().contains(.toolLoopSynthesis(toolResults: 3)))
        #expect(await transport.speechTexts.isEmpty, "Handoff never resumes speech automatically")
        ConversationStore.flush()
        let saved = try #require(ConversationStore.load(from: storeURL).first { $0.id == chat.activeConversationID })
        let result = allow ? "explicitly-approved-evidence" : "explicitly-denied-evidence"
        #expect(saved.messages.contains { $0.role == .tool && $0.content == result })
        #expect(saved.messages.contains { $0.role == .assistant && $0.content.contains(GoldenChatFake.toolLoopSynthesisText) })
    }

    @Test("Resident-only send refuses unavailable models; old token cannot stop typed regeneration")
    func nativeOwnership() async throws {
        let suite = "live-voice-native-ownership-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let unavailable = ChatViewModel(toolDefaults: defaults,
            sampling: SamplingConfig(defaults: defaults), customInstructions: CustomInstructionsConfig(defaults: defaults),
            server: ServerManager(testingState: .stopped, sessionDefaults: defaults), persistsConversations: false)
        #expect(unavailable.sendLiveVoice("hello", alias: "unloaded") == nil)
        #expect(unavailable.messages.isEmpty)
        let fake = GoldenChatFake()
        fake.interChunkDelay = 0.02; fake.contentRepeat = 20000
        let server = ServerManager(testingState: .ready(alias: "fake-alias"), activePort: fake.port, sessionDefaults: defaults)
        let chat = ChatViewModel(client: ChatStreamClient(baseURL: fake.baseURL, session: fake.session()),
            toolDefaults: defaults, sampling: SamplingConfig(defaults: defaults),
            customInstructions: CustomInstructionsConfig(defaults: defaults),
            server: server, persistsConversations: false)
        defer { chat.stop() }
        let token = try #require(chat.sendLiveVoice("voice turn", alias: "fake-alias"))
        chat.stopLiveVoiceTurn(token)
        await chat._testingWaitForCurrentTurn()
        chat.send("typed turn", alias: "fake-alias")
        let typed = chat.liveVoiceCurrentTurn
        #expect(typed != token)
        chat.stopLiveVoiceTurn(token)
        #expect(chat.isStreaming)
        #expect(chat.liveVoiceCurrentTurn == typed)
        chat.stop()
        await chat._testingWaitForCurrentTurn()
    }
}
#endif
