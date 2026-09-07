import AppKit
import Observation
import SwiftUI
import Testing
@testable import Rapid

/// Opt-in because this exercises real SwiftUI/AppKit layout on the window
/// server. Run in a bounded child process: a main-thread layout hang cannot be
/// detected by a timeout Task on that same MainActor. No microphone or service.
@MainActor
@Suite("Simple transcript layout", .serialized)
struct YouziSimpleTranscriptLayoutTests {
    @Observable final class Fixture {
        var messages: [ChatMessage] = []
        var followsReply = true
    }

    private struct Surface: View {
        let fixture: Fixture
        var body: some View {
            YouziSimpleTranscript(messages: fixture.messages, followsReply: fixture.followsReply) { message in
                HStack(alignment: .top) {
                    Text(message.role == .assistant ? "AI" : "You")
                    if message.status == .streaming || message.role == .user {
                        Text(message.content).textSelection(.enabled)
                    } else {
                        TextKitMarkdownView(content: message.content).textSelection(.enabled)
                    }
                }
            }
        }
    }

    @Test("Text → Markdown, tall rows, resizing and voice-overlay scroll suppression stay responsive",
          .enabled(if: ProcessInfo.processInfo.environment["YOUZI_TRANSCRIPT_LAYOUT_QA"] == "1"))
    func layoutTransitions() async throws {
        let fixture = Fixture()
        let host = NSHostingView(rootView: Surface(fixture: fixture))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        for turn in 0..<8 {
            fixture.followsReply = turn.isMultiple(of: 2)
            fixture.messages.append(ChatMessage(role: .user, content: "请介绍语音对话。"))
            fixture.messages.append(ChatMessage(role: .assistant, status: .streaming))
            for chunk in 0..<12 {
                fixture.messages[fixture.messages.count - 1].content += "这是流式回复的第 \(chunk) 句。\n\n"
                if chunk == 6 { window.setContentSize(NSSize(width: turn.isMultiple(of: 2) ? 560 : 900, height: 640)) }
                try await Task.sleep(for: .milliseconds(25))
                host.layoutSubtreeIfNeeded()
            }
            fixture.messages[fixture.messages.count - 1].status = .complete
            try await Task.sleep(for: .milliseconds(50))
            host.layoutSubtreeIfNeeded()
            #expect(host.bounds.height > 0)
        }
        // Exercise long persisted history, not just a single tiny bubble.
        fixture.messages += (0..<100).map { _ in ChatMessage(role: .assistant, content: "历史回复。\n\n第二段内容。") }
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        #expect(fixture.messages.count == 116)
    }
}
