import Foundation
import Testing
@testable import Rapid

@Suite("YouziConversationBridge — additive reconciliation")
struct YouziConversationBridgeTests {
    @MainActor
    private final class ObserverProbe: ChatConversationLifecycleObserver {
        let storeURL: URL
        var loaded: [ChatConversation] = []
        var persisted: [ChatConversation] = []
        var persistedWasOnDisk = false
        var deletedID: UUID?
        var deletionWasOnDisk = false

        init(storeURL: URL) { self.storeURL = storeURL }

        func conversationHistoryDidLoad(_ conversations: [ChatConversation]) {
            loaded = conversations
        }

        func conversationDidPersist(_ conversation: ChatConversation) {
            persisted.append(conversation)
            ConversationStore.flush()
            persistedWasOnDisk = ConversationStore.load(from: storeURL).contains {
                $0.id == conversation.id && $0.title == conversation.title
                    && $0.isArchived == conversation.isArchived
            }
        }

        func conversationWasDeleted(id: UUID) {
            deletedID = id
            ConversationStore.flush()
            deletionWasOnDisk = !ConversationStore.load(from: storeURL).contains { $0.id == id }
        }
    }

    private func conversation(
        id: UUID = UUID(),
        title: String = "Research",
        archived: Bool = false,
        assistantStatus: ChatMessage.Status = .complete
    ) -> ChatConversation {
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        return ChatConversation(
            id: id,
            title: title,
            messages: [
                ChatMessage(role: .user, content: "Find the answer", createdAt: created),
                ChatMessage(
                    role: .assistant,
                    content: assistantStatus == .failed ? "Network unavailable" : "Answer",
                    status: assistantStatus,
                    createdAt: created.addingTimeInterval(1)
                ),
            ],
            createdAt: created,
            updatedAt: created.addingTimeInterval(2),
            isPinned: true,
            isArchived: archived,
            folderID: UUID()
        )
    }

    @Test("Conversation changes upsert tasks while preserving independent domain links")
    func reconcilePreservesDomainData() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("youzi-bridge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = YouziDomainStore(fileURL: root.appendingPathComponent("domain.json"))
        let bridge = YouziConversationBridge(store: store)
        let initial = conversation()

        var document = try bridge.reconcile([initial])
        #expect(document.tasks.count == 1)
        #expect(document.tasks[0].id == initial.id)
        #expect(document.tasks[0].request == "Find the answer")
        #expect(document.tasks[0].status == .completed)
        #expect(document.projects.isEmpty) // A conversation folder is never a project.

        let workspaceID = UUID()
        document.tasks[0].workspaceID = workspaceID
        document.tasks[0].inputFileIDs = [UUID()]
        try store.save(document)
        let renamed = conversation(id: initial.id, title: "Renamed")
        let updated = try bridge.reconcile([renamed])
        #expect(updated.tasks.count == 1)
        #expect(updated.tasks[0].title == "Renamed")
        #expect(updated.tasks[0].workspaceID == workspaceID)
        #expect(updated.tasks[0].inputFileIDs == document.tasks[0].inputFileIDs)

        let afterEmptyLoad = try bridge.reconcile([])
        #expect(afterEmptyLoad == updated)
        let detached = try bridge.detachDeletedConversation(id: initial.id)
        #expect(detached.tasks[0].conversationID == nil)
        #expect(detached.tasks[0].status == .archived)
        #expect(detached.tasks[0].workspaceID == workspaceID)
        #expect(detached.tasks[0].inputFileIDs == document.tasks[0].inputFileIDs)
    }

    @Test("Failure and archive states reconcile idempotently")
    func stateMappingIsIdempotent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("youzi-bridge-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bridge = YouziConversationBridge(
            store: YouziDomainStore(fileURL: root.appendingPathComponent("domain.json"))
        )
        let failed = conversation(assistantStatus: .failed)
        let first = try bridge.reconcile([failed])
        let second = try bridge.reconcile([failed])
        #expect(first == second)
        #expect(first.tasks[0].status == .failed)
        #expect(first.tasks[0].failureSummary == "Network unavailable")

        let archived = conversation(id: failed.id, archived: true)
        let final = try bridge.reconcile([archived])
        #expect(final.tasks[0].status == .archived)
        #expect(final.tasks[0].isPinned)
    }

    @Test("Chat observer bulk-loads additively and reports mutations after canonical saves")
    @MainActor
    func chatObserverOrderingAndFolderUnarchive() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("youzi-chat-observer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let historyURL = root.appendingPathComponent("conversations.json")
        let initial = conversation()
        ConversationStore.save([initial], to: historyURL)
        ConversationStore.flush()
        let chat = ChatViewModel(
            persistsConversations: true,
            conversationStoreURL: historyURL
        )
        let probe = ObserverProbe(storeURL: historyURL)

        chat.setConversationLifecycleObserver(probe)
        #expect(probe.loaded.map(\.id) == [initial.id])

        #expect(chat.renameConversation(initial.id, to: "Renamed"))
        #expect(probe.persistedWasOnDisk)
        chat.setConversationArchived(initial.id, true)
        #expect(probe.persisted.last?.isArchived == true)
        let folder = try #require(chat.createFolder(named: "Folder"))
        chat.moveConversation(initial.id, toFolder: folder.id)
        #expect(probe.persisted.last?.isArchived == false)
        #expect(probe.persistedWasOnDisk)

        chat.deleteConversation(initial.id)
        #expect(probe.deletedID == initial.id)
        #expect(probe.deletionWasOnDisk)
    }
}
