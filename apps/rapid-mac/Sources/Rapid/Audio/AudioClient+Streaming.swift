import Foundation

// Both stored values are Sendable: URLSession and ModelGenerationDefaults
// (the latter wraps synchronized UserDefaults). Swift requires @unchecked for
// conformance outside the type's original file; no mutable reference cache is
// introduced here. Re-audit if AudioClient gains additional stored properties.
extension AudioClient: @unchecked Sendable {
    /// Incremental mono PCM, not a buffered WAV response. Awaiting the consumer
    /// bounds application-owned framing and lets a caller apply backpressure.
    func streamSpeech(
        text: String,
        model: String,
        voice: String?,
        port: Int,
        bearer: String?,
        onChunk: @escaping @MainActor (Data, Double) async throws -> Void
    ) async throws {
        do {
            try Task.checkCancellation()
            guard (1...65535).contains(port) else { throw AudioClientError.invalidResponse }
            let resolvedVoice: String
            if let voice, !voice.isEmpty {
                resolvedVoice = voice
            } else {
                let available = try await voices(model: model, port: port, bearer: bearer)
                guard let preferred = generationDefaults.voice(for: model, available: available) else {
                    throw AudioClientError.invalidResponse
                }
                resolvedVoice = preferred
            }
            try Task.checkCancellation()
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/audio/speech")!)
            request.httpMethod = "POST"
            request.timeoutInterval = Self.requestTimeout
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("audio/pcm", forHTTPHeaderField: "Accept")
            request.setValue("24000", forHTTPHeaderField: "X-Audio-Sample-Rate")
            request.setValue("1", forHTTPHeaderField: "X-Audio-Channels")
            request.setValue("pcm_s16le", forHTTPHeaderField: "X-Audio-Format")
            if let bearer, !bearer.isEmpty {
                request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
            }
            request.httpBody = try JSONEncoder().encode(StreamingSpeechBody(
                model: model, input: text, voice: resolvedVoice, speed: generationDefaults.speed
            ))

            let (bytes, response) = try await session.bytes(for: request)
            // Early validation, consumer failure and cancellation must all close
            // the request, including while the consumer is suspended off-network.
            defer { bytes.task.cancel() }
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse else {
                    throw AudioClientError.invalidResponse
                }
                guard (200...299).contains(http.statusCode) else {
                    var errorBody = Data()
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        errorBody.append(byte)
                        if errorBody.count == 8_192 { break }
                    }
                    throw AudioClientError.http(status: http.statusCode, message: Self.errorMessage(from: errorBody))
                }
                let sampleRate = try Self.streamingSampleRate(from: http)
                var framer = YouziPCMFramer()
                var delivered = false
                for try await byte in bytes {
                    try Task.checkCancellation()
                    if let frame = framer.append(byte) {
                        try await onChunk(frame, sampleRate)
                        try Task.checkCancellation()
                        delivered = true
                    }
                }
                try Task.checkCancellation()
                if let tail = try framer.finish() {
                    try await onChunk(tail, sampleRate)
                    try Task.checkCancellation()
                    delivered = true
                }
                guard delivered else { throw AudioClientError.emptyAudio }
            } onCancel: {
                bytes.task.cancel()
            }
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            if let transport = error as? URLError {
                throw AudioClientError.transport(transport.localizedDescription)
            }
            // In particular, preserve the consumer's typed queue-full error.
            throw error
        }
    }

    static func streamingSampleRate(from response: HTTPURLResponse) throws -> Double {
        func header(_ name: String) -> String? {
            response.value(forHTTPHeaderField: name)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        guard header("X-Audio-Sample-Rate").flatMap(Double.init) == 24_000,
              header("X-Audio-Channels") == "1",
              header("X-Audio-Format") == "pcm_s16le" else {
            throw AudioClientError.invalidResponse
        }
        return 24_000
    }
}

private struct StreamingSpeechBody: Encodable {
    let model: String
    let input: String
    let voice: String
    let speed: Double
    let stream = true
    let response_format = "pcm"
}

/// A byte stream can split even a single s16le sample across network packets.
/// Hold at most 100 ms (4,800 bytes) and never publish a half sample. A truncated
/// final sample is a protocol error, not silently padded or played as noise.
struct YouziPCMFramer {
    static let maximumChunkBytes = 4_800
    let chunkBytes: Int
    private var pending = Data()
    var bufferedByteCount: Int { pending.count }

    init(chunkBytes: Int = Self.maximumChunkBytes) {
        precondition(chunkBytes > 0 && chunkBytes <= Self.maximumChunkBytes && chunkBytes.isMultiple(of: 2))
        self.chunkBytes = chunkBytes
        pending.reserveCapacity(chunkBytes)
    }

    mutating func append(_ byte: UInt8) -> Data? {
        pending.append(byte)
        guard pending.count == chunkBytes else { return nil }
        let frame = pending
        pending = Data()
        pending.reserveCapacity(chunkBytes)
        return frame
    }

    mutating func finish() throws -> Data? {
        guard pending.count.isMultiple(of: 2) else { throw AudioClientError.invalidResponse }
        guard !pending.isEmpty else { return nil }
        let tail = pending
        pending = Data()
        return tail
    }
}
