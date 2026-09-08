import Foundation
import Testing
@testable import Rapid

@Suite("Chat multimodal artifact receipts")
struct YouziChatArtifactTests {
    func receipt(_ artifact: YouziArtifact, callID: String = "image-call") -> ChatMessage {
        ChatMessage(role: .tool, content: """
        {"saved":true,"artifact_id":"\(artifact.id)","file_id":"\(artifact.fileID)","filename":"ignored","location":"ignored"}
        """, toolCallID: callID)
    }

    @Test("All media and HTML resolve from persisted receipts without assistant follow-up", arguments: [
        ("youzi_generate_image", YouziArtifactKind.image),
        ("youzi_synthesize_speech", .audio),
        ("youzi_generate_video", .video),
        ("youzi_create_storybook", .document)
    ])
    func persistedReceipt(tool: String, kind: YouziArtifactKind) throws {
        let artifact = YouziArtifact(taskID: UUID(), title: "Generated file", kind: kind, fileID: UUID())
        let call = ToolCall(id: "image-call", name: tool, arguments: "{}")
        let result = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(receipt(artifact)))
        let resolved = YouziChatArtifactReceipt.resolve(call: call, result: result, taskID: artifact.taskID) { $0 == artifact.id ? artifact : nil }
        #expect(resolved == artifact)
    }

    @Test("Only matching successful tool receipts can reference current-task files")
    func rejectsUntrustedReferences() {
        let artifact = YouziArtifact(taskID: UUID(), title: "Output", kind: .image, fileID: UUID())
        let call = ToolCall(id: "image-call", name: "youzi_generate_image", arguments: "{}")
        func resolve(_ result: ChatMessage?, _ tool: ToolCall? = nil, taskID: UUID? = nil, record: YouziArtifact? = nil) -> YouziArtifact? {
            YouziChatArtifactReceipt.resolve(call: tool ?? call, result: result, taskID: taskID ?? artifact.taskID) { $0 == artifact.id ? record ?? artifact : nil }
        }
        #expect(resolve(nil) == nil)
        #expect(resolve(receipt(artifact, callID: "other-call")) == nil)
        #expect(resolve(receipt(artifact), taskID: UUID()) == nil)
        #expect(resolve(receipt(artifact), ToolCall(id: call.id, name: "external_tool", arguments: "{}")) == nil)
        var modified = artifact; modified.fileID = UUID()
        #expect(resolve(receipt(artifact), record: modified) == nil)
        modified = artifact; modified.kind = .audio
        #expect(resolve(receipt(artifact), record: modified) == nil)
        var result = ChatMessage(role: .assistant, content: receipt(artifact).content, toolCallID: call.id)
        #expect(resolve(result) == nil)
        result = receipt(artifact); result.status = .streaming
        #expect(resolve(result) == nil)
        result = receipt(artifact); result.status = .failed
        #expect(resolve(result) == nil)
        result = receipt(artifact); result.failureKind = .toolFailed
        #expect(resolve(result) == nil)
        result = receipt(artifact); result.content = result.content.replacingOccurrences(of: "true", with: "false")
        #expect(resolve(result) == nil)
        result = receipt(artifact); result.content = #"{"url":"file:///private/secret"}"#
        #expect(resolve(result) == nil)
        result.content = String(repeating: "x", count: 128_001)
        #expect(resolve(result) == nil)
    }

    @Test("Deleted or unavailable records can retain a non-playable history card")
    func unavailableReceipt() {
        var artifact = YouziArtifact(taskID: UUID(), title: "Removed output", kind: .image, fileID: UUID())
        artifact.state = .unavailable
        let call = ToolCall(id: "image-call", name: "youzi_generate_image", arguments: "{}")
        #expect(YouziChatArtifactReceipt.resolve(call: call, result: receipt(artifact), taskID: artifact.taskID) { _ in artifact } == artifact)
        #expect(YouziChatArtifactReceipt.resolve(call: call, result: receipt(artifact), taskID: artifact.taskID) { _ in nil } == nil)
    }
}
