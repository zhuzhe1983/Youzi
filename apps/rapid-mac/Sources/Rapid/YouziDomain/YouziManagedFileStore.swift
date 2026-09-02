import CryptoKit
import Darwin
import Foundation
import UniformTypeIdentifiers

enum YouziFileImportMode: String, Codable, Equatable, Sendable {
    case copy
    case reference
}

enum YouziManagedFileStoreError: Error, Equatable, Sendable {
    case sourceIsNotRegularFile(String)
    case fileNotFound(String)
    case workspaceNotFound(UUID)
    case refusesToDeleteExternalFile
    case invalidManagedLocation(String)
    case ioFailed(String)
}

extension YouziManagedFileStoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .sourceIsNotRegularFile(path): return "File source is not a regular file: \(path)"
        case let .fileNotFound(path): return "File is unavailable: \(path)"
        case let .workspaceNotFound(id): return "Workspace \(id) is unavailable."
        case .refusesToDeleteExternalFile: return "Only app-managed file bytes can be deleted."
        case let .invalidManagedLocation(path): return "Invalid app-managed file location: \(path)"
        case let .ioFailed(message): return "File operation failed: \(message)"
        }
    }
}

/// Byte store for app-owned files plus closure-scoped resolution of referenced
/// and workspace files. Managed sources always use `<UUID>/<safe-name>` below
/// the HOME-aware YouziFiles root.
final class YouziManagedFileStore: @unchecked Sendable {
    let root: URL

    private let fileManager: FileManager
    private let workspaces: YouziWorkspaceAccessCoordinator
    private let bookmarks: YouziSecurityScopedBookmarkAccess

    init(
        root: URL = ApplicationSupportLocator.youziManagedFilesDirectory(),
        fileManager: FileManager = .default,
        workspaceAccess: YouziWorkspaceAccessCoordinator = YouziWorkspaceAccessCoordinator(),
        bookmarks: YouziSecurityScopedBookmarkAccess = .foundation
    ) {
        self.root = root.standardizedFileURL
        self.fileManager = fileManager
        self.workspaces = workspaceAccess
        self.bookmarks = bookmarks
    }

    func importFile(
        at sourceURL: URL,
        mode: YouziFileImportMode,
        role: YouziFileRole,
        originTaskID: UUID? = nil,
        projectID: UUID? = nil,
        id: UUID = UUID(),
        at date: Date = Date()
    ) throws -> YouziFile {
        let metadata = try sourceMetadata(sourceURL)
        switch mode {
        case .copy:
            let relativePath = "\(id.uuidString.lowercased())/\(Self.safeName(sourceURL.lastPathComponent))"
            let destination = try checkedManagedURL(relativePath: relativePath)
            let digest = try copyAtomically(from: sourceURL, to: destination)
            return YouziFile(
                id: id,
                displayName: sourceURL.lastPathComponent,
                contentTypeIdentifier: metadata.contentTypeIdentifier,
                byteCount: metadata.byteCount,
                sha256: digest,
                role: role,
                originTaskID: originTaskID,
                projectID: projectID,
                location: .appManaged(relativePath: relativePath),
                createdAt: date,
                updatedAt: date,
                lastVerifiedAt: date
            )

        case .reference:
            let data: Data
            do {
                data = try bookmarks.create(sourceURL)
            } catch {
                throw YouziManagedFileStoreError.ioFailed(error.localizedDescription)
            }
            return YouziFile(
                id: id,
                displayName: sourceURL.lastPathComponent,
                contentTypeIdentifier: metadata.contentTypeIdentifier,
                byteCount: metadata.byteCount,
                role: role,
                originTaskID: originTaskID,
                projectID: projectID,
                location: .securityScopedBookmark(data: data, displayPath: sourceURL.path),
                createdAt: date,
                updatedAt: date,
                lastVerifiedAt: date
            )
        }
    }

