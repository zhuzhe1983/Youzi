// Output-only, opt-in synthetic benchmark. Never accesses AVAudioEngine.inputNode.
// Build with the production LiveVoiceSentenceSegmenter.swift; see the runbook.
import AVFoundation
import CoreAudio
import Foundation
import Darwin

private func hostClock() -> Double { AVAudioTime.seconds(forHostTime: mach_absolute_time()) }
private enum ProbeError: Error { case failed(String) }

private final class Trace: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [[String: Any]] = []
    private var origin = hostClock()
    func begin() { lock.withLock { origin = hostClock() } }
    func event(_ name: String, segment: Int? = nil, at: Double? = nil, fields: [String: Any] = [:]) {
        let observed = hostClock()
        lock.withLock {
            var row = fields
            row["event"] = name; row["seconds"] = (at ?? observed) - origin
            row["observed_seconds"] = observed - origin
            if let segment { row["segment"] = segment }
            rows.append(row)
        }
    }
    func snapshot() -> [[String: Any]] { lock.withLock { rows } }
}

private func scalar<T>(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       _ initial: T, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput,
                       element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> T? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    guard AudioObjectHasProperty(device, &address) else { return nil }
    var value = initial; var size = UInt32(MemoryLayout<T>.size)
    let status = withUnsafeMutableBytes(of: &value) {
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0.baseAddress!)
    }
    return status == noErr ? value : nil
}

private func deviceInfo() -> [String: Any] {
    guard let device = scalar(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
                              AudioObjectID(0), scope: kAudioObjectPropertyScopeGlobal), device != 0 else { return ["available": false] }
    var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
    var name: CFString = "Unknown" as CFString; var size = UInt32(MemoryLayout<CFString>.size)
    _ = withUnsafeMutablePointer(to: &name) { AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0) }
    var info: [String: Any] = ["available": true, "id": device, "name": name as String]
    info["sample_rate"] = scalar(device, kAudioDevicePropertyNominalSampleRate, Double(0), scope: kAudioObjectPropertyScopeGlobal)
    info["buffer_frames"] = scalar(device, kAudioDevicePropertyBufferFrameSize, UInt32(0), scope: kAudioObjectPropertyScopeGlobal)
    info["device_latency_frames"] = scalar(device, kAudioDevicePropertyLatency, UInt32(0))
    info["safety_offset_frames"] = scalar(device, kAudioDevicePropertySafetyOffset, UInt32(0))
    info["mute"] = scalar(device, kAudioDevicePropertyMute, UInt32(0))
    info["volume_master"] = scalar(device, kAudioDevicePropertyVolumeScalar, Float(0))
    info["volume_left"] = scalar(device, kAudioDevicePropertyVolumeScalar, Float(0), element: 1)
    info["volume_right"] = scalar(device, kAudioDevicePropertyVolumeScalar, Float(0), element: 2)
    return info
}

