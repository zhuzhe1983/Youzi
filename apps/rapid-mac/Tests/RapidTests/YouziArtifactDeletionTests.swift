import Foundation
import Testing
@testable import Rapid

@Suite("Deliverable deletion — recoverable files and durable receipts")
struct YouziArtifactDeletionTests {
    private enum Failure: Error { case injected }
    private final class Faults: @unchecked Sendable {
        var failSave = false
        var failTrash = false
        var failAfterTrash = false
        var moves = 0
    }
    private struct Fixture {
        let root: URL
        let store: YouziDomainStore
        let files: YouziManagedFileStore
        let repository: YouziLifecycleRepository
        let artifact: YouziArtifact
        let file: YouziFile
        let source: URL
        let trash: URL
        let faults: Faults
    }
    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("youzi-delete-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let faults = Faults()
        let store = YouziDomainStore(fileURL: root.appendingPathComponent("domain.json"), beforeAtomicReplace: {
            if faults.failSave { throw Failure.injected }
        })
        let trash = root.appendingPathComponent("trash.txt")
        let files = YouziManagedFileStore(root: root.appendingPathComponent("files"), trashItem: { url in
            if faults.failTrash { throw Failure.injected }
            try FileManager.default.moveItem(at: url, to: trash)
            faults.moves += 1
            if faults.failAfterTrash { faults.failSave = true }
        })
        let repository = YouziLifecycleRepository(store: store, fileStore: files)
        let task = YouziTask(title: "Deletion fixture", request: "", conversationID: UUID())
        try store.save(YouziDomainDocument(tasks: [task]))
        let (artifact, document) = try repository.createArtifact(data: Data("recover me".utf8), named: "output.txt", kind: .document, taskID: task.id)
        let file = try #require(document.files.first { $0.id == artifact.fileID })
        let source = try repository.withAccess(toFile: file.id) { $0 }
        return Fixture(root: root, store: store, files: files, repository: repository, artifact: artifact, file: file, source: source, trash: trash, faults: faults)
    }

    @Test("Deletion moves exact bytes, preserves history and survives reload/repeated deletion")
    func recoverableDeletion() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let before = try f.store.load()
        let result = try f.repository.deleteArtifact(f.artifact.id)
        #expect(result.artifacts[0].state == .archived)
        #expect(result.files[0].availability == .missing)
        #expect(result.tasks == before.tasks)
        #expect(!FileManager.default.fileExists(atPath: f.source.path))
        #expect(try Data(contentsOf: f.trash) == Data("recover me".utf8))
        #expect(try f.store.load() == result)
        #expect(try f.repository.deleteArtifact(f.artifact.id) == result)
        #expect(f.faults.moves == 1)
    }

    @Test("External references and workspace files are only removed from the gallery", arguments: [false, true])
    func externalReference(workspace: Bool) throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        var document = try f.store.load()
        if workspace {
            let space = YouziWorkspace(name: "External", location: .securityScopedBookmark(data: Data(), displayPath: f.root.path))
            document.workspaces.append(space)
            document.files[0].location = .workspace(workspaceID: space.id, relativePath: "outside.txt")
        } else {
            document.files[0].location = .securityScopedBookmark(data: Data(), displayPath: f.source.path)
        }
        try f.store.save(document)
        let result = try f.repository.deleteArtifact(f.artifact.id)
        #expect(result.artifacts[0].state == .archived)
        #expect(result.files[0] == document.files[0])
        #expect(f.faults.moves == 0)
        #expect(try Data(contentsOf: f.source) == Data("recover me".utf8))
    }

    @Test("A failed first metadata save leaves the original readable and never calls Trash")
    func firstCommitFailure() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let original = try f.store.load()
        f.faults.failSave = true
        #expect(throws: (any Error).self) { try f.repository.deleteArtifact(f.artifact.id) }
        #expect(try f.store.load() == original)
        #expect(f.faults.moves == 0)
        #expect(FileManager.default.fileExists(atPath: f.source.path))
    }

    @Test("Trash failure stays visible; retry finishes without permanently deleting bytes")
    @MainActor func trashFailure() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let product = YouziProductModel(store: f.store, fileStore: f.files)
        f.faults.failTrash = true
        #expect(throws: (any Error).self) { try product.deleteArtifact(id: f.artifact.id) }
        #expect(product.artifacts[0].state == .unavailable)
        #expect(product.files[0].availability == .revoked)
        #expect(product.lastPersistenceError != nil)
        #expect(FileManager.default.fileExists(atPath: f.source.path))
        f.faults.failTrash = false
        try product.deleteArtifact(id: f.artifact.id)
        #expect(product.artifacts[0].state == .archived)
        #expect(product.lastPersistenceError == nil)
        #expect(try Data(contentsOf: f.trash) == Data("recover me".utf8))
    }

    @Test("An interrupted final commit is retryable after bytes already reached Trash")
    func lastCommitFailure() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        f.faults.failAfterTrash = true
        #expect(throws: (any Error).self) { try f.repository.deleteArtifact(f.artifact.id) }
        #expect(try f.store.load().artifacts[0].state == .unavailable)
        #expect(try Data(contentsOf: f.trash) == Data("recover me".utf8))
        f.faults.failSave = false
        #expect(try f.repository.deleteArtifact(f.artifact.id).artifacts[0].state == .archived)
        #expect(f.faults.moves == 1)
    }

    @Test("A missing file still allows its deliverable to be removed")
    func missingSource() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try FileManager.default.removeItem(at: f.source)
        #expect(try f.repository.deleteArtifact(f.artifact.id).artifacts[0].state == .archived)
        #expect(f.faults.moves == 0)
    }

    @Test("Trash rejects external files, malformed ownership, traversal and escaped symlinks")
    func ownedPathValidation() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        var file = f.file
        file.location = .securityScopedBookmark(data: Data(), displayPath: f.source.path)
        #expect(throws: YouziManagedFileStoreError.refusesToDeleteExternalFile) { try f.files.trashManagedCopy(for: file) }
        for path in ["../output.txt", "\(UUID().uuidString.lowercased())/output.txt", "\(file.id.uuidString.lowercased())/../output.txt"] {
            file.location = .appManaged(relativePath: path)
            #expect(throws: (any Error).self) { try f.files.trashManagedCopy(for: file) }
        }
        let external = f.root.appendingPathComponent("external.txt")
        try Data("external".utf8).write(to: external)
        try FileManager.default.removeItem(at: f.source)
        try FileManager.default.createSymbolicLink(at: f.source, withDestinationURL: external)
        #expect(throws: (any Error).self) { try f.files.trashManagedCopy(for: f.file) }
        #expect(try Data(contentsOf: external) == Data("external".utf8))
        #expect(f.faults.moves == 0)
    }
}
