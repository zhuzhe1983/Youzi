import Foundation
import Testing
@testable import Rapid

@Suite("Youzi task filing, sharing history and security", .serialized)
@MainActor
struct YouziTaskDataSecurityTests {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("youzi-data-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("Pin, rename and archive survive selection, persistence and a fresh model")
    func taskFilingSurvivesSelectionAndRestart() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let history = root.appendingPathComponent("chat.json")
        let domainURL = root.appendingPathComponent("domain.json")
        let initial = ChatConversation(id: UUID(), title: "Original", messages: [
            ChatMessage(role: .user, content: "A request"),
            ChatMessage(role: .assistant, content: "A reply"),
        ], createdAt: Date(), updatedAt: Date())
        ConversationStore.save([initial], to: history)
        ConversationStore.flush()
        let chat = ChatViewModel(persistsConversations: true, conversationStoreURL: history)
        let product = YouziProductModel(store: YouziDomainStore(fileURL: domainURL))
        chat.setConversationLifecycleObserver(product)
        let taskID = try #require(product.tasks.first?.id)

        product.setTaskPinned(taskID, true, chat: chat)
        chat.selectConversation(initial.id)
        chat.newConversation()
        chat.selectConversation(initial.id)
        #expect(product.task(id: taskID)?.isPinned == true)
        #expect(chat.conversations.first?.isPinned == true)

        product.renameTask(taskID, to: " Renamed task ", chat: chat)
        chat.newConversation()
        chat.selectConversation(initial.id)
        #expect(product.task(id: taskID)?.title == "Renamed task")

        product.setTaskArchived(taskID, true, chat: chat)
        #expect(product.task(id: taskID)?.status == .archived)
        #expect(product.task(id: taskID)?.isPinned == false)
        chat.newConversation()
        chat.selectConversation(initial.id)
        #expect(product.task(id: taskID)?.status == .archived)
        ConversationStore.flush()

        let restartedChat = ChatViewModel(persistsConversations: true, conversationStoreURL: history)
        let restartedProduct = YouziProductModel(store: YouziDomainStore(fileURL: domainURL))
        restartedChat.setConversationLifecycleObserver(restartedProduct)
        #expect(restartedProduct.task(id: taskID)?.status == .archived)
        restartedProduct.setTaskArchived(taskID, false, chat: restartedChat)
        #expect(restartedProduct.task(id: taskID)?.status == .completed)
        #expect(restartedChat.conversations.first?.isArchived == false)
        restartedProduct.setTaskPinned(taskID, true, chat: restartedChat)
        ConversationStore.flush()
        let reloaded = ConversationStore.load(from: history)
        #expect(reloaded.first?.isPinned == true)
        #expect(reloaded.first?.title == "Renamed task")
        #expect(reloaded.first?.messages.count == 2)
        // The professional UI writes to chat, and Simple Mode sees the change.
        restartedChat.setConversationPinned(initial.id, false)
        #expect(restartedProduct.task(id: taskID)?.isPinned == false)
    }

    @Test("New settings titles stay localized when shared headings translate them again")
    func localizationIsIdempotent() {
        for (zh, en) in [("数据管理", "Data Management"), ("安全中心", "Security Center")] {
            #expect(YouziLocalization.localized(zh, isChinese: true) == zh)
            #expect(YouziLocalization.localized(en, isChinese: true) == zh)
            #expect(YouziLocalization.localized(zh, isChinese: false) == en)
            #expect(YouziLocalization.localized(en, isChinese: false) == en)
        }
    }

    @Test("Drafts without a conversation can be pinned, archived and restored")
    func draftFiling() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let product = YouziProductModel(store: YouziDomainStore(fileURL: root.appendingPathComponent("domain.json")))
        let chat = ChatViewModel(persistsConversations: false)
        let task = try #require(product.createTaskDraft(title: "Draft", request: "Hello"))
        product.setTaskPinned(task.id, true, chat: chat)
        #expect(product.task(id: task.id)?.isPinned == true)
        product.setTaskArchived(task.id, true, chat: chat)
        #expect(product.task(id: task.id)?.isPinned == false)
        product.setTaskArchived(task.id, false, chat: chat)
        #expect(product.task(id: task.id)?.status == .draft)
        product.refresh()
        #expect(product.task(id: task.id)?.request == "Hello")
    }

    @Test("Share history persists, filters and removes metadata without deleting sources")
    func shareHistoryPersistence() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.txt")
        try Data("must remain".utf8).write(to: source)
        let fileURL = root.appendingPathComponent("shares.json")
        let history = YouziShareHistory(fileURL: fileURL)
        let file = YouziShareRecord(kind: .file, sourceID: UUID(), title: "Image", service: "AirDrop")
        let task = YouziShareRecord(kind: .task, sourceID: UUID(), title: "Research", service: "Mail")
        #expect(history.record(file))
        #expect(history.record(task))
        let reopened = YouziShareHistory(fileURL: fileURL)
        #expect(reopened.records.count == 2)
        #expect(reopened.matching(kind: .file, query: " airdrop ") == [file])
        #expect(reopened.matching(kind: .task, query: "Research") == [task])
        #expect(reopened.matching(kind: .file, query: "Research").isEmpty)
        #expect(reopened.removeRecord(file.id))
        #expect(YouziShareHistory(fileURL: fileURL).records == [task])
        #expect(try String(contentsOf: source, encoding: .utf8) == "must remain")
    }

    @Test("Unreadable and future share history are never overwritten")
    func shareHistoryPreservesBadData() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("shares.json")
        for input in ["not json", "{\"version\":99,\"records\":[]}"] {
            let original = Data(input.utf8)
            try original.write(to: fileURL)
            let history = YouziShareHistory(fileURL: fileURL)
            #expect(history.lastError != nil)
            #expect(!history.record(YouziShareRecord(kind: .task, sourceID: UUID(), title: "No", service: "Mail")))
            #expect(try Data(contentsOf: fileURL) == original)
        }
    }

    @Test("Security revocation changes the live MCP gate and persists across reload")
    func revokeToolGrant() throws {
        let name = "youzi-security-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: MCPToolApprovalStore.grantKey("files__read"))
        defaults.set(true, forKey: MCPToolApprovalStore.grantKey("files__write"))
        let gate = MCPToolApprovalStore(defaults: defaults)
        #expect(gate.isGranted("files__read"))
        gate.revokeGrant(forTool: "files__read")
        #expect(!gate.isGranted("files__read"))
        #expect(gate.isGranted("files__write"))
        #expect(!MCPToolApprovalStore(defaults: defaults).isGranted("files__read"))
        gate.mode = .autoApproveAll
        #expect(gate.isGranted("files__read"))
        gate.mode = .ask
        gate.resetGrants()
        #expect(!gate.isGranted("files__write"))
        #expect(MCPToolApprovalStore(defaults: defaults).mode == .ask)
        let browse = BrowseApprovalStore(defaults: defaults)
        browse.mode = .autoApproveAll
        #expect(BrowseApprovalStore(defaults: defaults).mode == .autoApproveAll)
        browse.mode = .ask
        #expect(BrowseApprovalStore(defaults: defaults).mode == .ask)
    }
}
