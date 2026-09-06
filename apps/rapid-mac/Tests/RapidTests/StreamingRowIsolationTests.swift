import Foundation
import Testing
@testable import Rapid

/// Guards for the streaming transcript boundary. One `MessageRow` now spans
/// streaming and completion, while its growing prose remains store-owned.
@Suite("Streaming row isolation")
@MainActor
struct StreamingRowIsolationTests {

    private static var sourceURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // RapidTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Sources/Rapid/UI/ChatView.swift")
    }

    @Test("Streaming and completion use one message row")
    func streamingAndCompletionShareMessageRow() throws {
        let source = try String(contentsOf: Self.sourceURL, encoding: .utf8)
        #expect(!source.contains("StreamingMessageRow"))
        #expect(source.contains("ChatView.transcriptPresentationMessage(message)"))
        #expect(source.contains("StreamingTextKitMarkdownView("))

        let messageRowStart = try #require(source.range(of: "private struct MessageRow"))
        let toolChipStart = try #require(source.range(of: "struct ToolCallChip: View"))
        let messageRow = String(source[messageRowStart.lowerBound..<toolChipStart.lowerBound])

        #expect(messageRow.contains("var streamingMarkdown: StreamingMarkdownStore?"))
        #expect(messageRow.contains("StreamingTextKitMarkdownView("))
    }

    @Test("The streaming row snapshot excludes only the growing body")
    func streamingPresentationExcludesGrowingContent() {
        let id = UUID()
        let message = ChatMessage(
            id: id,
            role: .assistant,
            content: "A growing answer",
            reasoning: "Stable reasoning",
            status: .streaming,
            contentTruncated: true
        )

        let presentation = ChatView.transcriptPresentationMessage(message)

        #expect(presentation.id == id)
        #expect(presentation.content.isEmpty)
        #expect(presentation.reasoning == message.reasoning)
        #expect(presentation.status == .streaming)
        #expect(presentation.contentTruncated)

        var completed = message
        completed.status = .complete
        #expect(ChatView.transcriptPresentationMessage(completed) == completed)
    }
}
