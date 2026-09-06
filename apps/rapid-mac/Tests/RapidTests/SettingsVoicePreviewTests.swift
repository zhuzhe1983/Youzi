import Foundation
import Testing
@testable import Rapid

@MainActor
private final class PreviewPlayerStub: SettingsVoicePlaying {
    var isPlaying = false
    var played: [Data] = []
    var fail = false
    func play(_ data: Data) throws {
        if fail { throw AudioClientError.emptyAudio }
        played.append(data)
        isPlaying = true
    }
    func stop() { isPlaying = false }
}

@Suite("Settings voice preview lifecycle")
@MainActor
struct SettingsVoicePreviewTests {
    private func until(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(condition())
    }

    @Test("Replay stops old playback; completion returns to idle")
    func replay() async {
        let player = PreviewPlayerStub()
        let preview = SettingsVoicePreview(player: player)
        preview.start { Data([1]) }
        await until { preview.state == .playing }
        preview.start { Data([2]) }
        #expect(!player.isPlaying)
        await until { player.played.count == 2 }
        #expect(player.played == [Data([1]), Data([2])])
        player.isPlaying = false
        await until { preview.state == .idle }
        preview.stop()
    }

    @Test("Stop and leaving settings discard even an uncancellable late response")
    func lateResponse() async {
        let player = PreviewPlayerStub()
        let preview = SettingsVoicePreview(player: player)
        var continuation: CheckedContinuation<Data, Never>?
        preview.start { await withCheckedContinuation { continuation = $0 } }
        await until { continuation != nil }
        preview.stop()
        preview.start { Data([2]) }
        await until { preview.state == .playing }
        continuation?.resume(returning: Data([1]))
        try? await Task.sleep(for: .milliseconds(30))
        #expect(player.played == [Data([2])])
        #expect(preview.state == .playing)
        preview.stop()
        #expect(!player.isPlaying)
        #expect(preview.state == .idle)
    }

    @Test("Fast switching coalesces requests and Stop cancels pending generation")
    func debounce() async {
        let preview = SettingsVoicePreview(player: PreviewPlayerStub())
        var calls = 0
        for _ in 0..<5 {
            preview.start(debounce: .milliseconds(30)) { calls += 1; return Data([1]) }
        }
        await until { preview.state == .playing }
        #expect(calls == 1)
        preview.start(debounce: .milliseconds(30)) { calls += 1; return Data([2]) }
        preview.stop()
        try? await Task.sleep(for: .milliseconds(60))
        #expect(calls == 1)
    }

    @Test("Selection cancellation is silent even if a closure throws it directly")
    func normalCancellation() async {
        let player = PreviewPlayerStub()
        let preview = SettingsVoicePreview(player: player)
        preview.start { throw CancellationError() }
        await until { preview.state == .idle }
        #expect(preview.errorMessage == nil)
        #expect(player.played.isEmpty)
    }

    @Test("Synthesis and playback errors are surfaced and recover on replay")
    func errors() async {
        let player = PreviewPlayerStub()
        let preview = SettingsVoicePreview(player: player)
        preview.start { throw AudioClientError.emptyAudio }
        await until { preview.state == .failed }
        #expect(preview.errorMessage != nil)
        player.fail = true
        preview.start { Data([1]) }
        await until { preview.state == .failed }
        player.fail = false
        preview.start { Data([2]) }
        await until { preview.state == .playing }
        #expect(preview.errorMessage == nil)
        preview.stop()
    }
}
