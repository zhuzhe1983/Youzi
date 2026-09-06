import Foundation

/// Render-only cleanup for persisted transcripts, including older builds that
/// saved raw final-round calls as successful prose. No history is rewritten.
enum SimpleTranscriptPresentation {
    static func isVisible(_ message: ChatMessage) -> Bool {
        guard message.role != .tool else { return false }
        guard message.role == .assistant else { return true }
        return (message.status == .streaming || message.status == .failed) || !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !(message.toolCalls?.isEmpty ?? true) || !message.reasoning.isEmpty
            || message.errorMessage != nil || message.wireVisibility == .transcriptOnly
    }

    static func artifactIDs(in messages: [ChatMessage]) -> Set<UUID> {
        var hadToolCalls = false
        var result: Set<UUID> = []
        for message in messages {
            if message.role == .user { hadToolCalls = false }
            if message.role == .assistant, !(message.toolCalls?.isEmpty ?? true) { hadToolCalls = true }
            if message.role == .assistant, (message.toolCalls?.isEmpty ?? true),
               (hadToolCalls || message.toolCallArtifactSuppressed),
               ChatMessage.contentLooksLikeToolCallArtifact(message.content) {
                result.insert(message.id)
            }
        }
        return result
    }

    static func hasFakeIPFailure(_ message: ChatMessage) -> Bool {
        message.role == .tool && message.status == .failed
            && message.content.contains("resolves to a private/loopback address")
            && (message.content.contains("(198.18.") || message.content.contains("(198.19."))
    }
}
