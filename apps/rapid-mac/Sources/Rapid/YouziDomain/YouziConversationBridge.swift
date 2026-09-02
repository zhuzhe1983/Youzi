import Foundation

/// Narrow lifecycle seam owned by ChatViewModel. It reports canonical history
/// writes and explicit deletion, never conversation-folder presentation state.
@MainActor
protocol ChatConversationLifecycleObserver: AnyObject {
    func conversationHistoryDidLoad(_ conversations: [ChatConversation])
    func conversationDidPersist(_ conversation: ChatConversation)
    func conversationWasDeleted(id: UUID)
}

/// Reconciles the canonical conversation store into additive task metadata.
/// Absence from a loaded array is never interpreted as deletion: only the
/// explicit delete event detaches a task, protecting domain data from a failed
/// or empty conversation-store read.
final class YouziConversationBridge: @unchecked Sendable {
    private let store: YouziDomainStore

    init(store: YouziDomainStore) {
        self.store = store
    }

    @discardableResult
    func reconcile(_ conversations: [ChatConversation]) throws -> YouziDomainDocument {
        guard !conversations.isEmpty else { return try store.load() }
        return try store.update { document in
            for conversation in conversations {
                if let index = document.tasks.firstIndex(where: {
                    $0.conversationID == conversation.id
                }) {
                    var task = document.tasks[index]
                    task.title = conversation.title
                    task.request = Self.initialRequest(in: conversation)
                    task.status = Self.status(for: conversation)
                    task.failureSummary = Self.failureSummary(in: conversation)
                    task.isPinned = conversation.isPinned
                    task.updatedAt = conversation.updatedAt
                    task.completedAt = task.status == .completed ? conversation.updatedAt : nil
                    document.tasks[index] = task
                } else {
                    // Conversation and task share an identity when possible,
                    // making startup reconciliation naturally idempotent.
                    let taskID = document.tasks.contains(where: { $0.id == conversation.id })
                        ? UUID()
                        : conversation.id
                    document.tasks.append(
                        YouziTask(
                            id: taskID,
                            title: conversation.title,
                            request: Self.initialRequest(in: conversation),
                            conversationID: conversation.id,
                            status: Self.status(for: conversation),
                            failureSummary: Self.failureSummary(in: conversation),
                            isPinned: conversation.isPinned,
                            createdAt: conversation.createdAt,
                            updatedAt: conversation.updatedAt,
                            completedAt: Self.status(for: conversation) == .completed
                                ? conversation.updatedAt
                                : nil
                        )
                    )
                }
            }
        }
    }

    @discardableResult
    func detachDeletedConversation(id: UUID, at date: Date = Date()) throws
        -> YouziDomainDocument
    {
        try store.update { document in
            for index in document.tasks.indices
            where document.tasks[index].conversationID == id {
                document.tasks[index].conversationID = nil
                document.tasks[index].status = .archived
                document.tasks[index].isPinned = false
                document.tasks[index].updatedAt = date
            }
        }
    }

    private static func initialRequest(in conversation: ChatConversation) -> String {
        conversation.messages.first(where: { $0.role == .user })?.content ?? ""
    }

    private static func status(for conversation: ChatConversation) -> YouziTaskStatus {
        if conversation.isArchived { return .archived }
        guard let last = conversation.messages.last else { return .draft }
        if last.role == .assistant, last.status == .failed { return .failed }
        if last.status == .streaming || last.role == .user { return .inProgress }
        return conversation.messages.contains(where: { $0.role == .assistant })
            ? .completed
            : .draft
    }

    private static func failureSummary(in conversation: ChatConversation) -> String? {
        guard let message = conversation.messages.last,
              message.role == .assistant,
              message.status == .failed
        else { return nil }
        let normalized = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? "Assistant response failed" : normalized
    }
}
