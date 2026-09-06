import Foundation

/// Conversation-backed presentation metadata must be written to chat history
/// first. The bridge will otherwise overwrite domain-only edits on selection.
@MainActor
extension YouziProductModel {
    func setTaskPinned(_ id: UUID, _ pinned: Bool, chat: ChatViewModel) {
        guard var task = task(id: id) else { return }
        if let conversationID = task.conversationID,
           chat.conversations.contains(where: { $0.id == conversationID }) {
            chat.setConversationPinned(conversationID, pinned)
            reconcileTaskConversation(conversationID, chat: chat)
        } else {
            task.isPinned = pinned
            if pinned && task.status == .archived { task.status = .draft }
            task.updatedAt = Date()
            save(task)
        }
    }

    func setTaskArchived(_ id: UUID, _ archived: Bool, chat: ChatViewModel) {
        guard var task = task(id: id) else { return }
        if let conversationID = task.conversationID,
           chat.conversations.contains(where: { $0.id == conversationID }) {
            chat.setConversationArchived(conversationID, archived)
            reconcileTaskConversation(conversationID, chat: chat)
        } else {
            task.status = archived ? .archived : (task.completedAt == nil ? .draft : .completed)
            if archived { task.isPinned = false }
            task.updatedAt = Date()
            save(task)
        }
    }

    func renameTask(_ id: UUID, to title: String, chat: ChatViewModel) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, var task = task(id: id) else { return }
        if let conversationID = task.conversationID,
           chat.conversations.contains(where: { $0.id == conversationID }) {
            guard chat.renameConversation(conversationID, to: title) else { return }
            reconcileTaskConversation(conversationID, chat: chat)
        } else {
            task.title = title
            task.updatedAt = Date()
            save(task)
        }
    }

    private func reconcileTaskConversation(_ id: UUID, chat: ChatViewModel) {
        if let conversation = chat.conversations.first(where: { $0.id == id }) {
            conversationDidPersist(conversation)
        }
    }
}
