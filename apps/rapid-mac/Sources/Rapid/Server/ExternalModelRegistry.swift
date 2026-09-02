import Foundation

/// App-owned registry for individually linked external MLX checkpoints.
///
/// The registry is the directory of symlinks itself; there is no second index
/// that can drift from the filesystem. Only exact, revalidated managed links
/// cross the process boundary. In particular, neither a selected model's
/// parent nor the managed-links directory is advertised as a scan root.
enum ExternalModelRegistry {
    static let environmentKey = "RAPID_MLX_EXACT_MODEL_LINKS"
    static let folderName = "LinkedModels"

    struct Record: Identifiable, Equatable, Sendable {
        enum Availability: Equatable, Sendable {
            case available(destination: URL)
            case unavailable
        }

        let linkURL: URL
        let availability: Availability

        var id: String { alias }
        var alias: String { linkURL.lastPathComponent }
        var isAvailable: Bool {
            if case .available = availability { return true }
            return false
        }
    }

    static func linksDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        ApplicationSupportLocator.applicationSupportRoot(environment: environment)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    /// All managed links, including dangling/invalid ones that Settings must
    /// still be able to forget. Invalid entries never reach the engine value.
    static func records(
        in linksDirectory: URL = linksDirectory(),
        fileManager: FileManager = .default
    ) throws -> [Record] {
        try ExternalModelLinker.managedLinkURLs(
            in: linksDirectory,
            fileManager: fileManager
        ).map { link in
            do {
                let destination = try ExternalModelLinker.destinationOfManagedLink(
                    at: link,
                    in: linksDirectory,
                    fileManager: fileManager
                )
                return Record(linkURL: link, availability: .available(destination: destination))
            } catch {
                return Record(linkURL: link, availability: .unavailable)
            }
        }
    }

    /// Deterministic strict JSON list consumed by rapid-mlx inventory and
    /// resolution. Values are exact managed link paths, never source paths.
    static func encodedEnvironmentValue(
        in linksDirectory: URL = linksDirectory(),
        fileManager: FileManager = .default
    ) -> String? {
        guard let records = try? records(in: linksDirectory, fileManager: fileManager) else {
            return nil
        }
        let paths = records.compactMap { record -> String? in
            guard record.isAvailable else { return nil }
            return record.linkURL.standardizedFileURL.path
        }.sorted()
        guard !paths.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: paths),
              let encoded = String(data: data, encoding: .utf8) else {
            return nil
        }
        return encoded
    }
}
