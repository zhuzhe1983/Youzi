import SwiftUI

/// These rows can change from SwiftUI Text to AppKit-backed Markdown at the
/// end of a stream. The live-voice hang sample was dominated by SwiftUI's lazy
/// placement/graph updates, blocking UI and MainActor audio consumers. Keep row
/// geometry stable and move scroll requests out of the current transaction as
/// a mitigation; an attended reproduction is still needed to confirm the exact
/// interaction that triggered the incident.
struct YouziSimpleTranscript<Row: View>: View {
    let messages: [ChatMessage]
    var followsReply = true
    @ViewBuilder let row: (ChatMessage) -> Row

    private struct ScrollRequest: Equatable {
        let id: UUID?
        let text: String?
        let status: ChatMessage.Status?
        let followsReply: Bool
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // An eager stack keeps AppKit-backed rows mounted with stable
                // geometry instead of repeatedly recycling variable-height rows.
                VStack(alignment: .leading, spacing: RapidTheme.Space.xl) {
                    ForEach(messages) { message in
                        row(message).id(message.id)
                    }
                }
                .frame(maxWidth: RapidTheme.Layout.contentMaxWidth)
                .frame(maxWidth: .infinity)
                .padding(RapidTheme.Space.xl)
            }
            .task(id: ScrollRequest(id: messages.last?.id, text: messages.last?.content,
                                    status: messages.last?.status, followsReply: followsReply)) {
                guard followsReply, let id = messages.last?.id else { return }
                // Let the current layout transaction finish first. SwiftUI
                // cancels stale requests when content/view identity changes.
                do { try await Task.sleep(for: .milliseconds(16)) }
                catch { return }
                guard !Task.isCancelled else { return }
                proxy.scrollTo(id, anchor: .bottom)
            }
        }
    }
}
