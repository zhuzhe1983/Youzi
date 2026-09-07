// Software-only real AVFAudio callback bridge regression. Run through the
// adjacent shell script; legacy modes deliberately trap in child processes.
import AVFoundation
import Foundation
@main struct RenderProbe {
    @MainActor static func main() async throws {
        let engine = AVAudioEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 2)!
        // No inputNode, microphone, output hardware or permissions. The SDK tap
        // is nevertheless invoked by AVFAudio, through its real ObjC thunk.
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1_024)
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        let (stream, continuation) = AsyncThrowingStream<[Float], Error>.makeStream(bufferingPolicy: .bufferingOldest(512))
        let capture = try YouziCaptureConverter(format: format, continuation: continuation)
        if CommandLine.arguments.contains("legacy-tap") {
            // Unchanged pre-fix callback inside a MainActor async method.
            engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
                capture.consume(buffer)
            }
        } else {
            engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1_024, format: format, block: YouziLiveAudioCallbacks.inputTap(capture))
        }
        defer { engine.stop(); continuation.finish() }
        let tone = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000)!
        tone.frameLength = 8_000
        tone.floatChannelData![0].initialize(repeating: 0.25, count: 8_000)
        tone.floatChannelData![1].initialize(repeating: 0.25, count: 8_000)
        let owner = YouziLiveAudioEngine()
        var drains = 0
        owner.onPlaybackDrained = { MainActor.assertIsolated(); drains += 1 }
        // Offline engines have no device presentation; request consumed events
        // to exercise the same ObjC completion block ABI, not audible drain.
        player.scheduleBuffer(tone, completionCallbackType: .dataConsumed,
            completionHandler: try owner.reservePlaybackCompletion(frames: 8_000))
        engine.prepare()
        try engine.start()
        player.play()
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024)!
        for _ in 0..<30 {
            let status = try engine.renderOffline(1_024, to: output)
            precondition(status == .success)
            try await Task.sleep(for: .milliseconds(10))
        }
        engine.stop()
        player.stop()
        for _ in 0..<200 where drains == 0 { try await Task.sleep(for: .milliseconds(10)) }
        engine.mainMixerNode.removeTap(onBus: 0)
        continuation.finish()
        var count = 0
        for try await frame in stream { count += frame.count }
        precondition(count > 0 && drains == 1)
        print("PASS real AVFAudio offline tap: \(count) samples; no hardware input/output")
    }
}
