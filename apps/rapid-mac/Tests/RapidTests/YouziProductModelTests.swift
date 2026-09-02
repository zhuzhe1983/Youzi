import Foundation
import Testing
@testable import Rapid

@Suite("YouziProductModel — single observable lifecycle owner")
@MainActor
struct YouziProductModelTests {
    @Test("Draft execution links one conversation and allocates workspace at execution only")
    func executionBoundary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("youzi-product-model-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = YouziDomainStore(fileURL: root.appendingPathComponent("domain.json"))
        let access = YouziWorkspaceAccessCoordinator(
            managedRoot: root.appendingPathComponent("workspaces")
        )
        let files = YouziManagedFileStore(
            root: root.appendingPathComponent("files"),
            workspaceAccess: access
        )
        let model = YouziProductModel(
            store: store,
            workspaceAccess: access,
            fileStore: files
        )

        let draft = try #require(model.createTaskDraft(title: "Draft", request: "Do it"))
        #expect(draft.workspaceID == nil)
        let conversationID = UUID()
        let workspace = try #require(
            model.beginTaskExecution(taskID: draft.id, conversationID: conversationID)
        )
        let executing = try #require(model.task(id: draft.id))
        #expect(executing.workspaceID == workspace.id)
        #expect(executing.conversationID == conversationID)
        #expect(executing.status == .inProgress)

        let conversation = ChatConversation(
            id: conversationID,
            title: "Completed",
            messages: [
                ChatMessage(role: .user, content: "Do it"),
                ChatMessage(role: .assistant, content: "Done"),
            ],
            createdAt: executing.createdAt,
            updatedAt: executing.updatedAt.addingTimeInterval(1)
        )
        model.conversationDidPersist(conversation)
        #expect(model.task(id: draft.id)?.status == .completed)
        #expect(model.tasks.count == 1)
    }
}
