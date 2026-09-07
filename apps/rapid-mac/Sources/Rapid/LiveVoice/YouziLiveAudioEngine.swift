import AVFoundation
import CoreAudio
import Foundation

/// No AVAudioEngine (and no microphone device) exists until an explicit start.
/// Input and the TTS player share one hardware-rendering graph, so system voice
/// processing has the actual playback reference. This is not an acoustic AEC
/// quality guarantee: that requires an attended speaker/microphone test.
@MainActor
final class YouziLiveAudioEngine {
    var onInputFrame: (([Float]) -> Void)?
    var onPlaybackDrained: (() -> Void)?
    var onFailure: ((String) -> Void)?
    private(set) var isVoiceProcessingEnabled = false

    private var session: YouziAudioSession?
    private var inputTask: Task<Void, Never>?
    private var epoch: UInt64 = 0
    private var playback = YouziPlaybackQueue()

    func start(voiceProcessing: Bool) async throws {
        stop()
        let startingEpoch = epoch
        try Task.checkCancellation()
        // Missing usage text must never reach AVFoundation's permission request
        // (which would terminate an unbundled process). Tests do not call start.
        guard let usage = Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String,
              !usage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw YouziLiveAudioError.microphoneUsageMissing
        }
        let authorized: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: authorized = true
        case .notDetermined: authorized = await AVCaptureDevice.requestAccess(for: .audio)
        default: authorized = false
        }
        try Task.checkCancellation()
        guard startingEpoch == epoch else { throw CancellationError() }
        guard authorized else { throw YouziLiveAudioError.microphoneDenied }

        let resources = YouziAudioSession()
        do {
            let input = resources.engine.inputNode
            if voiceProcessing {
                // SDK AVAudioIONode.h: enable only while stopped; setting either
                // I/O node enables both. Do this BEFORE obtaining tap formats.
                do { try input.setVoiceProcessingEnabled(true) }
                catch { throw YouziLiveAudioError.voiceProcessingUnavailable }
                guard input.isVoiceProcessingEnabled,
                      resources.engine.outputNode.isVoiceProcessingEnabled else {
                    throw YouziLiveAudioError.voiceProcessingUnavailable
                }
            }
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate.isFinite, (8_000...192_000).contains(format.sampleRate),
                  format.channelCount > 0, format.channelCount <= 32,
                  resources.engine.outputNode.inputFormat(forBus: 0).channelCount > 0 else {
                throw YouziLiveAudioError.deviceUnavailable
            }
            let (frames, continuation) = AsyncThrowingStream<[Float], Error>.makeStream(
                bufferingPolicy: .bufferingOldest(32)
            )
            resources.continuation = continuation
            let capture = try YouziCaptureConverter(format: format, continuation: continuation)
            resources.engine.attach(resources.player)
            resources.engine.connect(resources.player, to: resources.engine.mainMixerNode, format: YouziPCMCodec.playbackFormat)
            input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(format.sampleRate * 0.1), format: format) { buffer, _ in
                capture.consume(buffer)
            }
            resources.tapInstalled = true
            session = resources
            resources.observer = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: resources.engine, queue: nil
            ) { [weak self] _ in
                // SDK forbids destroying the engine on the notification's
                // internal queue. Always leave that queue before teardown.
                Task { @MainActor [weak self] in
                    guard let self, self.epoch == startingEpoch else { return }
                    self.fail(YouziLiveAudioError.deviceChanged.localizedDescription)
                }
            }
            // The engine notification covers format changes. HAL default-device
            // listeners also catch route switches that keep the same format.
            try resources.observeDefaultDevices { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.epoch == startingEpoch else { return }
                    self.fail(YouziLiveAudioError.deviceChanged.localizedDescription)
                }
            }
            resources.engine.prepare()
            try Task.checkCancellation()
            try resources.engine.start()
            try Task.checkCancellation()
            isVoiceProcessingEnabled = input.isVoiceProcessingEnabled
            inputTask = Task { @MainActor [weak self] in
                do {
                    for try await frame in frames {
                        guard !Task.isCancelled, let self, self.epoch == startingEpoch else { return }
                        self.onInputFrame?(frame)
                    }
                } catch {
                    guard !Task.isCancelled, let self, self.epoch == startingEpoch else { return }
                    self.fail(error.localizedDescription)
                }
            }
        } catch {
            resources.shutdown()
            stop()
            throw error
        }
    }

    /// Accepts the negotiated 24 kHz mono s16le contract. Application-owned
    /// playback is capped at 12 seconds / 128 buffers, with <=500 ms per call.
    /// A producer may retry playbackQueueFull after a cancellable short wait;
    /// never drop or silently replace spoken samples when applying backpressure.
    func enqueuePCM(_ data: Data, sampleRate: Double) throws {
        try Task.checkCancellation()
        guard let session, session.engine.isRunning else { throw YouziLiveAudioError.notRunning }
        guard sampleRate == YouziPCMCodec.sampleRate else { throw YouziLiveAudioError.invalidPCM }
        if data.isEmpty { return }
        let samples = try YouziPCMCodec.decode(data)
        let ticket = try playback.reserve(frames: samples.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: YouziPCMCodec.playbackFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else {
            _ = playback.complete(ticket)
            throw YouziLiveAudioError.invalidPCM
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { channel.update(from: base, count: samples.count) }
        }
        // dataPlayedBack accounts for downstream/device latency. The default
        // completion is merely dataConsumed and can fire before audible output.
        session.player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.playback.complete(ticket) else { return }
                self.onPlaybackDrained?()
            }
        }
        if !session.player.isPlaying { session.player.play() }
    }

    func interruptPlayback() {
        // stop() also fires completion callbacks; invalidate tickets first.
        playback.interrupt()
        session?.player.stop()
    }

    func stop() {
        epoch &+= 1
        inputTask?.cancel()
        inputTask = nil
        playback.interrupt()
        session?.shutdown()
        session = nil
        isVoiceProcessingEnabled = false
    }

    private func fail(_ message: String) {
        stop()
        onFailure?(message)
    }

    deinit {
        inputTask?.cancel()
        session?.shutdown()
    }
}

