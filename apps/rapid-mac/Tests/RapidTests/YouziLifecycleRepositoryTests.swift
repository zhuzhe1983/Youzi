import Foundation
import Testing
@testable import Rapid

@Suite("YouziLifecycleRepository — task/workspace/project/file/artifact lifecycle")
struct YouziLifecycleRepositoryTests {
    private final class FailureSwitch: @unchecked Sendable {
        var shouldFail = false
    }

    private func fixture() throws -> (
        root: URL,
        store: YouziDomainStore,
        repository: YouziLifecycleRepository
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("youzi-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = YouziDomainStore(fileURL: root.appendingPathComponent("domain.json"))
        let access = YouziWorkspaceAccessCoordinator(
            managedRoot: root.appendingPathComponent("workspaces", isDirectory: true)
        )
        let files = YouziManagedFileStore(
            root: root.appendingPathComponent("files", isDirectory: true),
            workspaceAccess: access
        )
        return (
            root,
            store,
            YouziLifecycleRepository(store: store, workspaceAccess: access, fileStore: files)
        )
    }

    @Test("First execution allocates one managed workspace; explicit selection is stable")
    func workspaceLifecycle() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let task = YouziTask(title: "Prepare report", request: "Draft it")
        try fixture.store.save(YouziDomainDocument(tasks: [task]))

        let (first, firstDocument) = try fixture.repository.ensureManagedWorkspace(forTask: task.id)
        let (second, secondDocument) = try fixture.repository.ensureManagedWorkspace(forTask: task.id)
        #expect(first.id == second.id)
        #expect(firstDocument.workspaces.count == 1)
        #expect(secondDocument.workspaces.count == 1)

        let (selected, _) = try fixture.repository.createManagedWorkspace(name: "Selected")
        _ = try fixture.repository.assignWorkspace(selected.id, toTask: task.id)
        let (resolved, _) = try fixture.repository.ensureManagedWorkspace(forTask: task.id)
        #expect(resolved.id == selected.id)
    }

    @Test("Projects, imports, artifacts, and templates preserve separate identities")
    func completeLifecycle() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let task = YouziTask(title: "Trip", request: "Plan")
        try fixture.store.save(YouziDomainDocument(tasks: [task]))
        let (project, _) = try fixture.repository.createProject(name: "Travel")
        _ = try fixture.repository.moveTask(task.id, toProject: project.id)

        let source = fixture.root.appendingPathComponent("notes.txt")
        try Data("source".utf8).write(to: source)
        let (input, imported) = try fixture.repository.importFile(
            at: source,
            mode: .copy,
            attachingTo: .task(task.id)
        )
        #expect(imported.tasks[0].inputFileIDs == [input.id])
        #expect(imported.files[0].role == .taskInput)