    func write(
        _ data: Data,
        named displayName: String,
        contentTypeIdentifier: String? = nil,
        role: YouziFileRole,
        originTaskID: UUID? = nil,
        projectID: UUID? = nil,
        id: UUID = UUID(),
        at date: Date = Date()
    ) throws -> YouziFile {
        let relativePath = "\(id.uuidString.lowercased())/\(Self.safeName(displayName))"
        let destination = try checkedManagedURL(relativePath: relativePath)
        try writeAtomically(data, to: destination)
        return YouziFile(
            id: id,
            displayName: displayName,
            contentTypeIdentifier: contentTypeIdentifier,
            byteCount: Int64(data.count),
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            role: role,
            originTaskID: originTaskID,
            projectID: projectID,
            location: .appManaged(relativePath: relativePath),
            createdAt: date,
            updatedAt: date,
            lastVerifiedAt: date
        )
    }

    /// The optional refreshed location must be persisted by the lifecycle
    /// repository after a stale bookmark is successfully used.
    func withAccess<Result>(
        to file: YouziFile,
        workspaces workspaceRecords: [UUID: YouziWorkspace],
        _ operation: (URL, YouziFileLocation?) throws -> Result
    ) throws -> Result {
        switch file.location {
        case let .appManaged(relativePath):
            let url = try checkedManagedURL(relativePath: relativePath)
            guard fileManager.fileExists(atPath: url.path) else {
                throw YouziManagedFileStoreError.fileNotFound(url.path)
            }
            return try operation(url, nil)

        case let .workspace(workspaceID, relativePath):
            guard let workspace = workspaceRecords[workspaceID] else {
                throw YouziManagedFileStoreError.workspaceNotFound(workspaceID)
            }
            return try workspaces.withAccess(to: workspace, relativePath: relativePath) {
                url, refreshedWorkspaceLocation in
                let refreshedFileLocation: YouziFileLocation?
                if let refreshedWorkspaceLocation {
                    // The refreshed grant belongs to the workspace record, not
                    // to this relative file. LifecycleRepository resolves this
                    // branch directly so it can persist the workspace update.
                    _ = refreshedWorkspaceLocation
                    refreshedFileLocation = nil
                } else {
                    refreshedFileLocation = nil
                }
                return try operation(url, refreshedFileLocation)
            }

        case let .securityScopedBookmark(data, displayPath):
            let resolved: YouziResolvedBookmark
            do {
                resolved = try bookmarks.resolve(data)
            } catch {
                throw YouziManagedFileStoreError.ioFailed(error.localizedDescription)
            }
            let didStart = bookmarks.start(resolved.url)
            defer { if didStart { bookmarks.stop(resolved.url) } }
            guard fileManager.fileExists(atPath: resolved.url.path) else {
                throw YouziManagedFileStoreError.fileNotFound(displayPath)
            }
            let refreshed: YouziFileLocation?
            if resolved.isStale {
                do {
                    refreshed = .securityScopedBookmark(
                        data: try bookmarks.create(resolved.url),
                        displayPath: resolved.url.path
                    )
                } catch {
                    throw YouziManagedFileStoreError.ioFailed(error.localizedDescription)
                }
            } else {
                refreshed = nil
            }
            return try operation(resolved.url, refreshed)
        }
    }

    /// Exports a copy and leaves the authoritative file record unchanged.
    @discardableResult
    func export(
        _ file: YouziFile,
        to destinationURL: URL,
        workspaces workspaceRecords: [UUID: YouziWorkspace]
    ) throws -> YouziFileLocation? {
        var refreshedLocation: YouziFileLocation?
        try withAccess(to: file, workspaces: workspaceRecords) { source, refreshed in
            refreshedLocation = refreshed
            _ = try copyAtomically(from: source, to: destinationURL)
        }
        return refreshedLocation
    }

    func exportResolvedFile(at sourceURL: URL, to destinationURL: URL) throws {
        _ = try copyAtomically(from: sourceURL, to: destinationURL)
    }

    /// Explicit compensation/deletion API. It refuses workspace and bookmarked
    /// locations and validates the record UUID directory before removing bytes.
    func removeManagedCopy(for file: YouziFile) throws {
        guard case let .appManaged(relativePath) = file.location else {
            throw YouziManagedFileStoreError.refusesToDeleteExternalFile
        }
        let components = relativePath.split(separator: "/")
        guard components.count == 2,
              components[0] == Substring(file.id.uuidString.lowercased())
        else {
            throw YouziManagedFileStoreError.invalidManagedLocation(relativePath)
        }
        let url = try checkedManagedURL(relativePath: relativePath)
        do {
            if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
            let directory = url.deletingLastPathComponent()
            if fileManager.fileExists(atPath: directory.path) {
                try fileManager.removeItem(at: directory)
            }
        } catch {
            throw YouziManagedFileStoreError.ioFailed(error.localizedDescription)
        }
    }

