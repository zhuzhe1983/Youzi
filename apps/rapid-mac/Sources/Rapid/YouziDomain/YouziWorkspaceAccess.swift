import Foundation

struct YouziResolvedBookmark: Equatable, Sendable {
    var url: URL
    var isStale: Bool
}

/// Injectable wrapper around macOS bookmark APIs. Tests can prove balanced
/// security-scope and stale-refresh behavior without minting sandbox grants.
struct YouziSecurityScopedBookmarkAccess: @unchecked Sendable {
    var create: (URL) throws -> Data
    var resolve: (Data) throws -> YouziResolvedBookmark
    var start: (URL) -> Bool
    var stop: (URL) -> Void

    static let foundation = YouziSecurityScopedBookmarkAccess(
        create: { url in
            try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        },
        resolve: { data in
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return YouziResolvedBookmark(url: url, isStale: isStale)
        },
        start: { $0.startAccessingSecurityScopedResource() },
        stop: { $0.stopAccessingSecurityScopedResource() }
    )
}

enum YouziWorkspaceAccessError: Error, Equatable, Sendable {
    case invalidRelativePath(String)
    case pathEscapesWorkspace(String)
    case missingManagedWorkspace(String)
    case selectedWorkspaceIsNotDirectory(String)
    case bookmarkCreationFailed(String)
    case bookmarkResolutionFailed(String)
    case fileSystemFailed(String)
}

extension YouziWorkspaceAccessError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .invalidRelativePath(path): return "Invalid relative workspace path: \(path)"
        case let .pathEscapesWorkspace(path): return "Path escapes the selected workspace: \(path)"
        case let .missingManagedWorkspace(path): return "Managed workspace is missing: \(path)"
        case let .selectedWorkspaceIsNotDirectory(path):
            return "Selected workspace is not an existing directory: \(path)"
        case let .bookmarkCreationFailed(message): return "Could not save folder access: \(message)"
        case let .bookmarkResolutionFailed(message): return "Could not restore folder access: \(message)"
        case let .fileSystemFailed(message): return "Workspace filesystem operation failed: \(message)"
        }
    }
}

/// Owns all resolution of managed and bookmarked workspaces. Relative paths
/// are checked lexically and through existing symlinks before any caller gets
/// a URL, closing both `..` and symlink traversal escapes.
final class YouziWorkspaceAccessCoordinator: @unchecked Sendable {
    let managedRoot: URL

    private let fileManager: FileManager
    private let bookmarks: YouziSecurityScopedBookmarkAccess

    init(
        managedRoot: URL = ApplicationSupportLocator.youziManagedWorkspacesDirectory(),
        fileManager: FileManager = .default,
        bookmarks: YouziSecurityScopedBookmarkAccess = .foundation
    ) {
        self.managedRoot = managedRoot.standardizedFileURL
        self.fileManager = fileManager
        self.bookmarks = bookmarks
    }

