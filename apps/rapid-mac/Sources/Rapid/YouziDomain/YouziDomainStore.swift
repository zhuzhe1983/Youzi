import Darwin
import Foundation

enum YouziDomainSchema {
    static let formatIdentifier = "com.rapidmlx.youzi.domain"
    static let currentVersion = 2
}

struct YouziDomainEnvelope: Codable, Equatable, Sendable {
    var formatIdentifier: String
    var schemaVersion: Int
    var document: YouziDomainDocument

    init(
        formatIdentifier: String = YouziDomainSchema.formatIdentifier,
        schemaVersion: Int = YouziDomainSchema.currentVersion,
        document: YouziDomainDocument
    ) {
        self.formatIdentifier = formatIdentifier
        self.schemaVersion = schemaVersion
        self.document = document
    }
}

enum YouziDomainStoreError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(found: Int, supported: Int)
    case corruptFile(originalURL: URL, recoveryURL: URL?)
    case readFailed(url: URL, description: String)
    case writeFailed(url: URL, description: String)
}

extension YouziDomainStoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .unsupportedSchemaVersion(found, supported):
            return "Youzi data schema version \(found) is unsupported; this build supports version \(supported)."
        case let .corruptFile(originalURL, recoveryURL):
            if let recoveryURL {
                return "Youzi data at \(originalURL.path) is corrupt and was preserved at \(recoveryURL.path)."
            }
            return "Youzi data at \(originalURL.path) is corrupt and could not be moved aside."
        case let .readFailed(url, description):
            return "Could not read Youzi data at \(url.path): \(description)"
        case let .writeFailed(url, description):
            return "Could not save Youzi data at \(url.path): \(description)"
        }
    }
}

/// Synchronous, lock-protected repository for the shared Youzi metadata graph.
/// Callers can use ``update(_:)`` for one read/modify/atomic-save transaction.
final class YouziDomainStore: @unchecked Sendable {
    static let directoryName = "YouziDomain"
    static let fileName = "domain.json"

    let fileURL: URL

    private let lock = NSLock()
    private let fileManager: FileManager
    /// Test-only failure seam at the last point before the atomic temp write.
    /// Production leaves it nil; it lets lifecycle tests prove filesystem
    /// deletion never precedes a failed metadata commit.
    private let beforeAtomicReplace: (() throws -> Void)?

    init(
        fileURL: URL = YouziDomainStore.defaultFileURL(),
        fileManager: FileManager = .default,
        beforeAtomicReplace: (() throws -> Void)? = nil
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.beforeAtomicReplace = beforeAtomicReplace
    }

    static func defaultFileURL() -> URL {
        ApplicationSupportLocator.applicationSupportRoot()
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    /// Missing storage is the normal first-run state. Existing unreadable,
    /// unsupported, or malformed storage is never silently interpreted as empty.
    func load() throws -> YouziDomainDocument {
        lock.lock()
        defer { lock.unlock() }
        return try loadUnlocked()
    }

    func save(_ document: YouziDomainDocument) throws {
        lock.lock()
        defer { lock.unlock() }
        try saveUnlocked(document)
    }

    @discardableResult
    func update(
        _ mutation: (inout YouziDomainDocument) throws -> Void
    ) throws -> YouziDomainDocument {
        lock.lock()
        defer { lock.unlock() }

        var document = try loadUnlocked()
        try mutation(&document)
        try saveUnlocked(document)
        return document
    }

    private func loadUnlocked() throws -> YouziDomainDocument {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return .empty
        }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw YouziDomainStoreError.readFailed(
                url: fileURL,
                description: error.localizedDescription
            )
        }

        struct VersionProbe: Decodable {
            let formatIdentifier: String
            let schemaVersion: Int
        }

        let decoder = JSONDecoder()
        let probe: VersionProbe
        do {
            probe = try decoder.decode(VersionProbe.self, from: data)
        } catch {
            throw quarantineCorruptFile()
        }

        guard probe.formatIdentifier == YouziDomainSchema.formatIdentifier else {
            throw quarantineCorruptFile()
        }
        if probe.schemaVersion == 1 {
            let migrated: YouziDomainDocument
            do {
                migrated = try YouziDomainV1Migration.decode(data, decoder: decoder)
            } catch {
                throw quarantineCorruptFile()
            }
            // Atomic replacement is the migration commit point. If writing v2
            // fails, the original v1 inode is still present and the next load
            // can retry the same deterministic conversion.
            try saveUnlocked(migrated)
            return migrated
        }
        guard probe.schemaVersion == YouziDomainSchema.currentVersion else {
            throw YouziDomainStoreError.unsupportedSchemaVersion(
                found: probe.schemaVersion,
                supported: YouziDomainSchema.currentVersion
            )
        }

        do {
            return try decoder.decode(YouziDomainEnvelope.self, from: data).document
        } catch {
            throw quarantineCorruptFile()
        }
    }

    private func saveUnlocked(_ document: YouziDomainDocument) throws {
        let envelope = YouziDomainEnvelope(document: document)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data: Data
        do {
            data = try encoder.encode(envelope)
        } catch {
            throw YouziDomainStoreError.writeFailed(
                url: fileURL,
                description: error.localizedDescription
            )
        }

        let directory = fileURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
            try beforeAtomicReplace?()
            try replaceAtomicallyWithOwnerOnlyFile(data, in: directory)
        } catch let error as YouziDomainStoreError {
            throw error
        } catch {
            throw YouziDomainStoreError.writeFailed(
                url: fileURL,
                description: error.localizedDescription
            )
        }
    }

    /// Create a private temporary file beside the destination, fsync it, then
    /// use POSIX rename. Same-directory rename is the atomic commit point and
    /// preserves the temporary inode's 0600 mode even when replacing a file.
    private func replaceAtomicallyWithOwnerOnlyFile(_ data: Data, in directory: URL) throws {
        let temporaryURL = directory.appendingPathComponent(
            ".\(Self.fileName).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        var committed = false
        defer {
            if !committed {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }

        guard fileManager.createFile(
            atPath: temporaryURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw YouziDomainStoreError.writeFailed(
                url: fileURL,
                description: "Could not create the atomic temporary file."
            )
        }

        let handle = try FileHandle(forWritingTo: temporaryURL)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }

        let renameResult = temporaryURL.withUnsafeFileSystemRepresentation { source in
            fileURL.withUnsafeFileSystemRepresentation { destination in
                guard let source, let destination else { return Int32(-1) }
                return Darwin.rename(source, destination)
            }
        }
        guard renameResult == 0 else {
            let message = String(cString: strerror(errno))
            throw YouziDomainStoreError.writeFailed(url: fileURL, description: message)
        }
        committed = true
    }

    private func quarantineCorruptFile() -> YouziDomainStoreError {
        let stem = fileURL.deletingPathExtension().lastPathComponent
        let ext = fileURL.pathExtension.isEmpty ? "json" : fileURL.pathExtension
        let recoveryURL = fileURL.deletingLastPathComponent().appendingPathComponent(
            "\(stem).corrupt-\(UUID().uuidString).\(ext)",
            isDirectory: false
        )
        do {
            try fileManager.moveItem(at: fileURL, to: recoveryURL)
            try? fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: recoveryURL.path
            )
            return .corruptFile(originalURL: fileURL, recoveryURL: recoveryURL)
        } catch {
            return .corruptFile(originalURL: fileURL, recoveryURL: nil)
        }
    }
}
