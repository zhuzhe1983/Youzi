import Foundation
import Testing
@testable import Rapid

@Suite("YouziWorkspaceAccess — managed and security-scoped roots")
struct YouziWorkspaceAccessTests {
    private final class BookmarkProbe: @unchecked Sendable {
        var creates = 0
        var starts = 0
        var stops = 0
    }

    @Test("Managed workspaces are private and traversal-safe")
    func managedWorkspaceAndTraversal() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("youzi-workspaces-\(UUID().uuidString)", isDirectory: true)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("youzi-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let coordinator = YouziWorkspaceAccessCoordinator(managedRoot: root)
        let workspace = try coordinator.createManagedWorkspace(id: UUID(), name: "Task")
        let workspaceURL = try coordinator.withAccess(to: workspace) { url, _ in url }
        let mode = try #require(
            FileManager.default.attributesOfItem(atPath: workspaceURL.path)[.posixPermissions]
                as? NSNumber
        )
        #expect(mode.intValue & 0o777 == 0o700)

        #expect(throws: YouziWorkspaceAccessError.self) {
            _ = try coordinator.withAccess(to: workspace, relativePath: "../outside") { url, _ in url }
        }
        #expect(throws: YouziWorkspaceAccessError.self) {
            _ = try coordinator.withAccess(to: workspace, relativePath: "/tmp/outside") { url, _ in url }
        }

        let escape = workspaceURL.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: outside)
        #expect(throws: YouziWorkspaceAccessError.self) {
            _ = try coordinator.withAccess(to: workspace, relativePath: "escape/file.txt") {
                url, _ in url
            }
        }
    }

    @Test("Stale bookmarks refresh and security scope is balanced on throw")
    func staleBookmarkLifecycle() throws {
        enum Expected: Error { case stop }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("youzi-bookmark-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let probe = BookmarkProbe()
        let bookmarkAccess = YouziSecurityScopedBookmarkAccess(
            create: { _ in probe.creates += 1; return Data("fresh".utf8) },
            resolve: { _ in YouziResolvedBookmark(url: directory, isStale: true) },
            start: { _ in probe.starts += 1; return true },
            stop: { _ in probe.stops += 1 }
        )
        let coordinator = YouziWorkspaceAccessCoordinator(
            managedRoot: directory.appendingPathComponent("managed"),
            bookmarks: bookmarkAccess
        )
        let workspace = YouziWorkspace(
            name: "Selected",
            location: .securityScopedBookmark(data: Data("old".utf8), displayPath: directory.path)
        )

        do {
            try coordinator.withAccess(to: workspace, relativePath: "file.txt") { url, refreshed in
                #expect(url == directory.appendingPathComponent("file.txt"))
                #expect(
                    refreshed == .securityScopedBookmark(
                        data: Data("fresh".utf8),
                        displayPath: directory.path
                    )
                )
                throw Expected.stop
            }
        } catch Expected.stop {
            // Expected operation failure still has to release scope.
        }
        #expect(probe.creates == 1)
        #expect(probe.starts == 1)
        #expect(probe.stops == 1)
    }

    @Test("Bookmark workspaces require an existing directory before grant creation")
    func bookmarkedWorkspaceValidatesSelection() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("youzi-workspace-selection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("not-a-folder.txt")
        try Data("file".utf8).write(to: file)
        let probe = BookmarkProbe()
        let bookmarks = YouziSecurityScopedBookmarkAccess(
            create: { _ in probe.creates += 1; return Data("bookmark".utf8) },
            resolve: { _ in YouziResolvedBookmark(url: root, isStale: false) },
            start: { _ in false },
            stop: { _ in }
        )
        let coordinator = YouziWorkspaceAccessCoordinator(
            managedRoot: root.appendingPathComponent("managed"),
            bookmarks: bookmarks
        )

        #expect(throws: YouziWorkspaceAccessError.selectedWorkspaceIsNotDirectory(file.path)) {
            _ = try coordinator.createBookmarkedWorkspace(name: "File", directoryURL: file)
        }
        let missing = root.appendingPathComponent("missing")
        #expect(throws: YouziWorkspaceAccessError.selectedWorkspaceIsNotDirectory(missing.path)) {
            _ = try coordinator.createBookmarkedWorkspace(name: "Missing", directoryURL: missing)
        }
        #expect(probe.creates == 0)

        let workspace = try coordinator.createBookmarkedWorkspace(
            name: "Valid",
            directoryURL: root
        )
        #expect(workspace.state == .active)
        #expect(probe.creates == 1)
    }
}