enum YouziLiveAudioError: Error, LocalizedError, Equatable {
    case microphoneUsageMissing, microphoneDenied, voiceProcessingUnavailable
    case deviceUnavailable, deviceChanged, notRunning, invalidPCM
    case playbackQueueFull, captureQueueFull, captureConversionFailed

    var errorDescription: String? {
        switch self {
        case .microphoneUsageMissing: return "Microphone access requires the app's microphone usage description."
        case .microphoneDenied: return "Microphone access was denied. Enable it in System Settings to start voice."
        case .voiceProcessingUnavailable: return "Echo cancellation is unavailable. Restart explicitly in half-duplex mode."
        case .deviceUnavailable: return "No compatible audio input/output device is available."
        case .deviceChanged: return "The audio device changed. Voice stopped; restart to use the new device."
        case .notRunning: return "The voice audio engine is not running."
        case .invalidPCM: return "Expected bounded 24 kHz mono signed 16-bit little-endian PCM audio."
        case .playbackQueueFull: return "Voice playback reached its queue limit."
        case .captureQueueFull: return "Voice capture stopped because input processing fell behind."
        case .captureConversionFailed: return "The microphone audio format could not be converted."
        }
    }
}

/// Pure PCM decoding; do not use unaligned Int16 loads or the host's endianness.
/// The format object is software-only and does not open an audio device.
enum YouziPCMCodec {
    static let sampleRate = 24_000.0
    static let maximumFramesPerChunk = 12_000
    static var playbackFormat: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    }

    static func decode(_ data: Data) throws -> [Float] {
        guard data.count.isMultiple(of: 2), data.count / 2 <= maximumFramesPerChunk else {
            throw YouziLiveAudioError.invalidPCM
        }
        return data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            return stride(from: 0, to: bytes.count, by: 2).map { index in
                let bits = UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
                return Float(Int16(bitPattern: bits)) / 32_768
            }
        }
    }
}

/// Pure reservation ledger, shared by production and synthetic tests. Both
/// samples AND callback count are bounded; tiny packets cannot exhaust memory.
struct YouziPlaybackQueue {
    struct Ticket: Hashable, Sendable { let epoch: UInt64; let id: UInt64 }
    static let maximumFrames = 288_000
    static let maximumBuffers = 128
    private(set) var queuedFrames = 0
    private var epoch: UInt64 = 0
    private var nextID: UInt64 = 0
    private var pending: [Ticket: Int] = [:]
    var queuedBuffers: Int { pending.count }

