import Foundation
import Testing
@testable import Rapid

@Suite("YouziManagedFileStore — explicit ownership")
struct YouziManagedFileStoreTests {
    private func fixture() throws -> (URL, URL, YouziManagedFileStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("youzi-files-test-\(UUID().uuidString)", isDirectory: true)
        let sources = root.appendingPathComponent("sources", isDirectory: true)
        let managed = root.appendingPathComponent("managed", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let bookmarks = YouziSecurityScopedBookmarkAccess(
            create: { Data($0.path.utf8) },
            resolve: { data in
                YouziResolvedBookmark(
                    url: URL(fileURLWithPath: String(decoding: data, as: UTF8.self)),
                    isStale: false
                )
            },
            start: { _ in true },
            stop: { _ in }
        )
        let workspaceAccess = YouziWorkspaceAccessCoordinator(
            managedRoot: root.appendingPathComponent("workspaces"),
            bookmarks: bookmarks
        )
        return (
            root,
            sources,
            YouziManagedFileStore(
                root: managed,
                workspaceAccess: workspaceAccess,
                bookmarks: bookmarks
            )
        )
    }

    @Test("Copy import stores private exact bytes under UUID and exports without changing source")
    func copyImportAndExport() throws {
        let (root, sources, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = sources.appendingPathComponent("unsafe:name?.txt")
        try Data("hello".utf8).write(to: source)

        let record = try store.importFile(at: source, mode: .copy, role: .taskInput)
        guard case let .appManaged(relativePath) = record.location else {
            Issue.record("Expected appManaged location")
            return
        }
        #expect(relativePath.hasPrefix(record.id.uuidString.lowercased() + "/"))
        #expect(!relativePath.contains("?"))
        #expect(record.byteCount == 5)
        #expect(record.sha256 == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")

        let managedURL = try store.withAccess(to: record, workspaces: [:]) { url, _ in url }
        #expect(try Data(contentsOf: managedURL) == Data("hello".utf8))
        let mode = try #require(
            FileManager.default.attributesOfItem(atPath: managedURL.path)[.posixPermissions]
                as? NSNumber
        )
        #expect(mode.intValue & 0o777 == 0o600)

        let exportURL = root.appendingPathComponent("export.txt")
        #expect(try store.export(record, to: exportURL, workspaces: [:]) == nil)
        #expect(try Data(contentsOf: exportURL) == Data("hello".utf8))
        #expect(record.location == .appManaged(relativePath: relativePath))

        try store.removeManagedCopy(for: record)
        #expect(!FileManager.default.fileExists(atPath: managedURL.path))
    }

    @Test("Reference import keeps external bytes and refuses managed deletion")
    func referenceIsNotOwned() throws {
        let (root, sources, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = sources.appendingPathComponent("reference.txt")
        try Data("external".utf8).write(to: source)

        let record = try store.importFile(at: source, mode: .reference, role: .projectResource)
        guard case .securityScopedBookmark = record.location else {
            Issue.record("Expected a bookmark-backed reference")
            return
        }
        #expect(record.sha256 == nil)
        #expect(throws: YouziManagedFileStoreError.refusesToDeleteExternalFile) {
            try store.removeManagedCopy(for: record)
        }
        #expect(try Data(contentsOf: source) == Data("external".utf8))
    }
}
