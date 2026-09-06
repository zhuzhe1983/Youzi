import AVFoundation
import Observation

@MainActor
protocol SettingsVoicePlaying: AnyObject {
    var isPlaying: Bool { get }
    func play(_ data: Data) throws
    func stop()
}

@MainActor
private final class SettingsVoicePlayer: SettingsVoicePlaying {
    private var player: AVAudioPlayer?
    var isPlaying: Bool { player?.isPlaying == true }
    func play(_ data: Data) throws {
        let next = try AVAudioPlayer(data: data)
        guard next.prepareToPlay(), next.play() else { throw AudioClientError.emptyAudio }
        player = next
    }
    func stop() { player?.stop(); player = nil }
}

/// One cancellable request/player per settings page. A late response can never
/// play over a newer voice, after Stop, or after leaving the page.
@MainActor
@Observable
final class SettingsVoicePreview {
    enum State: Equatable { case idle, generating, playing, failed }
    private(set) var state: State = .idle
    private(set) var errorMessage: String?
    private var task: Task<Void, Never>?
    private var generation = 0
    private let player: any SettingsVoicePlaying

    init(player: (any SettingsVoicePlaying)? = nil) {
        self.player = player ?? SettingsVoicePlayer()
    }

    func start(debounce: Duration = .zero,
               generate: @escaping @MainActor () async throws -> Data) {
        stop()
        let current = generation
        state = .generating
        task = Task { [weak self] in
            do {
                if debounce > .zero { try await Task.sleep(for: debounce) }
                try Task.checkCancellation()
                let data = try await generate()
                try Task.checkCancellation()
                guard let self, self.generation == current else { return }
                try self.player.play(data)
                self.state = .playing
                while self.player.isPlaying {
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard self.generation == current else { return }
                self.state = .idle
                self.task = nil
            } catch {
                guard !Task.isCancelled, let self, self.generation == current else { return }
                self.player.stop()
                if error is CancellationError {
                    self.errorMessage = nil
                    self.state = .idle
                } else {
                    self.errorMessage = error.localizedDescription
                    self.state = .failed
                }
                self.task = nil
            }
        }
    }

    /// Authorization to load was handled by the page. A ready lazy audio lane
    /// is enough: requiring residency here prevents the first TTS request that
    /// would materialize that residency. This boundary is wire-tested.
    static func synthesizeOnReadyLane(
        server: ServerManager, alias: String, text: String, voice: String?, speed: Double,
        client: AudioClient = AudioClient()
    ) async throws -> Data {
        try Task.checkCancellation()
        guard server.isVoiceLaneReady(for: alias) else { throw AudioClientError.invalidResponse }
        let result = try await client.synthesize(
            text: text, model: alias, voice: voice, speed: speed,
            port: server.activePort, bearer: server.activeBearer
        )
        try Task.checkCancellation()
        return result.data
    }

    func stop() {
        generation &+= 1
        task?.cancel()
        task = nil
        player.stop()
        state = .idle
        errorMessage = nil
    }
}