// All mutable callback state is protected. Neither SDK callback inherits MainActor.
// The borrowed tap buffer is inspected synchronously and never retained or sent to a Task.
private final class OutputPlayer: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let lock = NSLock()
    private let trace: Trace
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)!
    private var outstandingFrames = 0
    private var activeSegment: Int?
    private var earliestRenderHost = Double.infinity
    private var heardSegments = Set<Int>()
    private var queueWasEmpty = false
    private var reachedEOF = false
    private(set) var info: [String: Any] = [:]

    init(trace: Trace) throws {
        self.trace = trace
        info = deviceInfo()
        guard info["available"] as? Bool == true else { throw ProbeError.failed("No output device") }
        if info["mute"] as? UInt32 == 1 && ProcessInfo.processInfo.environment["YOUZI_ALLOW_MUTED_RENDER_PROBE"] != "1" {
            throw ProbeError.failed("Output is muted; explicitly opt into render-only measurement or unmute manually")
        }
        info["acoustic_validation"] = "not performed; microphone never opened; device settings unchanged"
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        let tap: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { [weak self] buffer, when in
            self?.observe(buffer, when)
        }
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 256, format: nil, block: tap)
        engine.prepare(); try engine.start()
        info["mixer_output_presentation_latency_seconds"] = engine.mainMixerNode.outputPresentationLatency
        info["output_presentation_latency_seconds"] = engine.outputNode.outputPresentationLatency
        info["mixer_sample_rate"] = engine.mainMixerNode.outputFormat(forBus: 0).sampleRate
    }

    private func observe(_ buffer: AVAudioPCMBuffer, _ when: AVAudioTime) {
        let snapshot = lock.withLock { (activeSegment, earliestRenderHost) }
        guard let segment = snapshot.0, let channels = buffer.floatChannelData,
              when.isHostTimeValid else { return }
        let bufferStart = AVAudioTime.seconds(forHostTime: when.hostTime)
        let begin = max(0, Int(ceil((snapshot.1 - bufferStart) * buffer.format.sampleRate)))
        guard begin < Int(buffer.frameLength) else { return }
        guard !lock.withLock({ heardSegments.contains(segment) }) else { return }
        var first: Int?
        for frame in begin..<Int(buffer.frameLength) {
            for channel in 0..<Int(buffer.format.channelCount) where abs(channels[channel][frame]) > 0.001 {
                first = frame; break
            }
            if first != nil { break }
        }
        guard let first else { return }
        let fresh = lock.withLock { heardSegments.insert(segment).inserted }
        guard fresh else { return }
        let offset = Double(first) / buffer.format.sampleRate
        var fields: [String: Any] = ["threshold_dbfs": -60, "tap_frames": buffer.frameLength,
            "sample_offset_seconds": offset, "host_time_valid": when.isHostTimeValid]
        if when.isHostTimeValid {
            fields["mixer_buffer_host_seconds"] = AVAudioTime.seconds(forHostTime: when.hostTime)
            trace.event("first_nonsilent_render", segment: segment,
                        at: AVAudioTime.seconds(forHostTime: when.hostTime) + offset, fields: fields)
        } else {
            trace.event("first_nonsilent_tap_observed", segment: segment, fields: fields)
        }
    }

    func beginSegment(_ segment: Int) {
        lock.withLock { activeSegment = nil; earliestRenderHost = .infinity; reachedEOF = false; queueWasEmpty = false }
    }

    func enqueue(_ data: Data, segment: Int) async throws {
        guard !data.isEmpty, data.count.isMultiple(of: 2), data.count <= 4_800 else { throw ProbeError.failed("Invalid PCM frame") }
        let frames = data.count / 2
        // Same 100ms frames and ~1.5s pacing as production. Do not buffer a whole WAV.
        while lock.withLock({ outstandingFrames + frames > 36_000 }) {
            try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(5))
        }
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let channel = buffer.floatChannelData![0]
        data.withUnsafeBytes { raw in
            for i in 0..<frames {
                let bits = UInt16(raw[i * 2]) | UInt16(raw[i * 2 + 1]) << 8
                channel[i] = Float(Int16(bitPattern: bits)) / 32768
            }
        }
        let resumed = lock.withLock { () -> Bool in
            if activeSegment == nil { activeSegment = segment; earliestRenderHost = hostClock() }
            let resumed = queueWasEmpty
            queueWasEmpty = false; outstandingFrames += frames
            return resumed
        }
        trace.event("pcm_enqueued", segment: segment, fields: ["frames": frames])
        if resumed { trace.event("queue_refilled", segment: segment) }
        let completion: @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void = { [weak self] _ in
            guard let self else { return }
            let underrun = self.lock.withLock { () -> Bool in
                self.outstandingFrames -= frames
                let empty = self.outstandingFrames == 0 && !self.reachedEOF
                if empty { self.queueWasEmpty = true }
                return empty
            }
            self.trace.event("buffer_played_back", segment: segment, fields: ["frames": frames])
            if underrun { self.trace.event("queue_empty_before_tts_eof", segment: segment) }
        }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack, completionHandler: completion)
        if !player.isPlaying { player.play(); trace.event("player_play_called", segment: segment) }
    }

    func drain(_ segment: Int) async throws {
        lock.withLock { reachedEOF = true }
        while lock.withLock({ outstandingFrames > 0 }) {
            try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(5))
        }
        trace.event("playback_drained", segment: segment)
        // Do not call this a first-sound timestamp: dataPlayedBack is completion only.
        lock.withLock { activeSegment = nil }
        player.stop()
    }
    func stop() { engine.stop(); engine.mainMixerNode.removeTap(onBus: 0); player.stop() }
}

