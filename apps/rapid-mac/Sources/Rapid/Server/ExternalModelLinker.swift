import CryptoKit
import Darwin
import Foundation

/// Installs a single, user-selected MLX model as an app-managed symbolic link.
///
/// This helper deliberately knows nothing about the global Hugging Face cache
/// preference. Callers provide a dedicated links directory and receive the
/// exact link URL to register with the catalog/launch layer. Keeping that
/// boundary explicit prevents a one-model import from becoming a whole-cache
/// redirect.
enum ExternalModelLinker {
    static let managedLinkPrefix = "youzi-external-"

    enum LinkOutcome: Equatable {
        case linked(URL)
        case alreadyLinked(URL)
    }

    enum RemovalOutcome: Equatable {
        case removed
    }

    enum LinkError: Error, Equatable, LocalizedError {
        case sourceMustBeAbsolute
        case sourceMissing
        case sourceIsNotDirectory
        case sourceIsSymbolicLink
        case sourceIsCacheRoot
        case missingManifest
        case invalidManifest
        case missingWeights
        case invalidWeightIndex
        case unsafeModelTree
        case linksDirectoryMustBeAbsolute
        case linksDirectoryIsNotDirectory
        case sourceAndLinksDirectoryOverlap
        case targetCollision
        case danglingTarget
        case linkNotFound
        case unmanagedLink
        case fileSystem(operation: String, message: String)

        var errorDescription: String? {
            switch self {
            case .sourceMustBeAbsolute:
                return "Choose a model folder on this Mac."
            case .sourceMissing:
                return "That model folder is no longer available."
            case .sourceIsNotDirectory:
                return "Choose a model folder, not an individual file."
            case .sourceIsSymbolicLink:
                return "Choose the original model folder instead of another link."
            case .sourceIsCacheRoot:
                return "Choose one model folder, not an entire model cache."
            case .missingManifest:
                return "That folder does not contain a config.json model manifest."
            case .invalidManifest:
                return "The model's config.json manifest is not valid."
            case .missingWeights:
                return "That folder does not contain a complete set of model weights."
            case .invalidWeightIndex:
                return "The model's weight index is not valid."
            case .unsafeModelTree:
                return "The model contains a link outside its trusted model directory."
            case .linksDirectoryMustBeAbsolute:
                return "The linked-models location is not valid."
            case .linksDirectoryIsNotDirectory:
                return "The linked-models location is not a folder."
            case .sourceAndLinksDirectoryOverlap:
                return "The model and linked-models folders cannot contain each other."
            case .targetCollision:
                return "A different item already uses this linked-model name."
            case .danglingTarget:
                return "An existing linked model points to a folder that is unavailable."
            case .linkNotFound:
                return "That linked model no longer exists."
            case .unmanagedLink:
                return "Youzi can remove only links that it manages."
            case .fileSystem(let operation, let message):
                return "Could not \(operation): \(message)"
            }
        }
    }