    mutating func reserve(frames: Int) throws -> Ticket {
        guard frames > 0, frames <= YouziPCMCodec.maximumFramesPerChunk else { throw YouziLiveAudioError.invalidPCM }
        guard frames <= Self.maximumFrames - queuedFrames, pending.count < Self.maximumBuffers else {
            throw YouziLiveAudioError.playbackQueueFull
        }
        let ticket = Ticket(epoch: epoch, id: nextID)
        nextID &+= 1
        pending[ticket] = frames
        queuedFrames += frames
        return ticket
    }

    /// True exactly once when the current audible queue drains naturally.
    mutating func complete(_ ticket: Ticket) -> Bool {
        guard ticket.epoch == epoch, let frames = pending.removeValue(forKey: ticket) else { return false }
        queuedFrames -= frames
        return pending.isEmpty
    }

    mutating func interrupt() {
        epoch &+= 1
        pending.removeAll(keepingCapacity: false)
        queuedFrames = 0
    }
}

/// Accessed only on the main actor (or during the owning object's final release).
/// This wrapper allows deinit to synchronously close the mic under Swift 6;
/// AVFoundation callbacks never mutate it.
private final class YouziAudioSession: @unchecked Sendable {
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    var tapInstalled = false
    var observer: NSObjectProtocol?
    var continuation: AsyncThrowingStream<[Float], Error>.Continuation?
    private var deviceListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    func observeDefaultDevices(onChange: @escaping @Sendable () -> Void) throws {
        for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
            )
            let listener: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
            guard AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener) == noErr else {
                throw YouziLiveAudioError.deviceUnavailable
            }
            deviceListeners.append((address, listener))
        }
    }

    func shutdown() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        for (storedAddress, listener) in deviceListeners {
            var address = storedAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
        }
        deviceListeners.removeAll()
        continuation?.finish()
        continuation = nil
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
        tapInstalled = false
        player.stop()
    }
}

/// The converter is confined to AVAudioEngine's serial input tap, not passed to
/// main-actor tasks. Only bounded value-type frames cross that boundary.
final class YouziCaptureConverter: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let continuation: AsyncThrowingStream<[Float], Error>.Continuation
    private let sourceFormat: AVAudioFormat
    private var finished = false
    static let frameSamples = 320 // 20 ms of 16 kHz mono Float32

    init(format: AVAudioFormat, continuation: AsyncThrowingStream<[Float], Error>.Continuation) throws {
        guard format.sampleRate.isFinite, (8_000...192_000).contains(format.sampleRate),
              format.channelCount > 0, format.channelCount <= 32,
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: output) else {
            throw YouziLiveAudioError.captureConversionFailed
        }
        converter.primeMethod = .none // Live input: do not require a future filter tail.
        self.converter = converter
        self.sourceFormat = format
        self.continuation = continuation
    }

    func consume(_ buffer: AVAudioPCMBuffer) {
        guard !finished else { return }
        guard buffer.format == sourceFormat,
              Double(buffer.frameLength) <= sourceFormat.sampleRate * 0.5 else {
            finish(YouziLiveAudioError.captureConversionFailed)
            return
        }
        guard buffer.frameLength > 0 else { return }
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * 16_000 / sourceFormat.sampleRate)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
            finish(YouziLiveAudioError.captureConversionFailed)
            return
        }
        let input = SingleBufferInput(buffer)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, status in
            input.take(status)
        }
        guard conversionError == nil, status != .error,
              let channel = output.floatChannelData?[0] else {
            finish(YouziLiveAudioError.captureConversionFailed)
            return
        }
        for start in stride(from: 0, to: Int(output.frameLength), by: Self.frameSamples) {
            let end = min(start + Self.frameSamples, Int(output.frameLength))
            let samples = (start..<end).map { channel[$0].isFinite ? max(-1, min(1, channel[$0])) : 0 }
            switch continuation.yield(samples) {
            case .enqueued: break
            case .dropped: finish(YouziLiveAudioError.captureQueueFull); return
            case .terminated: finished = true; return
            @unknown default: finish(YouziLiveAudioError.captureConversionFailed); return
            }
        }
    }

    // AVAudioConverter calls its input block synchronously while convert runs.
    // Encapsulate the non-Sendable buffer and one-shot cursor rather than
    // capturing mutable stack variables in the SDK's @Sendable block.
    private final class SingleBufferInput: @unchecked Sendable {
        private var buffer: AVAudioPCMBuffer?
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
        func take(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            guard let buffer else { status.pointee = .noDataNow; return nil }
            self.buffer = nil
            status.pointee = .haveData
            return buffer
        }
    }

    private func finish(_ error: Error) {
        finished = true
        continuation.finish(throwing: error)
    }
}