// Legacy-only downloader records URLSession delegate arrivals, not slow per-byte
// AsyncSequence consumption. It is deliberately bounded and never called streaming TTS.
private final class BufferedSpeechDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let trace: Trace
    private let segment: Int
    private let lock = NSLock()
    private var body = Data()
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var cancelled = false
    private var validationError: Error?
    init(trace: Trace, segment: Int) { self.trace = trace; self.segment = segment }
    func fetch(_ request: URLRequest) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let config = URLSessionConfiguration.ephemeral
                config.connectionProxyDictionary = [:]
                config.timeoutIntervalForRequest = 90
                let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
                let task = session.dataTask(with: request)
                let cancelled = lock.withLock {
                    self.continuation = continuation; self.session = session; self.task = task
                    return self.cancelled
                }
                if cancelled { task.cancel() }
                task.resume()
            }
        } onCancel: {
            let task = self.lock.withLock { self.cancelled = true; return self.task }
            task?.cancel()
        }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { completionHandler(.cancel); return }
        trace.event("tts_headers", segment: segment, fields: [
            "content_type": http.value(forHTTPHeaderField: "Content-Type") ?? "",
            "content_length": http.value(forHTTPHeaderField: "Content-Length") ?? "",
            "sample_rate": http.value(forHTTPHeaderField: "X-Audio-Sample-Rate") ?? "",
            "channels": http.value(forHTTPHeaderField: "X-Audio-Channels") ?? "",
            "format": http.value(forHTTPHeaderField: "X-Audio-Format") ?? ""])
        guard http.statusCode == 200,
              http.value(forHTTPHeaderField: "X-Audio-Sample-Rate") == "24000",
              http.value(forHTTPHeaderField: "X-Audio-Channels") == "1",
              http.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("audio/pcm") == true,
              http.value(forHTTPHeaderField: "X-Audio-Format") == nil,
              let length = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init),
              length > 0 && length <= 5_760_000 else {
            validationError = ProbeError.failed("Legacy-only PCM probe contract unavailable; no format guessing")
            completionHandler(.cancel); return
        }
        trace.event("tts_buffered_legacy", segment: segment)
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if body.isEmpty { trace.event("first_pcm_byte", segment: segment) }
        guard body.count + data.count <= 5_760_000 else {
            validationError = ProbeError.failed("Legacy PCM exceeded 120s bound"); dataTask.cancel(); return
        }
        trace.event("pcm_network_chunk", segment: segment, fields: ["bytes": data.count])
        body.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let continuation = lock.withLock { let c = self.continuation; self.continuation = nil; return c }
        defer { session.finishTasksAndInvalidate() }
        if let error = validationError ?? error { continuation?.resume(throwing: error); return }
        trace.event("tts_eof", segment: segment, fields: ["pcm_bytes": body.count, "audio_seconds": Double(body.count)/48000])
        guard !body.isEmpty && body.count.isMultiple(of: 2) else { continuation?.resume(throwing: ProbeError.failed("Empty/truncated legacy PCM")); return }
        continuation?.resume(returning: body)
    }
}

private struct Sentence: Sendable { let id: Int; let text: String }
private struct ChatEnvelope: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable { let content: String?; let reasoning_content: String?; let reasoning: String? }
        let delta: Delta; let finish_reason: String?
    }
    let choices: [Choice]?
}

