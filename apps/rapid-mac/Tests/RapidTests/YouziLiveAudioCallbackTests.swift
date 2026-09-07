import AVFoundation
import Foundation
import Testing
@testable import Rapid

/// Do not substitute the audio-engine protocol here: that missed the delivered
/// SIGTRAP. Construct the production SDK blocks on MainActor, then invoke them
/// from a serial non-main queue with software-only AVAudioPCMBuffer data.
@Suite("YouziLiveAudioCallbackTests", .serialized)
@MainActor
struct YouziLiveAudioCallbackTests {
    @Test("Tap entry runs off MainActor and copies transient stereo PCM synchronously")
    func tapExecutorAndOwnership() async throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let (stream, continuation) = AsyncThrowingStream<[Float], Error>.makeStream(bufferingPolicy: .bufferingOldest(32))
        let capture = try YouziCaptureConverter(format: format, continuation: continuation)
        let tap = YouziLiveAudioCallbacks.inputTap(capture)
        try await Self.offMain {
            let buffer = try Self.buffer(sampleRate: 48_000, channels: 2, frames: 4_800)
            tap(buffer, AVAudioTime(sampleTime: 0, atRate: 48_000))
            tap(buffer, AVAudioTime(sampleTime: 4_800, atRate: 48_000))
            // AVFAudio may reuse its storage immediately after callback return.
            for channel in 0..<2 { buffer.floatChannelData![channel].update(repeating: 0, count: 4_800) }
        }
        continuation.finish()
        var samples: [Float] = []
        for try await frame in stream {
            #expect(!frame.isEmpty && frame.count <= YouziCaptureConverter.frameSamples)
            samples += frame
        }
        #expect((3_000...3_264).contains(samples.count))
        #expect(samples.allSatisfy { $0.isFinite && abs($0) <= 1 })
        #expect((samples.map(abs).max() ?? 0) > 0.1)
    }

    @Test("Actual background tap preserves overflow failure and ignores later callbacks")
    func tapOverflow() async throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let (stream, continuation) = AsyncThrowingStream<[Float], Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let tap = YouziLiveAudioCallbacks.inputTap(try YouziCaptureConverter(format: format, continuation: continuation))
        try await Self.offMain {
            let buffer = try Self.buffer(sampleRate: 16_000, channels: 1, frames: 1_600)
            for _ in 0..<10 { tap(buffer, AVAudioTime(sampleTime: 0, atRate: 16_000)) }
        }
        var received = 0
        do {
            for try await _ in stream { received += 1 }
            Issue.record("Overflow must stop capture, not silently drop speech")
        } catch {
            #expect(error as? YouziLiveAudioError == .captureQueueFull)
        }
        #expect(received == 1)
    }

    @Test("A late tap after stream shutdown cannot publish into the next session")
    func tapAfterShutdown() async throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let (stream, continuation) = AsyncThrowingStream<[Float], Error>.makeStream(bufferingPolicy: .bufferingOldest(32))
        let tap = YouziLiveAudioCallbacks.inputTap(try YouziCaptureConverter(format: format, continuation: continuation))
        continuation.finish()
        try await Self.offMain {
            let buffer = try Self.buffer(sampleRate: 16_000, channels: 1, frames: 1_600)
            for _ in 0..<10 { tap(buffer, AVAudioTime(sampleTime: 0, atRate: 16_000)) }
        }
        for try await _ in stream { Issue.record("Stopped capture delivered a frame") }
    }

    @Test("Playback callback hops to MainActor; stop and interrupt reject stale tickets")
    func playbackEpochs() async throws {
        let engine = YouziLiveAudioEngine()
        var drains = 0
        engine.onPlaybackDrained = { MainActor.assertIsolated(); drains += 1 }
        let stopped = try engine.reservePlaybackCompletion(frames: 320)
        engine.stop()
        let interrupted = try engine.reservePlaybackCompletion(frames: 320)
        engine.interruptPlayback()
        let first = try engine.reservePlaybackCompletion(frames: 320)
        let last = try engine.reservePlaybackCompletion(frames: 320)
        try await Self.offMain {
            stopped(.dataPlayedBack)
            interrupted(.dataPlayedBack)
            first(.dataPlayedBack)
        }
        await Self.flushMainActor()
        #expect(drains == 0)
        try await Self.offMain {
            last(.dataPlayedBack)
            last(.dataPlayedBack)
            stopped(.dataPlayedBack)
        }
        await Self.flushMainActor()
        #expect(drains == 1)
    }

    @Test("Concurrent playback events retain bounded reservations and drain exactly once")
    func playbackBoundsAndConcurrency() async throws {
        let engine = YouziLiveAudioEngine()
        var drains = 0
        engine.onPlaybackDrained = { MainActor.assertIsolated(); drains += 1 }
        let callbacks = try (0..<YouziPlaybackQueue.maximumBuffers).map { _ in try engine.reservePlaybackCompletion(frames: 1) }
        #expect(throws: YouziLiveAudioError.playbackQueueFull) { try engine.reservePlaybackCompletion(frames: 1) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for callback in callbacks {
                group.addTask { try await Self.offMain { callback(.dataPlayedBack) } }
            }
            try await group.waitForAll()
        }
        await Self.flushMainActor()
        #expect(drains == 1)
        let next = try engine.reservePlaybackCompletion(frames: 1)
        try await Self.offMain { next(.dataPlayedBack) }
        await Self.flushMainActor()
        #expect(drains == 2)
    }

    @Test("Notification and HAL callbacks leave the posting queue and reject old sessions")
    func deviceChanges() async throws {
        let engine = YouziLiveAudioEngine()
        var failures = 0
        engine.onFailure = { _ in MainActor.assertIsolated(); failures += 1 }
        let stale = engine.makeDeviceChangeHandler()
        engine.stop()
        let current = engine.makeDeviceChangeHandler()
        let notification = YouziLiveAudioCallbacks.configurationChange(current)
        let center = NotificationCenter()
        let token = center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil, using: notification)
        defer { center.removeObserver(token) }
        try await Self.offMain { stale() }
        await Self.flushMainActor()
        #expect(failures == 0)
        try await Self.offMain { center.post(name: .AVAudioEngineConfigurationChange, object: nil) }
        await Self.flushMainActor()
        #expect(failures == 1)
        // fail() stopped the session. A queued HAL/notification repeat is stale.
        try await Self.offMain { current(); center.post(name: .AVAudioEngineConfigurationChange, object: nil) }
        await Self.flushMainActor()
        #expect(failures == 1)
    }

    @Test("Framework callbacks do not retain the stopped audio owner")
    func releasedOwner() async throws {
        var engine: YouziLiveAudioEngine? = YouziLiveAudioEngine()
        weak var owner = engine
        let completion = try #require(engine).reservePlaybackCompletion(frames: 1)
        let device = try #require(engine).makeDeviceChangeHandler()
        engine = nil
        #expect(owner == nil)
        try await Self.offMain { completion(.dataPlayedBack); device() }
        await Self.flushMainActor()
        #expect(owner == nil)
    }

    @Test("Real AVFAudio ObjC tap and player completion survive offline start/stop cycles")
    func offlineFrameworkCallbacks() async throws {
        // Calling a Swift closure directly does NOT exercise the ObjC thunk
        // which trapped in the installed app. Offline rendering does, without
        // accessing inputNode or opening microphone/speaker hardware. Voice
        // processing is unsupported offline: this is NOT an acoustic AEC test.
        for _ in 0..<3 {
            let engine = AVAudioEngine()
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 2))
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1_024)
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            let (stream, continuation) = AsyncThrowingStream<[Float], Error>.makeStream(bufferingPolicy: .bufferingOldest(512))
            let capture = try YouziCaptureConverter(format: format, continuation: continuation)
            engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1_024, format: format,
                block: YouziLiveAudioCallbacks.inputTap(capture))
            defer {
                engine.stop()
                engine.mainMixerNode.removeTap(onBus: 0)
                continuation.finish()
            }
            let owner = YouziLiveAudioEngine()
            var drains = 0
            owner.onPlaybackDrained = { MainActor.assertIsolated(); drains += 1 }
            let tone = try Self.buffer(sampleRate: 16_000, channels: 2, frames: 8_000)
            // Offline has no hardware presentation clock. A consumed event
            // exercises the same ObjC block ABI; production still requests
            // dataPlayedBack. This test does not qualify audible completion.
            player.scheduleBuffer(tone, completionCallbackType: .dataConsumed,
                completionHandler: try owner.reservePlaybackCompletion(frames: 8_000))
            engine.prepare()
            try engine.start()
            player.play()
            let output = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024))
            for _ in 0..<30 {
                #expect(try engine.renderOffline(1_024, to: output) == .success)
                try await Task.sleep(for: .milliseconds(10))
            }
            engine.stop()
            player.stop()
            continuation.finish()
            for _ in 0..<200 where drains == 0 { try await Task.sleep(for: .milliseconds(10)) }
            await Self.flushMainActor()
            var samples = 0
            var peak: Float = 0
            for try await frame in stream {
                samples += frame.count
                peak = max(peak, frame.map(abs).max() ?? 0)
            }
            #expect(samples > 0)
            #expect(peak > 0.1)
            #expect(drains == 1)
            owner.stop()
        }
    }

    private nonisolated static func buffer(sampleRate: Double, channels: AVAudioChannelCount, frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            for index in 0..<Int(frames) {
                buffer.floatChannelData![channel][index] = sin(Float(index) * 2 * .pi * 440 / Float(sampleRate)) * 0.25
            }
        }
        return buffer
    }

    private nonisolated static func offMain(_ action: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue(label: "YouziLiveAudioCallbackTests.framework").async {
                dispatchPrecondition(condition: .notOnQueue(.main))
                continuation.resume(with: Result { try action() })
            }
        }
    }

    /// All SDK invocations above have returned. Flush a main-actor delivery
    /// through the same bridge, without sleeps or opening audio hardware.
    private nonisolated static func flushMainActor() async {
        await withCheckedContinuation { continuation in
            YouziLiveAudioCallbacks.deliverOnMainActor { continuation.resume() }()
        }
    }
}
