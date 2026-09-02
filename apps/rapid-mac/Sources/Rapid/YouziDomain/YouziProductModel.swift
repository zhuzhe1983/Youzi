import Foundation
import Observation

/// The one app-owned observable projection of durable Youzi metadata. Views
/// receive this instance through SwiftUI environment injection; no screen
/// constructs a competing store or shadows persisted objects with fixtures.
@MainActor
@Observable
final class YouziProductModel: ChatConversationLifecycleObserver {
    private(set) var document: YouziDomainDocument
    private(set) var lastPersistenceError: String?

    @ObservationIgnored private let store: YouziDomainStore
    @ObservationIgnored private let conversationBridge: YouziConversationBridge
    @ObservationIgnored private let lifecycle: YouziLifecycleRepository

    init(
        store: YouziDomainStore = YouziDomainStore(),
        workspaceAccess: YouziWorkspaceAccessCoordinator = YouziWorkspaceAccessCoordinator(),
        fileStore: YouziManagedFileStore? = nil
    ) {
        self.store = store
        self.conversationBridge = YouziConversationBridge(store: store)
        self.lifecycle = YouziLifecycleRepository(
            store: store,
            workspaceAccess: workspaceAccess,
            fileStore: fileStore
        )
        do {
            self.document = try store.load()
            self.lastPersistenceError = nil
        } catch {
            // Never overwrite unreadable/unsupported storage. The model stays
            // usable for diagnosis while each attempted transaction continues
            // to fail against the preserved source.
            self.document = .empty
            self.lastPersistenceError = error.localizedDescription
        }
    }

    var tasks: [YouziTask] { document.tasks }
    var workspaces: [YouziWorkspace] { document.workspaces }
    var projects: [YouziProject] { document.projects }
    var files: [YouziFile] { document.files }
    var artifacts: [YouziArtifact] { document.artifacts }
    var templates: [YouziTemplate] { document.templates }

    func task(id: UUID) -> YouziTask? { document.tasks.first { $0.id == id } }
    func workspace(id: UUID) -> YouziWorkspace? { document.workspaces.first { $0.id == id } }
    func project(id: UUID) -> YouziProject? { document.projects.first { $0.id == id } }
    func file(id: UUID) -> YouziFile? { document.files.first { $0.id == id } }
    func artifact(id: UUID) -> YouziArtifact? { document.artifacts.first { $0.id == id } }
    func template(id: UUID) -> YouziTemplate? { document.templates.first { $0.id == id } }
    func file(for artifact: YouziArtifact) -> YouziFile? { file(id: artifact.fileID) }

    func refresh() {
        capture { try store.load() }
    }

    /// Creates an editable draft only. Execution and managed-workspace
    /// allocation are deliberately separate lifecycle operations.
    @discardableResult
    func createTaskDraft(
        title: String,
        request: String,
        projectID: UUID? = nil,
        helperID: UUID? = nil,
        skillIDs: [UUID] = [],
        at date: Date = Date()
    ) -> YouziTask? {
        let task = YouziTask(
            title: title,
            request: request,
            projectID: projectID,
            helperID: helperID,
            skillIDs: skillIDs,
            status: .draft,
            createdAt: date,
            updatedAt: date
        )
        capture {
            try store.update { $0.upsert(task) }
        }
        return lastPersistenceError == nil ? task : nil
    }

    @discardableResult
    func createTaskDraft(from template: YouziTemplate, at date: Date = Date()) -> YouziTask? {
        createTaskDraft(
            title: template.name,
            request: template.prefilledRequest,
            helperID: template.recommendedHelperID,
            skillIDs: template.recommendedSkillIDs,
            at: date
        )
    }

    func save(_ task: YouziTask) {
        capture { try store.update { $0.upsert(task) } }
    }

    func save(_ project: YouziProject) {
        capture { try store.update { $0.upsert(project) } }
    }

    @discardableResult
    func createProject(
        name: String,
        summary: String = "",
        instructions: String = "",
        at date: Date = Date()
    ) -> YouziProject? {
        captureValue {
            try lifecycle.createProject(
                name: name,
                summary: summary,
                instructions: instructions,
                at: date
            )
        }
    }

    @discardableResult
    func createManagedWorkspace(name: String, at date: Date = Date()) -> YouziWorkspace? {
        captureValue { try lifecycle.createManagedWorkspace(name: name, at: date) }
    }

    @discardableResult
    func createBookmarkedWorkspace(
        name: String,
        directoryURL: URL,
        at date: Date = Date()
    ) -> YouziWorkspace? {
        captureValue {
            try lifecycle.createBookmarkedWorkspace(
                name: name,
                directoryURL: directoryURL,
                at: date
            )
        }
    }