    static func safeName(_ rawName: String) -> String {
        let source = rawName.isEmpty ? "file" : rawName
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ._-"))
        let mapped = source.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" }
        var result = String(mapped).trimmingCharacters(in: .whitespacesAndNewlines)
        if result.isEmpty || result == "." || result == ".." { result = "file" }
        if result.count > 160 { result = String(result.prefix(160)) }
        return result
    }

    private func checkedManagedURL(relativePath: String) throws -> URL {
        do {
            return try workspaces.checkedURL(relativePath: relativePath, beneath: root)
        } catch {
            throw YouziManagedFileStoreError.invalidManagedLocation(
                "\(relativePath) (\(error.localizedDescription))"
            )
        }
    }

    private func sourceMetadata(_ url: URL) throws
        -> (byteCount: Int64?, contentTypeIdentifier: String?)
    {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentTypeKey])
            guard values.isRegularFile == true else {
                throw YouziManagedFileStoreError.sourceIsNotRegularFile(url.path)
            }
            return (values.fileSize.map(Int64.init), values.contentType?.identifier)
        } catch let error as YouziManagedFileStoreError {
            throw error
        } catch {
            throw YouziManagedFileStoreError.ioFailed(error.localizedDescription)
        }
    }

    private func writeAtomically(_ data: Data, to destination: URL) throws {
        try prepareParent(of: destination)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        )
        do {
            guard fileManager.createFile(
                atPath: temporary.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw YouziManagedFileStoreError.ioFailed("Could not create temporary file")
            }
            defer { try? fileManager.removeItem(at: temporary) }
            let handle = try FileHandle(forWritingTo: temporary)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            try rename(temporary, to: destination)
        } catch let error as YouziManagedFileStoreError {
            throw error
        } catch {
            throw YouziManagedFileStoreError.ioFailed(error.localizedDescription)
        }
    }

    private func copyAtomically(from source: URL, to destination: URL) throws -> String {
        try prepareParent(of: destination)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        )
        let didStart = source.startAccessingSecurityScopedResource()
        defer { if didStart { source.stopAccessingSecurityScopedResource() } }
        do {
            guard fileManager.createFile(
                atPath: temporary.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw YouziManagedFileStoreError.ioFailed("Could not create temporary file")
            }
            defer { try? fileManager.removeItem(at: temporary) }
            let reader = try FileHandle(forReadingFrom: source)
            let writer = try FileHandle(forWritingTo: temporary)
            defer {
                try? reader.close()
                try? writer.close()
            }
            var hasher = SHA256()
            while true {
                let chunk = try reader.read(upToCount: 1_048_576) ?? Data()
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
                try writer.write(contentsOf: chunk)
            }
            try writer.synchronize()
            try writer.close()
            try reader.close()
            try rename(temporary, to: destination)
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        } catch let error as YouziManagedFileStoreError {
            throw error
        } catch {
            throw YouziManagedFileStoreError.ioFailed(error.localizedDescription)
        }
    }

    private func prepareParent(of destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        do {
            let isManaged = directory.standardizedFileURL.path.hasPrefix(root.path + "/")
            if isManaged {
                try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
                try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                try fileManager.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: directory.path
                )
            } else {
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                      isDirectory.boolValue
                else {
                    throw YouziManagedFileStoreError.ioFailed(
                        "Export destination directory does not exist"
                    )
                }
            }
        } catch {
            if let error = error as? YouziManagedFileStoreError { throw error }
            throw YouziManagedFileStoreError.ioFailed(error.localizedDescription)
        }
    }

    private func rename(_ source: URL, to destination: URL) throws {
        let result = source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else { return Int32(-1) }
                return Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else {
            throw YouziManagedFileStoreError.ioFailed(String(cString: strerror(errno)))
        }
    }
}
