import AVFoundation
import Foundation

@MainActor
protocol YouziVoicePermissionAuthorizing: AnyObject {
    func authorizeVoiceSession(
        context: YouziVoiceAssistantContext
    ) async -> YouziVoicePrivacyAuthorization
}

/// Production-shaped privacy gate. Composition supplies the exact domain
/// permission and saved local-processing consent; this adapter never consults
/// a network service or broad app-wide grant.
@MainActor
final class YouziLocalVoicePermissionGate: YouziVoicePermissionAuthorizing {
    typealias DecisionProvider = @MainActor (YouziVoiceAssistantContext) async
        -> YouziVoicePrivacyAuthorization

    private let decisionProvider: DecisionProvider

    init(decisionProvider: @escaping DecisionProvider) {
        self.decisionProvider = decisionProvider
    }

    func authorizeVoiceSession(
        context: YouziVoiceAssistantContext
    ) async -> YouziVoicePrivacyAuthorization {
        await decisionProvider(context)
    }
}

@MainActor
protocol YouziVoiceMicrophoneCapturing: AnyObject {
    var onLevel: ((Float) -> Void)? { get set }
    var onFirstSample: (() -> Void)? { get set }

    func requestSystemPermission() async -> Bool
    func startCapture() throws
    func finishCapture() -> Data?
    func cancelCapture()
    func shutdown()
}

/// One capture engine per injected voice controller. The adapter intentionally
/// reuses Dictation's hardened 16 kHz in-memory recorder and never archives a
/// buffer or exposes a file URL.
@MainActor
final class YouziVoiceMicrophoneCapture: YouziVoiceMicrophoneCapturing {
    var onLevel: ((Float) -> Void)?
    var onFirstSample: (() -> Void)?

    private let recorder: DictationRecorder

    init(recorder: DictationRecorder = DictationRecorder()) {
        self.recorder = recorder
        recorder.keepWarmInterval = 0
        recorder.onLevel = { [weak self] level in
            Task { @MainActor [weak self] in self?.onLevel?(level) }
        }
        recorder.onFirstSample = { [weak self] in
            Task { @MainActor [weak self] in self?.onFirstSample?() }
        }
    }

    func requestSystemPermission() async -> Bool {
        await DictationRecorder.requestMicrophoneAccess()
    }

    func startCapture() throws {
        try recorder.startCapture()
    }

    func finishCapture() -> Data? {
        recorder.stopCapture()
    }

    func cancelCapture() {
        recorder.cancelCapture()
    }

    func shutdown() {
        recorder.shutdown()
    }
}

@MainActor
protocol YouziVoiceAudioPlaying: AnyObject {
    var isPlaying: Bool { get }
    var onFinished: (() -> Void)? { get set }

    func play(_ audio: SynthesizedAudio) throws
    func stop()
}

enum YouziVoicePlaybackError: Error {
    case couldNotStart
}

/// Full-buffer local playback. Completion polling mirrors the existing Audio
/// surface and avoids an AVAudioPlayerDelegate crossing Swift concurrency
/// isolation. `stop()` is synchronous so barge-in cuts sound immediately.
@MainActor
final class YouziVoiceAudioPlayer: YouziVoiceAudioPlaying {
    var onFinished: (() -> Void)?
    private(set) var isPlaying = false

    private var player: AVAudioPlayer?
    private var monitor: Task<Void, Never>?

    func play(_ audio: SynthesizedAudio) throws {
        stop()
        let player = try AVAudioPlayer(data: audio.data)
        guard player.prepareToPlay(), player.play() else {
            throw YouziVoicePlaybackError.couldNotStart
        }
        self.player = player
        isPlaying = true
        monitor = Task { [weak self, weak player] in
            while !Task.isCancelled, player?.isPlaying == true {
                try? await Task.sleep(for: .milliseconds(40))
            }
            guard !Task.isCancelled, let self else { return }
            self.player = nil
            self.monitor = nil
            self.isPlaying = false
            self.onFinished?()
        }
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        player?.stop()
        player = nil
        isPlaying = false
    }
}
