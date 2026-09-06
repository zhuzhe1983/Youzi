import Foundation
import Testing
@testable import Rapid

@Suite("Compact settings and tray")
struct YouziCompactSettingsTests {
    @Test func fileCategoriesStayDiscoverable() {
        #expect(ModelFileCategory.kinds == [.chat, .audio, .image, .video])
        #expect(ModelFileCategory.title(.video, isChinese: true) == "视频")
        #expect(ModelFileCategory.title(.video, isChinese: false) == "Video")
    }
    @Test func resourceMetricsAreBoundedAndHonest() {
        #expect(YouziTraySnapshot.resourceLine(cpu: nil, gpu: .nan, memory: nil, isChinese: true) == "CPU — · GPU — · 内存 —")
        #expect(YouziTraySnapshot.resourceLine(cpu: 150, gpu: -5,
            memory: .init(totalBytes: 100, usedBytes: 75), isChinese: false) == "CPU 100% · GPU 0% · Memory 75%")
    }
    @Test func trayIncludesOnlyResidentModelsAndDeduplicatesAudio() {
        let models = ["llm", "audio", "image", "video"].map { lane in
            ResidentModelStatus(id: lane, modelPath: "org/\(lane)", aliases: [lane], modality: lane,
                state: "resident", pinned: false, primary: false, activeRequests: 0,
                estimatedBytes: 1_073_741_824, measuredBytes: nil, idleSeconds: 0)
        }
        let snapshot = ModelResidencySnapshot(memoryLimitBytes: 0, memoryUsedBytes: 0,
            memoryAvailableBytes: nil, idleTTLSeconds: 0, loadsTotal: 0, evictionsTotal: 0,
            models: models, audioLanes: [.init(lane: "tts", model: "org/audio", state: "resident"),
                .init(lane: "asr", model: "unloaded", state: "idle")])
        let lines = YouziTraySnapshot.modelLines(residency: snapshot, isChinese: true)
        #expect(lines.count == 4)
        #expect(lines.contains { $0.hasPrefix("VIDEO ·") })
        #expect(lines.contains { $0.hasPrefix("IMAGE ·") })
        #expect(!lines.contains { $0.contains("unloaded") })
        #expect(YouziTraySnapshot.modelLines(residency: .empty, isChinese: true) == ["暂无已加载模型"])
    }
    @Test func anonymousModeCannotComeFromAmbientEnvironment() {
        let strict = ServerManager.serveEnvironmentAdditions(bearer: "test-key", ambient: ["YOUZI_ALLOW_ANONYMOUS_INFERENCE": "1"])
        #expect(strict["YOUZI_ALLOW_ANONYMOUS_INFERENCE"] == nil)
        let local = ServerManager.serveEnvironmentAdditions(bearer: "test-key", allowAnonymousInference: true, ambient: [:])
        #expect(local["YOUZI_ALLOW_ANONYMOUS_INFERENCE"] == "1")
        #expect(local["RAPID_MLX_API_KEY"] == "test-key")
    }
}

@Suite("Simple transcript presentation")
struct SimpleTranscriptPresentationTests {
    @Test func noEmptyAvatars() {
        #expect(!SimpleTranscriptPresentation.isVisible(.init(role: .assistant)))
        #expect(!SimpleTranscriptPresentation.isVisible(.init(role: .assistant, content: "  \n", status: .unknown)))
        #expect(!SimpleTranscriptPresentation.isVisible(.init(role: .tool, content: "result")))
        #expect(SimpleTranscriptPresentation.isVisible(.init(role: .assistant, status: .streaming)))
        #expect(SimpleTranscriptPresentation.isVisible(.init(role: .assistant, reasoning: "thinking")))
        #expect(SimpleTranscriptPresentation.isVisible(.init(role: .assistant, status: .failed)))
    }
    @Test func legacyArtifactsOnlyAfterToolUseInTheSameTurn() {
        let call = ToolCall(id: "call", name: "browse", arguments: "{}")
        let artifact = ChatMessage(role: .assistant, content: "<tool_call><function=browse></function></tool_call>")
        let example = ChatMessage(role: .assistant, content: artifact.content)
        let messages: [ChatMessage] = [.init(role: .user, content: "research"),
            .init(role: .assistant, toolCalls: [call]), artifact,
            .init(role: .user, content: "show syntax"), example]
        #expect(SimpleTranscriptPresentation.artifactIDs(in: messages) == [artifact.id])
        #expect(SimpleTranscriptPresentation.isVisible(messages[1]))
    }
    @Test func fakeIPFailureExplainsWithoutWhitelisting() {
        #expect(SimpleTranscriptPresentation.hasFakeIPFailure(.init(role: .tool,
            content: "browse error: host 'example' resolves to a private/loopback address (198.18.25.250) and cannot be browsed", status: .failed)))
        #expect(!SimpleTranscriptPresentation.hasFakeIPFailure(.init(role: .tool,
            content: "198.18.25.250", status: .failed)))
    }
}
