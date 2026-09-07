import AVFoundation
import Foundation
import Testing
@testable import Rapid

@Suite("YouziLiveAudioCoreTests", .serialized)
struct YouziLiveAudioCoreTests {
    @Test("Little-endian signed PCM uses asymmetric full scale and supports sliced Data")
    func pcmDecode() throws {
        let bytes = Data([99, 0, 128, 255, 127, 0, 0, 0, 64, 0, 192])
        let samples = try YouziPCMCodec.decode(bytes.dropFirst())
        #expect(samples == [-1, Float(32767) / 32768, 0, 0.5, -0.5])
        #expect(try YouziPCMCodec.decode(Data()).isEmpty)
        #expect(throws: YouziLiveAudioError.invalidPCM) { try YouziPCMCodec.decode(Data([0])) }
        #expect(throws: YouziLiveAudioError.invalidPCM) {
            try YouziPCMCodec.decode(Data(count: (YouziPCMCodec.maximumFramesPerChunk + 1) * 2))
        }
    }

    @Test("Arbitrary packet boundaries preserve complete samples and bounded chunks")
    func oddByteFraming() throws {
        let input = Data((0..<20_002).map { UInt8(truncatingIfNeeded: $0) })
        var framer = YouziPCMFramer()
        var output = Data()
        var chunks = 0
        for byte in input {
            if let chunk = framer.append(byte) {
                #expect(chunk.count == YouziPCMFramer.maximumChunkBytes)
                output.append(chunk)
                chunks += 1
            }
            #expect(framer.bufferedByteCount < YouziPCMFramer.maximumChunkBytes)
        }
        let tail = try framer.finish()
        output.append(try #require(tail))
        #expect(chunks == 4)
        #expect(output == input)
        #expect(try framer.finish() == nil)
        var truncated = YouziPCMFramer(chunkBytes: 4)
        #expect(truncated.append(1) == nil)
        #expect(throws: AudioClientError.invalidResponse) { try truncated.finish() }
    }

    @Test("Playback bounds both duration and callback count without mutating on failure")
    func playbackBounds() throws {
        var queue = YouziPlaybackQueue()
        for _ in 0..<24 { _ = try queue.reserve(frames: 12_000) }
        #expect(queue.queuedFrames == YouziPlaybackQueue.maximumFrames)
        #expect(throws: YouziLiveAudioError.playbackQueueFull) { try queue.reserve(frames: 1) }
        #expect(queue.queuedFrames == YouziPlaybackQueue.maximumFrames)
        queue.interrupt()
        for _ in 0..<YouziPlaybackQueue.maximumBuffers { _ = try queue.reserve(frames: 1) }
        #expect(throws: YouziLiveAudioError.playbackQueueFull) { try queue.reserve(frames: 1) }
        #expect(queue.queuedBuffers == YouziPlaybackQueue.maximumBuffers)
        #expect(throws: YouziLiveAudioError.invalidPCM) { try queue.reserve(frames: 0) }
        #expect(throws: YouziLiveAudioError.invalidPCM) { try queue.reserve(frames: Int.max) }
    }

    @Test("Interrupt invalidates late and duplicate completion callbacks")
    func playbackEpochs() throws {
        var queue = YouziPlaybackQueue()
        let old = try queue.reserve(frames: 100)
        queue.interrupt()
        let first = try queue.reserve(frames: 200)
        let last = try queue.reserve(frames: 300)
        #expect(queue.complete(old) == false)
        #expect(queue.queuedFrames == 500)
        #expect(queue.complete(first) == false)
        #expect(queue.complete(first) == false)
        #expect(queue.complete(last) == true)
        #expect(queue.complete(last) == false)
        #expect(queue.queuedFrames == 0)
        #expect(queue.queuedBuffers == 0)
    }

    @MainActor
    @Test("Constructing, stopping and rejecting playback never starts hardware")
    func inertEngine() {
        let engine = YouziLiveAudioEngine()
        var callback = false
        engine.onPlaybackDrained = { callback = true }
        engine.onInputFrame = { _ in callback = true }
        engine.onFailure = { _ in callback = true }
        #expect(!engine.isVoiceProcessingEnabled)
        #expect(throws: YouziLiveAudioError.notRunning) {
            try engine.enqueuePCM(Data([0, 0]), sampleRate: 24_000)
        }
        engine.interruptPlayback()
        engine.stop()
        engine.stop()
        #expect(!callback)
        #expect(!engine.isVoiceProcessingEnabled)
        // Intentionally never call start(), even if the test host has consent.
    }

    @Test("Software converter produces finite 16 kHz mono frames without devices")
    func syntheticCapture() async throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
        buffer.frameLength = 4_800
        for channel in 0..<2 {
            for index in 0..<4_800 {
                buffer.floatChannelData![channel][index] = sin(Float(index) * 2 * .pi * 440 / 48_000) * 0.25
            }
        }
        let (stream, continuation) = AsyncThrowingStream<[Float], Error>.makeStream(bufferingPolicy: .bufferingOldest(32))
        let converter = try YouziCaptureConverter(format: format, continuation: continuation)
        converter.consume(buffer)
        converter.consume(buffer)
        continuation.finish()
        var sampleCount = 0
        var peak: Float = 0
        for try await frame in stream {
            #expect(!frame.isEmpty && frame.count <= 320)
            #expect(frame.allSatisfy { $0.isFinite && abs($0) <= 1 })
            peak = max(peak, frame.map(abs).max() ?? 0)
            sampleCount += frame.count
        }
        // Converter priming can withhold a small filter tail at the first call.
        #expect((3_000...3_264).contains(sampleCount))
        #expect(peak > 0.1)
    }

    @Test("Capture overflow terminates instead of silently losing utterance samples")
    func captureBounds() async throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600))
        buffer.frameLength = 1_600
        buffer.floatChannelData![0].initialize(repeating: 0, count: 1_600)
        let (stream, continuation) = AsyncThrowingStream<[Float], Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let converter = try YouziCaptureConverter(format: format, continuation: continuation)
        converter.consume(buffer)
        var count = 0
        do {
            for try await _ in stream { count += 1 }
            Issue.record("Expected a capture overflow error")
        } catch {
            #expect(error as? YouziLiveAudioError == .captureQueueFull)
        }
        #expect(count <= 1)
    }

    @Test("Device format mismatch terminates synthetic input safely")
    func captureFormatChange() async throws {
        let source = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let changed = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: changed, frameCapacity: 100))
        buffer.frameLength = 100
        let (stream, continuation) = AsyncThrowingStream<[Float], Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
        let converter = try YouziCaptureConverter(format: source, continuation: continuation)
        converter.consume(buffer)
        do {
            for try await _ in stream { Issue.record("Mismatched format must not be delivered") }
            Issue.record("Expected a format error")
        } catch {
            #expect(error as? YouziLiveAudioError == .captureConversionFailed)
        }
    }

    @Test("PCM response metadata is mandatory and exact")
    func responseHeaders() throws {
        let url = URL(string: "http://127.0.0.1:8123/v1/audio/speech")!
        let valid = LivePCMProtocol.headers
        #expect(try AudioClient.streamingSampleRate(from: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: valid)!) == 24_000)
        for (name, value) in [("X-Audio-Sample-Rate", "nan"), ("X-Audio-Sample-Rate", "16000"),
                              ("X-Audio-Channels", "2"), ("X-Audio-Format", "float32"), ("X-Audio-Format", "")] {
            var invalid = valid
            invalid[name] = value
            #expect(throws: AudioClientError.invalidResponse) {
                try AudioClient.streamingSampleRate(from: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: invalid)!)
            }
        }
        #expect(throws: AudioClientError.invalidResponse) {
            try AudioClient.streamingSampleRate(from: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [:])!)
        }
    }

    @MainActor
    @Test("PCM arrives before EOF, with bearer, selected defaults and odd-packet assembly")
    func incrementalSpeech() async throws {
        let name = "YouziLiveAudioCoreTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["speech-model": "Serena"], forKey: ModelGenerationDefaults.Key.voices)
        defaults.set(1.25, forKey: ModelGenerationDefaults.Key.speed)
        var configuredClient = makeClient(.init(chunks: [Data(repeating: 1, count: 4_799), Data([2, 3])], holdOpen: true))
        configuredClient.generationDefaults = ModelGenerationDefaults(defaults: defaults)
        let client = configuredClient
        var chunks: [Data] = []
        let task = Task { @MainActor in
            try await client.streamSpeech(text: "Hello", model: "speech-model", voice: nil, port: 8123, bearer: "test-secret") { data, rate in
                #expect(rate == 24_000)
                chunks.append(data)
                if chunks.count == 1 {
                    #expect(!LivePCMProtocol.state.snapshot().finished)
                    LivePCMProtocol.finishHeld(tail: Data([4]))
                }
            }
        }
        let deadline = deadline(for: task)
        defer { deadline.cancel(); client.session.invalidateAndCancel() }
        try await task.value
        #expect(chunks.map(\.count) == [4_800, 2])
        #expect(chunks.last == Data([3, 4]))
        let requests = LivePCMProtocol.state.snapshot().requests
        #expect(requests.map { $0.url?.path } == ["/v1/audio/voices", "/v1/audio/speech"])
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer test-secret" })
        let request = try #require(requests.last)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Accept") == "audio/pcm")
        let bodyData = try #require(LivePCMProtocol.state.snapshot().body)
        let body = try #require(try JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
        #expect(body["stream"] as? Bool == true)
        #expect(body["response_format"] as? String == "pcm")
        #expect(body["model"] as? String == "speech-model")
        #expect(body["voice"] as? String == "Serena")
        #expect(body["speed"] as? Double == 1.25)
    }

    @MainActor
    @Test("HTTP errors, empty audio, missing metadata and truncated samples fail closed")
    func streamFailures() async throws {
        let scenarios: [(LivePCMProtocol.Plan, AudioClientError)] = [
            (.init(status: 409, chunks: [Data(#"{"detail":{"message":"lane busy"}}"#.utf8)]), .http(status: 409, message: "lane busy")),
            (.init(chunks: []), .emptyAudio),
            (.init(chunks: [Data([1, 2, 3])]), .invalidResponse),
            (.init(headers: [:], chunks: [Data([0, 0])]), .invalidResponse),
            (.init(status: 500, chunks: [Data(repeating: 65, count: 10_000)], holdOpen: true), .http(status: 500, message: nil))
        ]
        for (plan, expected) in scenarios {
            let client = makeClient(plan)
            let task = Task { @MainActor in
                try await client.streamSpeech(text: "Hello", model: "model", voice: "Vivian", port: 8123, bearer: nil) { _, _ in
                    Issue.record("Invalid response must not produce PCM")
                }
            }
            let deadline = deadline(for: task)
            do {
                try await task.value
                Issue.record("Expected \(expected)")
            } catch {
                #expect(error as? AudioClientError == expected)
            }
            deadline.cancel()
            client.session.invalidateAndCancel()
        }
    }

    @MainActor
    @Test("Consumer error closes the network stream without swallowing the typed error")
    func consumerFailure() async throws {
        let client = makeClient(.init(chunks: [Data(count: 4_800)], holdOpen: true))
        let task = Task { @MainActor in
            try await client.streamSpeech(text: "Hello", model: "model", voice: "Vivian", port: 8123, bearer: nil) { _, _ in
                throw YouziLiveAudioError.playbackQueueFull
            }
        }
        let deadline = deadline(for: task)
        defer { deadline.cancel(); client.session.invalidateAndCancel() }
        do {
            try await task.value
            Issue.record("Expected the consumer's error")
        } catch {
            #expect(error as? YouziLiveAudioError == .playbackQueueFull)
        }
        try await waitUntil { LivePCMProtocol.state.snapshot().stopped }
    }

    @MainActor
    @Test("Cancellation while consumer awaits closes the underlying request")
    func cancelDuringConsumer() async throws {
        let client = makeClient(.init(chunks: [Data(count: 4_800)], holdOpen: true))
        var callbackCount = 0
        let task = Task { @MainActor in
            try await client.streamSpeech(text: "Hello", model: "model", voice: "Vivian", port: 8123, bearer: nil) { _, _ in
                callbackCount += 1
                try await Task.sleep(for: .seconds(30))
            }
        }
        defer { task.cancel(); client.session.invalidateAndCancel() }
        try await waitUntil { callbackCount == 1 }
        task.cancel()
        do {
            try await task.value
            Issue.record("Expected cancellation")
        } catch { #expect(error is CancellationError) }
        try await waitUntil { LivePCMProtocol.state.snapshot().stopped }
        #expect(callbackCount == 1)
    }

    @MainActor
    @Test("Cancellation while waiting for PCM closes the stream; precancel sends no request")
    func cancelDuringRead() async throws {
        let client = makeClient(.init(chunks: [], holdOpen: true))
        var chunks = 0
        let task = Task { @MainActor in
            try await client.streamSpeech(text: "Hello", model: "model", voice: "Vivian", port: 8123, bearer: nil) { _, _ in chunks += 1 }
        }
        defer { task.cancel(); client.session.invalidateAndCancel() }
        try await waitUntil { !LivePCMProtocol.state.snapshot().requests.isEmpty }
        task.cancel()
        do { try await task.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        try await waitUntil { LivePCMProtocol.state.snapshot().stopped }
        #expect(chunks == 0)

        let before = LivePCMProtocol.state.snapshot().requests.count
        let precancelled = Task { @MainActor in
            try await client.streamSpeech(text: "Hello", model: "model", voice: "Vivian", port: 8123, bearer: nil) { _, _ in Issue.record("No late PCM") }
        }
        precancelled.cancel()
        do { try await precancelled.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        #expect(LivePCMProtocol.state.snapshot().requests.count == before)
    }

    /// Explicit opt-in only: this does not load/download models, open a mic,
    /// construct an engine, or play audio. Require an already-resident idle lane.
    @MainActor
    @Test("Opt-in native bytes against an already-resident loopback speech endpoint",
          .enabled(if: ProcessInfo.processInfo.environment["YOUZI_LIVE_AUDIO_TEST_PORT"] != nil))
    func residentEndpointStreaming() async throws {
        let environment = ProcessInfo.processInfo.environment
        let portText = try #require(environment["YOUZI_LIVE_AUDIO_TEST_PORT"])
        let port = try #require(Int(portText))
        try #require((1...65535).contains(port))
        let model = try #require(environment["YOUZI_LIVE_AUDIO_TEST_MODEL"])
        let voice = try #require(environment["YOUZI_LIVE_AUDIO_TEST_VOICE"])
        let bearer = environment["YOUZI_LIVE_AUDIO_TEST_BEARER"]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 120
        let client = AudioClient(session: URLSession(configuration: configuration))
        defer { client.session.invalidateAndCancel() }

        @MainActor func laneIsIdle() async throws -> Bool {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
            if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
            let (data, response) = try await client.session.data(for: request)
            let http = try #require(response as? HTTPURLResponse)
            try #require(http.statusCode == 200)
            let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let lanes = try #require(root["lanes"] as? [[String: Any]])
            let lane = try #require(lanes.first { $0["model"] as? String == model })
            return lane["state"] as? String == "resident" && lane["active_requests"] as? Int == 0
        }
        @MainActor func waitForIdle() async throws -> Bool {
            for _ in 0..<200 {
                if try await laneIsIdle() { return true }
                try await Task.sleep(for: .milliseconds(100))
            }
            return false
        }
        try #require(await laneIsIdle(), "Do not contend with another worker or implicitly load a model")

        var chunkCount = 0
        var byteCount = 0
        var firstPCM: ContinuousClock.Instant?
        let start = ContinuousClock.now
        let speech = Task { @MainActor in
            try await client.streamSpeech(
                text: "This is a native streaming acceptance check. The first audio frames must arrive while the response is still being synthesized, without activating the microphone or playing any sound.",
                model: model, voice: voice, port: port, bearer: bearer
            ) { data, rate in
                if firstPCM == nil { firstPCM = .now }
                #expect(rate == 24_000)
                #expect(data.count <= YouziPCMFramer.maximumChunkBytes && data.count.isMultiple(of: 2))
                let samples = try YouziPCMCodec.decode(data)
                #expect(samples.allSatisfy { $0.isFinite })
                chunkCount += 1
                byteCount += data.count
            }
        }
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(120)); speech.cancel() } catch { }
        }
        defer { timeout.cancel(); speech.cancel() }
        try await speech.value
        let end = ContinuousClock.now
        let first = try #require(firstPCM)
        #expect(chunkCount > 1)
        #expect(byteCount > YouziPCMFramer.maximumChunkBytes)
        #expect(first < end)
        print("Native PCM endpoint: speed=\(client.generationDefaults.speed), chunks=\(chunkCount), bytes=\(byteCount), first_pcm=\(start.duration(to: first)), complete=\(start.duration(to: end)); no microphone/playback")

        try #require(await waitForIdle(), "The completed request must release its lane before the next test")
        var cancelChunks = 0
        let cancelled = Task { @MainActor in
            try await client.streamSpeech(
                text: "Cancel this streaming request immediately after the first PCM chunk, while the synthesizer still has more audio to generate. No audio is played.",
                model: model, voice: voice, port: port, bearer: bearer
            ) { _, _ in
                cancelChunks += 1
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        defer { cancelled.cancel() }
        do { try await cancelled.value; Issue.record("Expected native stream cancellation") }
        catch { #expect(error is CancellationError) }
        #expect(cancelChunks == 1)
        let released = try await waitForIdle()
        try #require(released, "Cancelled native request must release the resident synthesis lane")

        // Exercise the same real URLSession again: an idle health response alone
        // does not establish that consumer cancellation leaves transport usable.
        var recoveryChunks = 0
        var recoveryBytes = 0
        try await client.streamSpeech(
            text: "A fresh request succeeds after cancellation.",
            model: model, voice: voice, port: port, bearer: bearer
        ) { data, rate in
            #expect(rate == 24_000)
            #expect(!data.isEmpty && data.count <= YouziPCMFramer.maximumChunkBytes && data.count.isMultiple(of: 2))
            recoveryChunks += 1
            recoveryBytes += data.count
        }
        #expect(recoveryChunks > 0)
        #expect(recoveryBytes > 0)
        #expect(cancelChunks == 1, "Cancelled stream must never deliver late PCM into the new turn")
        #expect(try await waitForIdle(), "The fresh request must complete and release its lane")
        print("Native PCM cancellation recovery: cancelled_chunks=\(cancelChunks), fresh_chunks=\(recoveryChunks), fresh_bytes=\(recoveryBytes); same URLSession, no microphone/playback")
    }

    private func makeClient(_ plan: LivePCMProtocol.Plan) -> AudioClient {
        LivePCMProtocol.state.reset(plan)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LivePCMProtocol.self]
        return AudioClient(session: URLSession(configuration: configuration))
    }

    private func deadline(for task: Task<Void, Error>) -> Task<Void, Never> {
        Task {
            do { try await Task.sleep(for: .seconds(5)); task.cancel() }
            catch { }
        }
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw WaitTimedOut()
    }
    private struct WaitTimedOut: Error { }
}

/// Only synthetic URLProtocol traffic. No server, model, microphone or speaker.
private final class LivePCMProtocol: URLProtocol, @unchecked Sendable {
    static let headers = ["Content-Type": "audio/pcm", "X-Audio-Sample-Rate": "24000", "X-Audio-Channels": "1", "X-Audio-Format": "pcm_s16le"]
    struct Plan: Sendable {
        var status = 200
        var headers = LivePCMProtocol.headers
        var chunks: [Data]
        var holdOpen = false
    }
    struct Snapshot {
        var requests: [URLRequest] = []
        var body: Data?
        var stopped = false
        var finished = false
    }
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var plan = Plan(chunks: [])
        private var value = Snapshot()
        private var held: LivePCMProtocol?
        private var instances: Set<ObjectIdentifier> = []
        func reset(_ plan: Plan) {
            lock.lock(); defer { lock.unlock() }
            self.plan = plan; value = Snapshot(); held = nil; instances.removeAll()
        }
        func begin(_ instance: LivePCMProtocol, body: Data?) -> Plan {
            lock.lock(); defer { lock.unlock() }
            instances.insert(ObjectIdentifier(instance))
            value.requests.append(instance.request)
            if instance.request.url?.path.hasSuffix("speech") == true {
                value.body = body
                if plan.holdOpen { held = instance }
            }
            return plan
        }
        func takeHeld() -> LivePCMProtocol? {
            lock.lock(); defer { lock.unlock() }
            let instance = held; held = nil
            return instance
        }
        func markStopped(_ instance: LivePCMProtocol) {
            lock.lock(); defer { lock.unlock() }
            guard instances.contains(ObjectIdentifier(instance)) else { return }
            value.stopped = true
            if held === instance { held = nil }
        }
        func markFinished(_ instance: LivePCMProtocol) {
            lock.lock(); defer { lock.unlock() }
            guard instances.contains(ObjectIdentifier(instance)) else { return }
            value.finished = true
        }
        func snapshot() -> Snapshot { lock.lock(); defer { lock.unlock() }; return value }
    }
    static let state = State()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 1_024)
            var data = Data()
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                data.append(contentsOf: bytes.prefix(count))
            }
            body = data
        }
        let plan = Self.state.begin(self, body: body)
        if request.url!.path.hasSuffix("voices") {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"voices":["Vivian","Serena"]}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: plan.status, httpVersion: nil, headerFields: plan.headers)!, cacheStoragePolicy: .notAllowed)
        for chunk in plan.chunks { client?.urlProtocol(self, didLoad: chunk) }
        if !plan.holdOpen {
            Self.state.markFinished(self)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { Self.state.markStopped(self) }
    static func finishHeld(tail: Data) {
        guard let instance = state.takeHeld() else { return }
        instance.client?.urlProtocol(instance, didLoad: tail)
        state.markFinished(instance)
        instance.client?.urlProtocolDidFinishLoading(instance)
    }
}