    func assignWorkspace(_ workspaceID: UUID?, toTask taskID: UUID, at date: Date = Date()) {
        capture { try lifecycle.assignWorkspace(workspaceID, toTask: taskID, at: date) }
    }

    @discardableResult
    func ensureWorkspaceForExecution(taskID: UUID, at date: Date = Date()) -> YouziWorkspace? {
        captureValue { try lifecycle.ensureManagedWorkspace(forTask: taskID, at: date) }
    }

    func moveTask(_ taskID: UUID, toProject projectID: UUID?, at date: Date = Date()) {
        capture { try lifecycle.moveTask(taskID, toProject: projectID, at: date) }
    }

    @discardableResult
    func beginTaskExecution(
        taskID: UUID,
        conversationID: UUID,
        at date: Date = Date()
    ) -> YouziWorkspace? {
        captureValue {
            try lifecycle.beginExecution(
                taskID: taskID,
                conversationID: conversationID,
                at: date
            )
        }
    }

    @discardableResult
    func importFile(
        at sourceURL: URL,
        mode: YouziFileImportMode,
        attachingTo target: YouziFileAttachmentTarget,
        at date: Date = Date()
    ) -> YouziFile? {
        captureValue {
            try lifecycle.importFile(
                at: sourceURL,
                mode: mode,
                attachingTo: target,
                at: date
            )
        }
    }

    func attachFile(_ fileID: UUID, to target: YouziFileAttachmentTarget, at date: Date = Date()) {
        capture { try lifecycle.attachFile(fileID, to: target, at: date) }
    }

    func referenceProjectFile(_ fileID: UUID, toTask taskID: UUID, at date: Date = Date()) {
        capture { try lifecycle.referenceProjectFile(fileID, toTask: taskID, at: date) }
    }

    @discardableResult
    func createArtifact(
        data: Data,
        named name: String,
        contentTypeIdentifier: String? = nil,
        kind: YouziArtifactKind,
        taskID: UUID,
        projectID: UUID? = nil,
        previewText: String? = nil,
        at date: Date = Date()
    ) -> YouziArtifact? {
        captureValue {
            try lifecycle.createArtifact(
                data: data,
                named: name,
                contentTypeIdentifier: contentTypeIdentifier,
                kind: kind,
                taskID: taskID,
                projectID: projectID,
                previewText: previewText,
                at: date
            )
        }
    }

    /// Closure-scoped so security-scoped access remains balanced for previews,
    /// Finder reveals, and any future Quick Look integration.
    func withFileURL<Result>(
        id: UUID,
        _ operation: (URL) throws -> Result
    ) throws -> Result {
        do {
            let result = try lifecycle.withAccess(toFile: id, operation)
            document = try lifecycle.load()
            lastPersistenceError = nil
            return result
        } catch {
            lastPersistenceError = error.localizedDescription
            throw error
        }
    }

    func exportFile(id: UUID, to destinationURL: URL) throws {
        do {
            try lifecycle.exportFile(id, to: destinationURL)
            document = try lifecycle.load()
            lastPersistenceError = nil
        } catch {
            lastPersistenceError = error.localizedDescription
            throw error
        }
    }

    func removeFile(id: UUID, deleteManagedCopy: Bool = false) {
        capture { try lifecycle.removeFile(id, deleteManagedCopy: deleteManagedCopy) }
    }

    func seedTemplates(_ templates: [YouziTemplate]) {
        capture { try lifecycle.seedTemplates(templates) }
    }

    @discardableResult
    func instantiateTemplate(id: UUID, at date: Date = Date()) -> YouziTask? {
        captureValue { try lifecycle.instantiateTemplate(id, at: date) }
    }

    func conversationHistoryDidLoad(_ conversations: [ChatConversation]) {
        capture { try conversationBridge.reconcile(conversations) }
    }

    func conversationDidPersist(_ conversation: ChatConversation) {
        capture { try conversationBridge.reconcile([conversation]) }
    }

    func conversationWasDeleted(id: UUID) {
        capture { try conversationBridge.detachDeletedConversation(id: id) }
    }

    private func capture(_ operation: () throws -> YouziDomainDocument) {
        do {
            document = try operation()
            lastPersistenceError = nil
        } catch {
            lastPersistenceError = error.localizedDescription
        }
    }

    private func captureValue<Value>(
        _ operation: () throws -> (Value, YouziDomainDocument)
    ) -> Value? {
        do {
            let (value, updatedDocument) = try operation()
            document = updatedDocument
            lastPersistenceError = nil
            return value
        } catch {
            lastPersistenceError = error.localizedDescription
            return nil
        }
    }
}