    func createManagedWorkspace(
        id: UUID,
        name: String,
        at date: Date = Date()
    ) throws -> YouziWorkspace {
        let relativePath = id.uuidString.lowercased()
        let directory = try checkedURL(relativePath: relativePath, beneath: managedRoot)
        do {
            try fileManager.createDirectory(at: managedRoot, withIntermediateDirectories: true)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: managedRoot.path)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            throw YouziWorkspaceAccessError.fileSystemFailed(error.localizedDescription)
        }
        return YouziWorkspace(
            id: id,
            name: name,
            location: .managed(relativePath: relativePath),
            createdAt: date,
            updatedAt: date,
            lastAccessedAt: date
        )
    }

    func createBookmarkedWorkspace(
        id: UUID = UUID(),
        name: String,
        directoryURL: URL,
        at date: Date = Date()
    ) throws -> YouziWorkspace {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw YouziWorkspaceAccessError.selectedWorkspaceIsNotDirectory(directoryURL.path)
        }
        do {
            let data = try bookmarks.create(directoryURL)
            return YouziWorkspace(
                id: id,
                name: name,
                location: .securityScopedBookmark(data: data, displayPath: directoryURL.path),
                createdAt: date,
                updatedAt: date,
                lastAccessedAt: date
            )
        } catch {
            throw YouziWorkspaceAccessError.bookmarkCreationFailed(error.localizedDescription)
        }
    }

    /// Compensation for a failed metadata commit. Only a single managed
    /// workspace directory is eligible; bookmarked folders are never deleted.
    func removeManagedWorkspace(_ workspace: YouziWorkspace) throws {
        guard case let .managed(relativePath) = workspace.location,
              relativePath == workspace.id.uuidString.lowercased()
        else { return }
        let directory = try checkedURL(relativePath: relativePath, beneath: managedRoot)
        do {
            if fileManager.fileExists(atPath: directory.path) {
                try fileManager.removeItem(at: directory)
            }
        } catch {
            throw YouziWorkspaceAccessError.fileSystemFailed(error.localizedDescription)
        }
    }

    /// Executes while a bookmark's security scope is active. A stale bookmark
    /// is refreshed before the operation and surfaced so the repository can
    /// persist it in the same lifecycle transaction.
    func withAccess<Result>(
        to workspace: YouziWorkspace,
        relativePath: String = "",
        _ operation: (URL, YouziWorkspaceLocation?) throws -> Result
    ) throws -> Result {
        switch workspace.location {
        case let .managed(storedRelativePath):
            let root = try checkedURL(relativePath: storedRelativePath, beneath: managedRoot)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else {
                throw YouziWorkspaceAccessError.missingManagedWorkspace(root.path)
            }
            let target = try checkedURL(relativePath: relativePath, beneath: root)
            return try operation(target, nil)

        case let .securityScopedBookmark(data, displayPath):
            let resolved: YouziResolvedBookmark
            do {
                resolved = try bookmarks.resolve(data)
            } catch {
                throw YouziWorkspaceAccessError.bookmarkResolutionFailed(error.localizedDescription)
            }

            let didStart = bookmarks.start(resolved.url)
            defer {
                if didStart { bookmarks.stop(resolved.url) }
            }
            let target = try checkedURL(relativePath: relativePath, beneath: resolved.url)
            let refreshed: YouziWorkspaceLocation?
            if resolved.isStale {
                do {
                    refreshed = .securityScopedBookmark(
                        data: try bookmarks.create(resolved.url),
                        displayPath: resolved.url.path.isEmpty ? displayPath : resolved.url.path
                    )
                } catch {
                    throw YouziWorkspaceAccessError.bookmarkCreationFailed(error.localizedDescription)
                }
            } else {
                refreshed = nil
            }
            return try operation(target, refreshed)
        }
    }

    /// Same traversal guard used by workspace and managed-file stores. Kept
    /// internal so focused tests can exercise the boundary directly.
    func checkedURL(relativePath: String, beneath rootURL: URL) throws -> URL {
        let root = rootURL.standardizedFileURL
        guard !relativePath.hasPrefix("/"), !relativePath.hasPrefix("~") else {
            throw YouziWorkspaceAccessError.invalidRelativePath(relativePath)
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0 == ".." || $0 == "." }) else {
            throw YouziWorkspaceAccessError.invalidRelativePath(relativePath)
        }

        let candidate = relativePath.isEmpty
            ? root
            : root.appendingPathComponent(relativePath, isDirectory: false).standardizedFileURL
        guard Self.contains(candidate, in: root) else {
            throw YouziWorkspaceAccessError.pathEscapesWorkspace(relativePath)
        }

        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        var existingAncestor = candidate
        while !fileManager.fileExists(atPath: existingAncestor.path),
              existingAncestor.standardizedFileURL.path != root.path {
            existingAncestor.deleteLastPathComponent()
        }
        let resolvedAncestor = existingAncestor.resolvingSymlinksInPath().standardizedFileURL
        guard Self.contains(resolvedAncestor, in: resolvedRoot) else {
            throw YouziWorkspaceAccessError.pathEscapesWorkspace(relativePath)
        }
        return candidate
    }

    private static func contains(_ candidate: URL, in root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }
}
