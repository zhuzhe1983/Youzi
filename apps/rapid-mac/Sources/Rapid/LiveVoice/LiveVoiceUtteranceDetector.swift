import Foundation

/// Energy VAD, not an ASR decoder. Consumes 16 kHz mono Float32 and emits bounded
/// utterance windows for HTTP transcription. Thresholds deliberately require
/// sustained energy: clicks/short noise spikes must not interrupt a spoken reply.
struct LiveVoiceUtteranceDetector {
    struct Configuration {
        var sampleRate = 16_000
        var windowSamples = 320
        var rmsThreshold: Float = 0.018
        var startWindows = 10       // 200 ms sustained voice
        var preRollWindows = 18     // 360 ms, includes the start decision
        var endSilenceWindows = 33  // 660 ms endpoint silence
        var maxUtteranceWindows = 750 // 15 s safety limit; overflow is NEVER submitted
    }
    enum Event: Equatable {
        case speechStarted
        /// No ASR/chat submission: a still-speaking user has not finished a command.
        case limitReached
        case utterance([Float])
    }

    let configuration: Configuration
    private var pending: [Float] = []
    private var preRoll: [Float] = []
    private var captured: [Float] = []
    private var voicedWindows = 0
    private var silenceWindows = 0
    private(set) var isSpeaking = false
    var bufferedSampleCount: Int { pending.count + preRoll.count + captured.count }

    init(configuration: Configuration = Configuration()) {
        precondition(configuration.windowSamples > 0 && configuration.startWindows > 0)
        precondition(configuration.endSilenceWindows > 0)
        precondition(configuration.preRollWindows >= configuration.startWindows)
        precondition(configuration.maxUtteranceWindows > configuration.preRollWindows)
        self.configuration = configuration
    }

    mutating func append(_ samples: [Float]) -> [Event] {
        var events: [Event] = []
        // Process incrementally even when a caller supplies an enormous buffer.
        for sample in samples {
            pending.append(sample.isFinite ? max(-1, min(1, sample)) : 0)
            if pending.count == configuration.windowSamples {
                let window = pending
                pending.removeAll(keepingCapacity: true)
                events += consume(window)
            }
        }
        return events
    }

    private mutating func consume(_ window: [Float]) -> [Event] {
        let energy = window.reduce(Float.zero) { $0 + $1 * $1 } / Float(window.count)
        let voiced = energy.squareRoot() >= configuration.rmsThreshold
        if !isSpeaking {
            preRoll += window
            let limit = configuration.preRollWindows * configuration.windowSamples
            if preRoll.count > limit { preRoll.removeFirst(preRoll.count - limit) }
            voicedWindows = voiced ? voicedWindows + 1 : 0
            guard voicedWindows >= configuration.startWindows else { return [] }
            captured = preRoll
            preRoll.removeAll(keepingCapacity: true)
            isSpeaking = true
            silenceWindows = 0
            return [.speechStarted]
        }
        captured += window
        silenceWindows = voiced ? 0 : silenceWindows + 1
        if captured.count >= configuration.maxUtteranceWindows * configuration.windowSamples {
            reset()
            return [.limitReached]
        }
        if silenceWindows >= configuration.endSilenceWindows {
            let result = captured
            reset()
            return [.utterance(result)]
        }
        return []
    }

    /// Manual endpoint for half duplex. Never transcribes silence or a click.
    mutating func finish() -> [Float]? {
        let result = isSpeaking ? captured + pending : nil
        reset()
        return result
    }

    mutating func reset() {
        pending.removeAll(keepingCapacity: true)
        preRoll.removeAll(keepingCapacity: true)
        captured.removeAll(keepingCapacity: true)
        voicedWindows = 0
        silenceWindows = 0
        isSpeaking = false
    }

    /// In-memory PCM16 WAV. No temporary recordings or new persistence policy.
    static func wavData(_ samples: [Float], sampleRate: Int = 16_000) -> Data {
        var data = Data()
        func text(_ string: String) { data.append(contentsOf: string.utf8) }
        func u16(_ value: UInt16) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        func u32(_ value: UInt32) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        text("RIFF"); u32(UInt32(36 + samples.count * 2)); text("WAVEfmt ")
        u32(16); u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2))
        u16(2); u16(16); text("data"); u32(UInt32(samples.count * 2))
        for sample in samples {
            let finite = sample.isFinite ? max(-1, min(1, sample)) : 0
            u16(UInt16(bitPattern: Int16(finite * 32767)))
        }
        return data
    }
}