    /// Validate and create exactly one symlink beneath `linksDirectory`.
    ///
    /// Existing files/directories/other links are never replaced. A matching
    /// link is an idempotent success, while a dangling link is surfaced for an
    /// explicit user decision instead of being silently repointed.
    static func linkModel(
        at sourceDirectory: URL,
        into linksDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> LinkOutcome {
        let source = try validateModelDirectory(sourceDirectory, fileManager: fileManager)
        let links = try prepareLinksDirectory(
            linksDirectory,
            source: source,
            fileManager: fileManager
        )
        let link = links.appendingPathComponent(
            targetName(forCanonicalSource: source),
            isDirectory: true
        )

        if let type = itemType(at: link, fileManager: fileManager) {
            guard type == .typeSymbolicLink else {
                throw LinkError.targetCollision
            }
            let existing = try symbolicLinkDestination(
                at: link,
                requireExistingDirectory: true,
                fileManager: fileManager
            )
            guard existing == source else {
                throw LinkError.targetCollision
            }
            return .alreadyLinked(link)
        }

        do {
            try fileManager.createSymbolicLink(at: link, withDestinationURL: source)
        } catch {
            // `symlink(2)` is the final no-overwrite gate if another process
            // races us after the lstat-style item check above.
            if itemType(at: link, fileManager: fileManager) != nil {
                throw LinkError.targetCollision
            }
            throw LinkError.fileSystem(
                operation: "link the model",
                message: error.localizedDescription
            )
        }
        return .linked(link)
    }

    /// Resolve an app-managed link to the selected model directory.
    /// Re-validating here makes discovery fail closed if source data changed
    /// after the link was installed.
    static func destinationOfManagedLink(
        at linkURL: URL,
        in linksDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        try requireDirectManagedChild(linkURL, of: linksDirectory)
        guard let type = itemType(at: linkURL, fileManager: fileManager) else {
            throw LinkError.linkNotFound
        }
        guard type == .typeSymbolicLink else {
            throw LinkError.unmanagedLink
        }
        let destination = try symbolicLinkDestination(
            at: linkURL,
            requireExistingDirectory: true,
            fileManager: fileManager
        )
        let validated = try validateModelDirectory(destination, fileManager: fileManager)
        guard linkURL.lastPathComponent == targetName(forCanonicalSource: validated) else {
            throw LinkError.unmanagedLink
        }
        return validated
    }

    /// Remove only the symlink entry itself. The source directory is never
    /// passed to `removeItem`, even when the managed link is dangling.
    @discardableResult
    static func removeManagedLink(
        at linkURL: URL,
        from linksDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> RemovalOutcome {
        try requireDirectManagedChild(linkURL, of: linksDirectory)
        guard let type = itemType(at: linkURL, fileManager: fileManager) else {
            throw LinkError.linkNotFound
        }
        guard type == .typeSymbolicLink else {
            throw LinkError.unmanagedLink
        }
        do {
            try fileManager.removeItem(at: linkURL)
        } catch {
            throw LinkError.fileSystem(
                operation: "remove the model link",
                message: error.localizedDescription
            )
        }
        return .removed
    }

    /// Direct app-managed symlinks currently present in `linksDirectory`.
    ///
    /// Enumeration deliberately does not resolve the destinations. A dangling
    /// link must remain visible to Settings so the user can forget it safely;
    /// callers that advertise a link to the engine separately revalidate it
    /// through ``destinationOfManagedLink``.
    static func managedLinkURLs(
        in linksDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> [URL] {
        guard linksDirectory.isFileURL,
              linksDirectory.path.hasPrefix("/") else {
            throw LinkError.linksDirectoryMustBeAbsolute
        }
        let root = linksDirectory.standardizedFileURL
        guard let rootType = itemType(at: root, fileManager: fileManager) else {
            return []
        }
        guard rootType == .typeDirectory else {
            throw LinkError.linksDirectoryIsNotDirectory
        }
        let children: [URL]
        do {
            children = try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw LinkError.fileSystem(
                operation: "read the linked-models folder",
                message: error.localizedDescription
            )
        }
        return children.filter {
            isManagedLinkName($0.lastPathComponent)
                && itemType(at: $0, fileManager: fileManager) == .typeSymbolicLink
        }.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                == .orderedAscending
        }
    }

    /// Stable, filesystem-safe link name. The readable stem is diagnostic;
    /// canonical-path SHA-256 identity prevents same-named folders on two
    /// disks from colliding.
    static func targetName(for sourceDirectory: URL) -> String {
        let canonical = sourceDirectory.standardizedFileURL.resolvingSymlinksInPath()
        return targetName(forCanonicalSource: canonical)
    }

    /// Validate one directly loadable MLX/Hugging Face snapshot directory.
    /// A cache root fails before any destination path is created.
    static func validateModelDirectory(
        _ sourceDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard sourceDirectory.isFileURL,
              sourceDirectory.path.hasPrefix("/") else {
            throw LinkError.sourceMustBeAbsolute
        }
        let source = sourceDirectory.standardizedFileURL
        guard let type = itemType(at: source, fileManager: fileManager) else {
            throw LinkError.sourceMissing
        }
        if type == .typeSymbolicLink {
            // Avoid link chains and the self/cycle ambiguity they introduce.
            throw LinkError.sourceIsSymbolicLink
        }
        guard type == .typeDirectory else {
            throw LinkError.sourceIsNotDirectory
        }

        let canonical = source.resolvingSymlinksInPath()
        if try looksLikeWholeCache(canonical, fileManager: fileManager) {
            throw LinkError.sourceIsCacheRoot
        }
        let manifest = canonical.appendingPathComponent("config.json", isDirectory: false)
        guard itemType(at: manifest, fileManager: fileManager) != nil else {
            throw LinkError.missingManifest
        }
        let children: [URL]
        do {
            children = try fileManager.contentsOfDirectory(
                at: canonical,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw LinkError.fileSystem(
                operation: "read the model folder",
                message: error.localizedDescription
            )
        }
        let rootWeights = children.filter {
            $0.lastPathComponent.hasPrefix("model")
                && $0.lastPathComponent.hasSuffix(".safetensors")
        }
        let index = canonical.appendingPathComponent(
            "model.safetensors.index.json",
            isDirectory: false
        )
        guard !rootWeights.isEmpty || itemType(at: index, fileManager: fileManager) != nil else {
            throw LinkError.missingWeights
        }

        // Only walk the complete tree after the bounded root checks above.
        // Selecting a broad OMLX/cache parent should fail in O(1) directory
        // work, not recursively inspect every downloaded model.
        try validateContainedSymlinks(in: canonical, fileManager: fileManager)
        guard try isNonemptyRegularFile(manifest, fileManager: fileManager),
              let object = try? JSONSerialization.jsonObject(with: Data(contentsOf: manifest)),
              object is [String: Any] else {
            throw LinkError.invalidManifest
        }
        if itemType(at: index, fileManager: fileManager) != nil {
            try validateWeightIndex(index, in: canonical, fileManager: fileManager)
        }
        guard try rootWeights.allSatisfy({
            try isNonemptyRegularFile($0, fileManager: fileManager)
        }) else {
            throw LinkError.missingWeights
        }
        return canonical
    }

    private static func prepareLinksDirectory(
        _ linksDirectory: URL,
        source: URL,
        fileManager: FileManager
    ) throws -> URL {
        guard linksDirectory.isFileURL,
              linksDirectory.path.hasPrefix("/") else {
            throw LinkError.linksDirectoryMustBeAbsolute
        }
        let standardized = linksDirectory.standardizedFileURL
        let prospective = standardized.resolvingSymlinksInPath()
        guard !pathsOverlap(source, prospective) else {
            throw LinkError.sourceAndLinksDirectoryOverlap
        }
        if let type = itemType(at: standardized, fileManager: fileManager) {
            guard type == .typeDirectory else {
                throw LinkError.linksDirectoryIsNotDirectory
            }
        } else {
            do {
                try fileManager.createDirectory(
                    at: standardized,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw LinkError.fileSystem(
                    operation: "create the linked-models folder",
                    message: error.localizedDescription
                )
            }
        }
        let canonical = standardized.resolvingSymlinksInPath()
        guard !pathsOverlap(source, canonical) else {
            throw LinkError.sourceAndLinksDirectoryOverlap
        }
        return canonical
    }

    private static func symbolicLinkDestination(
        at linkURL: URL,
        requireExistingDirectory: Bool,
        fileManager: FileManager
    ) throws -> URL {
        let raw: String
        do {
            raw = try fileManager.destinationOfSymbolicLink(atPath: linkURL.path)
        } catch {
            throw LinkError.fileSystem(
                operation: "read the model link",
                message: error.localizedDescription
            )
        }
        let unresolved: URL
        if raw.hasPrefix("/") {
            unresolved = URL(fileURLWithPath: raw, isDirectory: true)
        } else {
            unresolved = linkURL.deletingLastPathComponent()
                .appendingPathComponent(raw, isDirectory: true)
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: unresolved.path, isDirectory: &isDirectory),
              (!requireExistingDirectory || isDirectory.boolValue) else {
            throw LinkError.danglingTarget
        }
        return unresolved.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func requireDirectManagedChild(_ linkURL: URL, of linksDirectory: URL) throws {
        guard linkURL.isFileURL, linksDirectory.isFileURL else {
            throw LinkError.unmanagedLink
        }
        let link = linkURL.standardizedFileURL
        let root = linksDirectory.standardizedFileURL
        guard link.deletingLastPathComponent() == root,
              isManagedLinkName(link.lastPathComponent) else {
            throw LinkError.unmanagedLink
        }
    }

    static func isManagedLinkName(_ name: String) -> Bool {
        guard name.hasPrefix(managedLinkPrefix),
              let suffix = name.split(separator: "-").last,
              suffix.count == 16 else { return false }
        return suffix.allSatisfy { $0.isHexDigit }
    }

    private static func targetName(forCanonicalSource source: URL) -> String {
        let rawStem = source.lastPathComponent.lowercased()
        var stem = ""
        var previousWasSeparator = false
        for scalar in rawStem.unicodeScalars {
            let allowed = scalar.isASCII
                && (CharacterSet.alphanumerics.contains(scalar)
                    || scalar == "." || scalar == "_" || scalar == "-")
            if allowed {
                stem.unicodeScalars.append(scalar)
                previousWasSeparator = false
            } else if !previousWasSeparator {
                stem.append("-")
                previousWasSeparator = true
            }
        }
        stem = stem.trimmingCharacters(in: CharacterSet(charactersIn: ".-_"))
        if stem.isEmpty { stem = "model" }
        stem = String(stem.prefix(48))

        let digest = SHA256.hash(data: Data(source.path.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        return managedLinkPrefix + stem + "-" + digest
    }

    private static func validateWeightIndex(
        _ index: URL,
        in source: URL,
        fileManager: FileManager
    ) throws {
        guard try isNonemptyRegularFile(index, fileManager: fileManager),
              let object = try? JSONSerialization.jsonObject(with: Data(contentsOf: index)),
              let root = object as? [String: Any],
              let weightMap = root["weight_map"] as? [String: Any],
              !weightMap.isEmpty else {
            throw LinkError.invalidWeightIndex
        }
        let shardValues = weightMap.values.compactMap { $0 as? String }
        guard shardValues.count == weightMap.count else {
            throw LinkError.invalidWeightIndex
        }
        let shards = Set(shardValues)
        guard !shards.isEmpty else { throw LinkError.invalidWeightIndex }
        for shard in shards {
            guard shard == (shard as NSString).lastPathComponent,
                  shard.hasPrefix("model"),
                  shard.hasSuffix(".safetensors") else {
                throw LinkError.invalidWeightIndex
            }
            let shardURL = source.appendingPathComponent(shard, isDirectory: false)
            guard try isNonemptyRegularFile(shardURL, fileManager: fileManager) else {
                throw LinkError.missingWeights
            }
        }
    }

    private static func isNonemptyRegularFile(
        _ url: URL,
        fileManager: FileManager
    ) throws -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFREG && info.st_size > 0
    }

    private static func looksLikeWholeCache(
        _ source: URL,
        fileManager: FileManager
    ) throws -> Bool {
        let names: [String]
        do {
            names = try fileManager.contentsOfDirectory(atPath: source.path)
        } catch {
            throw LinkError.fileSystem(
                operation: "read the selected folder",
                message: error.localizedDescription
            )
        }
        return names.contains {
            $0.hasPrefix("models--") || $0.hasPrefix("datasets--") || $0.hasPrefix("spaces--")
        }
    }

    private static func validateContainedSymlinks(
        in source: URL,
        fileManager: FileManager
    ) throws {
        let boundary = trustedBoundary(for: source)
        var traversalFailed = false
        guard let enumerator = fileManager.enumerator(
            at: source,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, _ in
                traversalFailed = true
                return false
            }
        ) else {
            throw LinkError.unsafeModelTree
        }
        while let item = enumerator.nextObject() as? URL {
            guard itemType(at: item, fileManager: fileManager) == .typeSymbolicLink else {
                continue
            }
            let raw: String
            do {
                raw = try fileManager.destinationOfSymbolicLink(atPath: item.path)
            } catch {
                throw LinkError.unsafeModelTree
            }
            let unresolved = raw.hasPrefix("/")
                ? URL(fileURLWithPath: raw)
                : item.deletingLastPathComponent().appendingPathComponent(raw)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: unresolved.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                throw LinkError.unsafeModelTree
            }
            let resolved = unresolved.standardizedFileURL.resolvingSymlinksInPath()
            guard isSameOrDescendant(resolved, of: boundary) else {
                throw LinkError.unsafeModelTree
            }
        }
        guard !traversalFailed else { throw LinkError.unsafeModelTree }
    }

    /// Standard HF snapshot leaves point to `<models--repo>/blobs`; allow
    /// those only when the selected directory has the canonical
    /// `<models--repo>/snapshots/<revision>` shape. Flat MLX folders must be
    /// fully self-contained.
    private static func trustedBoundary(for source: URL) -> URL {
        let snapshots = source.deletingLastPathComponent()
        let repository = snapshots.deletingLastPathComponent()
        if snapshots.lastPathComponent == "snapshots",
           repository.lastPathComponent.hasPrefix("models--") {
            return repository.standardizedFileURL.resolvingSymlinksInPath()
        }
        return source
    }

    private static func pathsOverlap(_ first: URL, _ second: URL) -> Bool {
        isSameOrDescendant(first, of: second) || isSameOrDescendant(second, of: first)
    }

    private static func isSameOrDescendant(_ candidate: URL, of ancestor: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let ancestorPath = ancestor.standardizedFileURL.path
        if candidatePath == ancestorPath { return true }
        let prefix = ancestorPath == "/" ? "/" : ancestorPath + "/"
        return candidatePath.hasPrefix(prefix)
    }

    /// `attributesOfItem` has lstat-like behavior at the leaf on Darwin, so
    /// it sees dangling links that `fileExists` intentionally follows past.
    private static func itemType(at url: URL, fileManager: FileManager) -> FileAttributeType? {
        (try? fileManager.attributesOfItem(atPath: url.path)[.type]) as? FileAttributeType
    }
}
