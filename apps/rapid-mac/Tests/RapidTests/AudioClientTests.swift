import Foundation
import AVFoundation
import Testing
@testable import Rapid

@Suite("AudioClient wire contract", .serialized)
struct AudioClientTests {
    private func makeClient() -> AudioClient {
        AudioStubProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AudioStubProtocol.self]
        return AudioClient(session: URLSession(configuration: config))
    }

    @Test("Omitted speech parameters resolve saved voice against real model voices")
    func persistedSpeechDefaults() async throws {
        let name = "AudioDefaultsWire.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var client = makeClient()
        client.generationDefaults = ModelGenerationDefaults(defaults: defaults)
        defaults.set(["speech-model": "Serena"], forKey: ModelGenerationDefaults.Key.voices)
        defaults.set(1.25, forKey: ModelGenerationDefaults.Key.speed)
        AudioStubProtocol.response = (200, [:], Data(#"{"voices":["Vivian","Serena"]}"#.utf8))
        _ = try await client.synthesize(text: "Hello", model: "speech-model", port: 8123, bearer: "test")
        #expect(AudioStubProtocol.requests.map { $0.url?.path } == ["/v1/audio/voices", "/v1/audio/speech"])
        let body = try JSONSerialization.jsonObject(with: AudioStubProtocol.bodies.last!) as? [String: Any]
        #expect(body?["voice"] as? String == "Serena")
        #expect(body?["speed"] as? Double == 1.25)
        #expect(AudioStubProtocol.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer test" })
    }

    @MainActor
    @Test("Local narration keeps alias-keyed voice defaults while requesting the canonical model")
    func localNarrationDefaults() async throws {
        let name = "LocalNarrationDefaults.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var client = makeClient()
        client.generationDefaults = ModelGenerationDefaults(defaults: defaults)
        defaults.set(["voice-alias": "Serena"], forKey: ModelGenerationDefaults.Key.voices)
        AudioStubProtocol.response = (200, [:], Data(#"{"voices":["Vivian","Serena"]}"#.utf8))
        let entry = ModelEntry(alias: "voice-alias", hfRepo: "local/voice", sizeOnDisk: nil,
            cached: true, kind: .audio, audioCapability: .speech)
        _ = try await YouziLocalModelTools.synthesizeLocally(text: "Hello", entry: entry, voice: nil,
            port: 8123, bearer: "test", client: client)
        let data = try #require(AudioStubProtocol.bodies.last)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["model"] as? String == "local/voice")
        #expect(body["voice"] as? String == "Serena")
        #expect(AudioStubProtocol.requests.count == 2)
    }

    @MainActor
    @Test("Settings preview sends first speech request on a ready but not yet resident lazy lane")
    func settingsPreviewLazyLane() async throws {
        let client = makeClient()
        AudioStubProtocol.response = (200, ["Content-Type": "audio/wav"], Data("RIFFtest".utf8))
        let server = ServerManager(testingState: .ready(alias: "chat-model"), activeBearer: "test-bearer")
        #expect(!server.isModelResident("qwen3-tts"))
        #expect(server.isVoiceLaneReady(for: "qwen3-tts"))
        let data = try await SettingsVoicePreview.synthesizeOnReadyLane(
            server: server, alias: "qwen3-tts", text: "你好，柚子。", voice: "Vivian", speed: 1.1, client: client
        )
        #expect(data == Data("RIFFtest".utf8))
        #expect(server.servingAlias == "chat-model")
        let request = try #require(AudioStubProtocol.requests.first)
        #expect(request.url?.path == "/v1/audio/speech")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-bearer")
        let body = try JSONSerialization.jsonObject(with: #require(AudioStubProtocol.bodies.first)) as? [String: Any]
        #expect(body?["model"] as? String == "qwen3-tts")
        #expect(body?["voice"] as? String == "Vivian")
        #expect(body?["speed"] as? Double == 1.1)
    }

    @MainActor
    @Test("A language used as voice is rejected before synthesis; speaker casing is canonicalized")
    func invalidLocalNarrationVoice() async throws {
        let client = makeClient()
        AudioStubProtocol.response = (200, [:], Data(#"{"voices":["Vivian","Serena"]}"#.utf8))
        let entry = ModelEntry(alias: "voice", hfRepo: "local/voice", sizeOnDisk: nil,
            cached: true, kind: .audio, audioCapability: .speech)
        do {
            _ = try await YouziLocalModelTools.synthesizeLocally(text: "Hello", entry: entry,
                voice: "Chinese", port: 8123, bearer: nil, client: client)
            Issue.record("Invalid speaker should fail before generation")
        } catch let error as YouziLocalModelTools.Failure {
            #expect(error == .invalid_voice)
        }
        #expect(AudioStubProtocol.requests.map { $0.url?.path } == ["/v1/audio/voices"])
        _ = try await YouziLocalModelTools.synthesizeLocally(text: "Hello", entry: entry,
            voice: "vivian", port: 8123, bearer: nil, client: client)
        let body = try JSONSerialization.jsonObject(with: #require(AudioStubProtocol.bodies.last)) as? [String: Any]
        #expect(body?["voice"] as? String == "Vivian")
    }

    @Test("Transcription uploads multipart audio with model and bearer")
    @MainActor
    func transcriptionRequest() async throws {
        let client = makeClient()
        AudioStubProtocol.response = (
            200,
            ["Content-Type": "application/json"],
            Data(#"{"text":"hello world","language":"en","duration":1.25}"#.utf8)
        )
        let file = temporaryFile(name: "sample.wav", data: Data("RIFFrapid-audio".utf8))
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let result = try await client.transcribe(
            fileURL: file,
            model: "whisper-tiny",
            port: 8123,
            bearer: "secret"
        )

        #expect(result == AudioTranscriptionResult(text: "hello world", language: "en", duration: 1.25))
        let request = try #require(AudioStubProtocol.requests.first)
        #expect(request.url?.absoluteString == "http://127.0.0.1:8123/v1/audio/transcriptions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
        #expect(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)

        let body = String(decoding: try #require(AudioStubProtocol.bodies.first), as: UTF8.self)
        #expect(body.contains("name=\"model\"\r\n\r\nwhisper-tiny"))
        #expect(body.contains("name=\"response_format\"\r\n\r\njson"))
        #expect(body.contains("name=\"file\"; filename=\"input.wav\""))
        #expect(body.contains("Content-Type: audio/wav"))
        #expect(body.contains("RIFFrapid-audio"))
    }

    @Test("M4A transcription is normalized to a 16 kHz WAV upload")
    @MainActor
    func m4aTranscriptionRequest() async throws {
        let client = makeClient()
        AudioStubProtocol.response = (
            200,
            ["Content-Type": "application/json"],
            Data(#"{"text":"local m4a","language":"en","duration":0.1}"#.utf8)
        )
        let file = try temporaryM4A()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        _ = try await client.transcribe(
            fileURL: file,
            model: "whisper-medium",
            port: 8124,
            bearer: nil
        )

        let bodyData = try #require(AudioStubProtocol.bodies.first)
        let body = String(decoding: bodyData, as: UTF8.self)
        #expect(body.contains("name=\"file\"; filename=\"input.wav\""))
        #expect(body.contains("Content-Type: audio/wav"))
        #expect(bodyData.range(of: Data("RIFF".utf8)) != nil)
        #expect(bodyData.range(of: Data("WAVEfmt ".utf8)) != nil)
        let format = try wavFormat(in: bodyData)
        #expect(format.sampleRate == 16_000)
        #expect(format.channels == 1)
    }

    @Test("AIFF transcription is normalized to a 16 kHz WAV upload")
    @MainActor
    func aiffTranscriptionRequest() async throws {
        let client = makeClient()
        AudioStubProtocol.response = (
            200,
            ["Content-Type": "application/json"],
            Data(#"{"text":"local aiff","language":"en","duration":0.1}"#.utf8)
        )
        let file = try temporaryAIFF()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        _ = try await client.transcribe(
            fileURL: file,
            model: "whisper-medium",
            port: 8125,
            bearer: nil
        )

        let bodyData = try #require(AudioStubProtocol.bodies.first)
        let body = String(decoding: bodyData, as: UTF8.self)
        #expect(body.contains("name=\"file\"; filename=\"input.wav\""))
        #expect(body.contains("Content-Type: audio/wav"))
        #expect(bodyData.range(of: Data("RIFF".utf8)) != nil)
        #expect(bodyData.range(of: Data("WAVEfmt ".utf8)) != nil)
        let format = try wavFormat(in: bodyData)
        #expect(format.sampleRate == 16_000)
        #expect(format.channels == 1)
    }

    @Test("Voices sends model query and omits an empty bearer")
    @MainActor
    func voicesRequest() async throws {
        let client = makeClient()
        AudioStubProtocol.response = (
            200,
            ["Content-Type": "application/json"],
            Data(#"{"voices":["af_heart","bf_emma"]}"#.utf8)
        )

        let voices = try await client.voices(model: "kokoro", port: 8222, bearer: "")

        #expect(voices == ["af_heart", "bf_emma"])
        let request = try #require(AudioStubProtocol.requests.first)
        #expect(request.url?.path == "/v1/audio/voices")
        #expect(URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?
            .queryItems == [URLQueryItem(name: "model", value: "kokoro")])
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("Speech sends the OpenAI JSON shape and preserves WAV bytes")
    @MainActor
    func speechRequest() async throws {
        let client = makeClient()
        let wav = Data([0x52, 0x49, 0x46, 0x46, 0x01, 0x02])
        AudioStubProtocol.response = (200, ["Content-Type": "audio/wav"], wav)

        let result = try await client.synthesize(
            text: "Hello locally",
            model: "kokoro-4bit",
            voice: "af_heart",
            speed: 1.15,
            port: 8333,
            bearer: "token"
        )

        #expect(result == SynthesizedAudio(data: wav, contentType: "audio/wav"))
        let request = try #require(AudioStubProtocol.requests.first)
        #expect(request.url?.path == "/v1/audio/speech")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
        #expect(request.value(forHTTPHeaderField: "Accept") == "audio/wav")
        let body = try JSONSerialization.jsonObject(
            with: try #require(AudioStubProtocol.bodies.first)
        ) as? [String: Any]
        #expect(body?["model"] as? String == "kokoro-4bit")
        #expect(body?["input"] as? String == "Hello locally")
        #expect(body?["voice"] as? String == "af_heart")
        #expect(body?["speed"] as? Double == 1.15)
        #expect(body?["response_format"] as? String == "wav")
    }

    @Test("Voice preview uses the requested voice without changing the selection")
    @MainActor
    func voicePreview() async throws {
        let client = makeClient()
        let wav = Data([0x52, 0x49, 0x46, 0x46, 0x03, 0x04])
        AudioStubProtocol.response = (200, ["Content-Type": "audio/wav"], wav)
        let server = ServerManager(testingState: .ready(alias: "qwen3-tts-4bit"))
        let viewModel = AudioViewModel(server: server, client: client)
        viewModel.audioModels = [
            ModelEntry(
                alias: "qwen3-tts-4bit",
                hfRepo: "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-4bit",
                sizeOnDisk: "1.1 GiB",
                cached: true,
                kind: .audio,
                audioCapability: .speech,
                audioFamily: "qwen3_tts"
            )
        ]
        viewModel.selectedSpeechAlias = "qwen3-tts-4bit"
        viewModel.voices = ["Vivian", "Serena"]
        viewModel.selectedVoice = "Vivian"

        let result = await viewModel.previewVoice("Serena")

        #expect(result == SynthesizedAudio(data: wav, contentType: "audio/wav"))
        #expect(viewModel.selectedVoice == "Vivian")
        #expect(viewModel.previewingVoice == nil)
        let body = try JSONSerialization.jsonObject(
            with: try #require(AudioStubProtocol.bodies.first)
        ) as? [String: Any]
        #expect(body?["model"] as? String == "qwen3-tts-4bit")
        #expect(body?["input"] as? String == "你好，这是我的声音，很高兴认识你。")
        #expect(body?["voice"] as? String == "Serena")
    }

    @Test("Nested server detail is exposed as the user-facing failure")
    @MainActor
    func nestedServerError() async throws {
        let client = makeClient()
        AudioStubProtocol.response = (
            500,
            ["Content-Type": "application/json"],
            Data(#"{"detail":{"error":{"message":"audio runtime is unavailable"}}}"#.utf8)
        )

        do {
            _ = try await client.voices(model: "kokoro", port: 8444, bearer: nil)
            Issue.record("Expected the HTTP error")
        } catch let error as AudioClientError {
            #expect(error == .http(status: 500, message: "audio runtime is unavailable"))
            #expect(error.errorDescription == "audio runtime is unavailable")
        }
    }

    @Test("Files larger than 25 MB are rejected before transport")
    @MainActor
    func oversizedFile() async throws {
        let client = makeClient()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rapid-audio-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("large.wav")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(AudioClient.maxUploadBytes + 1))
        try handle.close()

        do {
            _ = try await client.transcribe(
                fileURL: file,
                model: "whisper-tiny",
                port: 8555,
                bearer: nil
            )
            Issue.record("Expected the file-size error")
        } catch let error as AudioClientError {
            #expect(error == .fileTooLarge(maxBytes: AudioClient.maxUploadBytes))
        }
        #expect(AudioStubProtocol.requests.isEmpty)
    }

    private func temporaryFile(name: String, data: Data) -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rapid-audio-test-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(name)
        try! data.write(to: file)
        return file
    }

    private func temporaryM4A() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rapid-audio-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("sample.m4a")
        let sampleRate = 44_100.0
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 1
        ))
        let frames: AVAudioFrameCount = 4_410
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<Int(frames) {
            samples[index] = Float(sin(2.0 * .pi * 440.0 * Double(index) / sampleRate) * 0.2)
        }
        let output = try AVAudioFile(
            forWriting: file,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000,
            ]
        )
        try output.write(from: buffer)
        return file
    }

    private func temporaryAIFF() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rapid-audio-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("sample.aiff")
        let sampleRate = 22_050.0
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 1
        ))
        let frames: AVAudioFrameCount = 2_205
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try #require(buffer.floatChannelData?[0])
        for index in 0..<Int(frames) {
            samples[index] = Float(sin(2.0 * .pi * 440.0 * Double(index) / sampleRate) * 0.2)
        }
        let output = try AVAudioFile(
            forWriting: file,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: true,
            ]
        )
        try output.write(from: buffer)
        return file
    }

    private func wavFormat(in multipartBody: Data) throws -> (sampleRate: UInt32, channels: UInt16) {
        let riff = try #require(multipartBody.range(of: Data("RIFF".utf8))?.lowerBound)
        let wave = riff + 8
        #expect(multipartBody[wave..<(wave + 4)] == Data("WAVE".utf8))

        var chunk = wave + 4
        while chunk + 8 <= multipartBody.endIndex {
            let chunkID = multipartBody[chunk..<(chunk + 4)]
            let chunkSize = Int(littleEndianUInt32(in: multipartBody, at: chunk + 4))
            let payload = chunk + 8
            guard payload + chunkSize <= multipartBody.endIndex else { break }
            if chunkID == Data("fmt ".utf8) {
                #expect(chunkSize >= 16)
                return (
                    littleEndianUInt32(in: multipartBody, at: payload + 4),
                    littleEndianUInt16(in: multipartBody, at: payload + 2)
                )
            }
            chunk = payload + chunkSize + (chunkSize % 2)
        }
        Issue.record("Uploaded WAV is missing its fmt chunk")
        throw CocoaError(.fileReadCorruptFile)
    }

    private func littleEndianUInt16(in data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private func littleEndianUInt32(in data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}

private final class AudioStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var bodies: [Data] = []
    nonisolated(unsafe) static var response: (Int, [String: String], Data) = (200, [:], Data())

    static func reset() {
        requests = []
        bodies = []
        response = (200, [:], Data())
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        Self.bodies.append(Self.readBody(from: request))
        let (status, headers, data) = Self.response
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBody(from request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