        let (artifact, artifactDocument) = try fixture.repository.createArtifact(
            data: Data("result".utf8),
            named: "result.md",
            contentTypeIdentifier: "net.daringfireball.markdown",
            kind: .document,
            taskID: task.id,
            projectID: project.id,
            previewText: "Result"
        )
        let artifactFile = try #require(
            artifactDocument.files.first { $0.id == artifact.fileID }
        )
        #expect(artifact.id != artifact.fileID)
        #expect(artifactFile.role == .artifact)
        #expect(artifactDocument.tasks[0].artifactIDs == [artifact.id])
        #expect(
            throws: YouziLifecycleError.artifactFileCannotBeReattached(artifact.fileID)
        ) {
            _ = try fixture.repository.attachFile(artifact.fileID, to: .task(task.id))
        }

        let sourceURL = try fixture.repository.withAccess(toFile: input.id) { $0 }
        _ = try fixture.repository.removeFile(input.id)
        #expect(FileManager.default.fileExists(atPath: sourceURL.path))

        let template = YouziTemplate(
            name: "Weekly plan",
            category: "Planning",
            summary: "Make a plan",
            prefilledRequest: "Draft my week",
            source: YouziManifestSource(kind: .builtIn, identifier: "catalog", version: "1")
        )
        _ = try fixture.repository.seedTemplates([template])
        let (draft, final) = try fixture.repository.instantiateTemplate(template.id)
        #expect(draft.status == .draft)
        #expect(draft.workspaceID == nil)
        #expect(final.tasks.contains { $0.id == draft.id })
    }

    @Test("Moving a file repairs every old backlink; project references remain non-owning")
    func attachmentSemantics() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let firstTask = YouziTask(title: "First", request: "")
        let secondTask = YouziTask(title: "Second", request: "")
        try fixture.store.save(YouziDomainDocument(tasks: [firstTask, secondTask]))
        let (project, _) = try fixture.repository.createProject(name: "Project")
        _ = try fixture.repository.moveTask(secondTask.id, toProject: project.id)
        let source = fixture.root.appendingPathComponent("move.txt")
        try Data("move".utf8).write(to: source)
        let (file, _) = try fixture.repository.importFile(
            at: source,
            mode: .copy,
            attachingTo: .task(firstTask.id)
        )

        var moved = try fixture.repository.attachFile(file.id, to: .project(project.id))
        #expect(moved.tasks.allSatisfy { !$0.inputFileIDs.contains(file.id) })
        #expect(moved.projects[0].resourceFileIDs == [file.id])
        #expect(moved.files[0].role == .projectResource)
        #expect(moved.files[0].originTaskID == nil)
        #expect(moved.files[0].projectID == project.id)

        moved = try fixture.repository.referenceProjectFile(file.id, toTask: secondTask.id)
        #expect(moved.projects[0].resourceFileIDs == [file.id])
        #expect(moved.tasks.first { $0.id == secondTask.id }?.inputFileIDs == [file.id])
        #expect(moved.files[0].role == .projectResource)

        moved = try fixture.repository.attachFile(file.id, to: .task(firstTask.id))
        #expect(moved.projects[0].resourceFileIDs.isEmpty)
        #expect(moved.tasks.first { $0.id == secondTask.id }?.inputFileIDs.isEmpty == true)
        #expect(moved.tasks.first { $0.id == firstTask.id }?.inputFileIDs == [file.id])
        #expect(moved.files[0].role == .taskInput)
        #expect(moved.files[0].originTaskID == firstTask.id)
        #expect(moved.files[0].projectID == nil)
    }

    @Test("A failed metadata tombstone cannot delete managed bytes")
    func metadataFailurePrecedesManagedDeletion() throws {
        enum InjectedFailure: Error { case stop }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("youzi-delete-order-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let failure = FailureSwitch()
        let store = YouziDomainStore(
            fileURL: root.appendingPathComponent("domain.json"),
            beforeAtomicReplace: {
                if failure.shouldFail { throw InjectedFailure.stop }
            }
        )
        let access = YouziWorkspaceAccessCoordinator(
            managedRoot: root.appendingPathComponent("workspaces")
        )
        let fileStore = YouziManagedFileStore(
            root: root.appendingPathComponent("files"),
            workspaceAccess: access
        )
        let repository = YouziLifecycleRepository(
            store: store,
            workspaceAccess: access,
            fileStore: fileStore
        )
        let task = YouziTask(title: "Delete", request: "")
        try store.save(YouziDomainDocument(tasks: [task]))
        let source = root.appendingPathComponent("source.txt")
        try Data("authoritative".utf8).write(to: source)
        let (file, _) = try repository.importFile(
            at: source,
            mode: .copy,
            attachingTo: .task(task.id)
        )
        guard case let .appManaged(relativePath) = file.location else {
            Issue.record("Expected managed copy")
            return
        }
        let managedURL = root.appendingPathComponent("files").appendingPathComponent(relativePath)
        #expect(FileManager.default.fileExists(atPath: managedURL.path))

        failure.shouldFail = true
        #expect(throws: YouziDomainStoreError.self) {
            _ = try repository.removeFile(file.id, deleteManagedCopy: true)
        }
        #expect(FileManager.default.fileExists(atPath: managedURL.path))
        #expect(try store.load().files.first { $0.id == file.id }?.availability == .available)
    }
}