@main
private enum Probe {
    static func request(_ path: String, body: [String: Any]) throws -> URLRequest {
        // Intentionally loopback-only. Credentials are optional and never saved.
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8000" + path)!)
        request.httpMethod = "POST"; request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = ProcessInfo.processInfo.environment["YOUZI_PROBE_API_KEY"] {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func main() async {
        guard ProcessInfo.processInfo.environment["YOUZI_OUTPUT_PLAYBACK_PROBE"] == "1",
              ProcessInfo.processInfo.environment["RAPID_DESKTOP_NO_PORT_SWEEP"] == "1",
              CommandLine.arguments.count == 3 else {
            print("Opt-in required: YOUZI_OUTPUT_PLAYBACK_PROBE=1 RAPID_DESKTOP_NO_PORT_SWEEP=1 probe OUTPUT_DIR RUN_LABEL")
            return
        }
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let trace = Trace()
        let prompt = "请用六句简短中文介绍李白的静夜思及其含义。每句话以句号结尾，第一句不超过十五个字。不要标题、Markdown或工具，直接讲解。"
        var result: [String: Any] = ["label": CommandLine.arguments[2], "date": ISO8601DateFormatter().string(from: Date()),
            "prompt": prompt, "chat_model": "qwen3.8-27b-4bit", "tts_model": "qwen3-tts", "voice": "vivian",
            "enable_thinking": false, "temperature": 0.3, "max_tokens": 400, "pcm_sample_rate": 24000,
            "scope": "synthetic native HTTP + production sentence segmenter + output-only AVAudioPlayerNode; no GUI/ASR/microphone/AEC",
            "clock": "mach_absolute_time converted with AVAudioTime.seconds; origin immediately before LLM POST",
            "playback_policy": "100ms PCM frames, max 1.5s queue, next sentence TTS after previous playback drains",
            "speaker_onset": "not acoustically measured; mixer first > -60dBFS sample host timestamp only"]
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let output = try OutputPlayer(trace: trace)
            defer { output.stop() }
            result["output_device"] = output.info
            let config = URLSessionConfiguration.ephemeral
            config.connectionProxyDictionary = [:]
            config.timeoutIntervalForRequest = 90
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }
            let (sentences, continuation) = AsyncStream<Sentence>.makeStream(bufferingPolicy: .bufferingOldest(64))
            let speechTask = Task { () throws -> Void in
                for await sentence in sentences {
                    try Task.checkCancellation()
                    output.beginSegment(sentence.id)
                    let req = try request("/v1/audio/speech", body: ["model": "qwen3-tts", "input": sentence.text,
                        "voice": "vivian", "speed": 1.0, "stream": true, "response_format": "pcm"])
                    trace.event("tts_request", segment: sentence.id, fields: ["text": sentence.text])
                    let allPCM: Data
                    if ProcessInfo.processInfo.environment["YOUZI_ALLOW_BUFFERED_TTS_PROBE"] == "1" {
                        allPCM = try await BufferedSpeechDownload(trace: trace, segment: sentence.id).fetch(req)
                        for offset in stride(from: 0, to: allPCM.count, by: 4_800) {
                            try await output.enqueue(allPCM.subdata(in: offset..<min(offset + 4_800, allPCM.count)), segment: sentence.id)
                        }
                    } else {
                        let (bytes, response) = try await session.bytes(for: req)
                        defer { bytes.task.cancel() }
                        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw ProbeError.failed("TTS HTTP failure") }
                        trace.event("tts_headers", segment: sentence.id)
                        guard http.value(forHTTPHeaderField: "X-Audio-Sample-Rate") == "24000",
                              http.value(forHTTPHeaderField: "X-Audio-Channels") == "1",
                              http.value(forHTTPHeaderField: "X-Audio-Format") == "pcm_s16le" else { throw ProbeError.failed("Streaming PCM contract unavailable; no silent fallback") }
                        trace.event("tts_stream_contract", segment: sentence.id)
                        var frame = Data(); var received = Data(); var first = true
                        for try await byte in bytes {
                            if first { trace.event("first_pcm_byte", segment: sentence.id); first = false }
                            guard received.count + frame.count < 5_760_000 else { throw ProbeError.failed("PCM response exceeded 120s bound") }
                            frame.append(byte)
                            if frame.count == 4_800 {
                                received.append(frame)
                                try await output.enqueue(frame, segment: sentence.id)
                                frame = Data()
                            }
                        }
                        trace.event("tts_eof", segment: sentence.id, fields: ["pcm_bytes": received.count + frame.count,
                            "audio_seconds": Double(received.count + frame.count) / 48000])
                        guard !first, frame.count.isMultiple(of: 2) else { throw ProbeError.failed("Empty/truncated PCM") }
                        if !frame.isEmpty { received.append(frame); try await output.enqueue(frame, segment: sentence.id) }
                        allPCM = received
                    }
                    try allPCM.write(to: folder.appendingPathComponent("sentence-\(sentence.id).pcm"))
                    try await output.drain(sentence.id)
                }
            }
            do {
                let req = try request("/v1/chat/completions", body: ["model": "qwen3.8-27b-4bit", "stream": true,
                    "messages": [["role": "user", "content": prompt]], "max_tokens": 400, "temperature": 0.3,
                    "stream_options": ["include_usage": true], "chat_template_kwargs": ["enable_thinking": false]])
                trace.begin(); trace.event("llm_request")
                let (bytes, response) = try await session.bytes(for: req)
                defer { bytes.task.cancel() }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw ProbeError.failed("LLM HTTP failure") }
                trace.event("llm_headers")
                var segmenter = LiveVoiceSentenceSegmenter()
                var text = ""; var count = 0; var reasonChars = 0; var finishReason: String?
                func emit(_ utterances: [String]) throws {
                    for text in utterances {
                        count += 1
                        trace.event("sentence_ready", segment: count, fields: ["text": text])
                        guard case .enqueued = continuation.yield(Sentence(id: count, text: text)) else { throw ProbeError.failed("Sentence queue full/closed") }
                    }
                }
                for try await line in bytes.lines {
                    guard line.hasPrefix("data: ") else { continue }
                    let raw = String(line.dropFirst(6))
                    if raw == "[DONE]" { trace.event("llm_done"); break }
                    let data = Data(raw.utf8)
                    let envelope = try JSONDecoder().decode(ChatEnvelope.self, from: data)
                    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    if object?["error"] != nil { throw ProbeError.failed("LLM stream error") }
                    if let usage = object?["usage"], !(usage is NSNull) { result["usage"] = usage }
                    for choice in envelope.choices ?? [] {
                        reasonChars += (choice.delta.reasoning_content ?? choice.delta.reasoning ?? "").count
                        if let delta = choice.delta.content, !delta.isEmpty {
                            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !delta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { trace.event("first_text") }
                            text += delta
                            try emit(segmenter.append(delta))
                        }
                        if let reason = choice.finish_reason { finishReason = reason; trace.event("llm_finish_reason", fields: ["reason": reason]) }
                    }
                }
                try emit(segmenter.finish())
                result["llm_text"] = text; result["reasoning_characters"] = reasonChars
                result["finish_reason"] = finishReason; result["sentence_count"] = count
                continuation.finish()
                try await speechTask.value
                guard count > 0, finishReason == "stop" else { throw ProbeError.failed("LLM incomplete or no sentence") }
                trace.event("run_complete"); result["status"] = "completed"
            } catch {
                continuation.finish(); speechTask.cancel(); session.invalidateAndCancel()
                _ = try? await speechTask.value
                throw error
            }
        } catch {
            result["status"] = "failed"; result["error"] = String(describing: error)
        }
        result["events"] = trace.snapshot()
        result["probe_revision"] = "delegate-arrivals-v2-tap-epoch-gate"
        result["tts_transport_mode"] = trace.snapshot().contains { $0["event"] as? String == "tts_buffered_legacy" } ? "buffered_legacy" : "strict_stream_contract"
        result["streaming_generation_verified"] = false // A contract/header alone is not a latency proof.
        do {
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: folder.appendingPathComponent("results.json"))
            print("\(result["status"] ?? "unknown"): \(folder.appendingPathComponent("results.json").path)")
            if result["status"] as? String != "completed" { exit(1) }
        } catch { print("Failed to save benchmark results") }
    }
}
