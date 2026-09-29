import Darwin
import Foundation

struct YouziSkillPackageLimits: Equatable, Sendable {
    static let `default` = YouziSkillPackageLimits(
        maximumFileBytes: 1_048_576,
        maximumAggregateBytes: 8_388_608
    )

    let maximumFileBytes: Int
    let maximumAggregateBytes: Int

    init(maximumFileBytes: Int, maximumAggregateBytes: Int) {
        self.maximumFileBytes = maximumFileBytes
        self.maximumAggregateBytes = maximumAggregateBytes
    }
}

enum YouziSkillPackagePathProblem: String, Equatable, Sendable {
    case empty
    case absolute
    case nul
    case emptyComponent
    case dotComponent
    case parentTraversal
}

enum YouziSkillPackageError: Error, Equatable, Sendable {
    case invalidLimits
    case packageRootMustBeAbsoluteFileURL
    case packageRootUnavailable
    case packageRootIsSymbolicLink
    case packageRootIsNotDirectory
    case invalidRelativePath(YouziSkillPackagePathProblem)
    case duplicateDeclaredPath(relativePath: String)
    case pathEscapesPackage(relativePath: String)
    case pathContainsSymbolicLink(relativePath: String)
    case pathComponentIsNotDirectory(relativePath: String)
    case missingEntrypoint(relativePath: String)
    case missingResource(relativePath: String)
    case fileIsNotRegular(relativePath: String)
    case fileTooLarge(relativePath: String, maximumBytes: Int)
    case aggregateTooLarge(maximumBytes: Int)
    case invalidUTF8(relativePath: String)
    case undeclaredResource(relativePath: String)
    case fileReadFailed(relativePath: String)
}

extension YouziSkillPackageError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidLimits:
            return "The skill package size limits are not valid."
        case .packageRootMustBeAbsoluteFileURL:
            return "Choose a skill package folder on this Mac."
        case .packageRootUnavailable:
            return "That skill package folder is no longer available."
        case .packageRootIsSymbolicLink:
            return "Choose the original skill package folder instead of a link."
        case .packageRootIsNotDirectory:
            return "Choose a skill package folder, not an individual file."
        case .invalidRelativePath(let problem):
            switch problem {
            case .empty:
                return "A declared skill file path is empty."
            case .absolute:
                return "Skill files must use paths relative to their package."
            case .nul:
                return "A declared skill file path contains an invalid character."
            case .emptyComponent:
                return "A declared skill file path contains an empty component."
            case .dotComponent:
                return "A declared skill file path contains a dot component."
            case .parentTraversal:
                return "A declared skill file path tries to leave its package."
            }
        case .duplicateDeclaredPath:
            return "The same skill file is declared more than once."
        case .pathEscapesPackage:
            return "A declared skill file resolves outside its package."
        case .pathContainsSymbolicLink:
            return "Skill package files and folders cannot be symbolic links."
        case .pathComponentIsNotDirectory:
            return "A skill file path contains an item that is not a folder."
        case .missingEntrypoint:
            return "The skill package entrypoint is missing."
        case .missingResource:
            return "A declared skill resource is missing."
        case .fileIsNotRegular:
            return "Skill package content must be a regular file."
        case .fileTooLarge(_, let maximumBytes):
            return "A skill file exceeds the \(maximumBytes)-byte limit."
        case .aggregateTooLarge(let maximumBytes):
            return "The declared skill files exceed the \(maximumBytes)-byte package limit."
        case .invalidUTF8:
            return "Skill package text must use UTF-8 encoding."
        case .undeclaredResource:
            return "That file is not a declared skill resource."
        case .fileReadFailed:
            return "A declared skill file could not be read."
        }
    }
}

struct YouziSkillPackageFile: Equatable, Sendable {
    let relativePath: String
    let byteCount: Int
}

struct YouziSkillPackageManifest: Equatable, Sendable {
    /// The caller-selected root is retained so a bookmark-resolved URL keeps
    /// its security-scope identity across later explicit loads. It is
    /// deliberately not included in recovery error descriptions.
    let packageRoot: URL
    fileprivate let resolvedPackageRoot: URL
    let entrypoint: YouziSkillPackageFile
    let resources: [YouziSkillPackageFile]
    let aggregateByteCount: Int

    var entrypointPath: String { entrypoint.relativePath }
    var resourcePaths: [String] { resources.map(\.relativePath) }
}

struct YouziSkillPackageTextFile: Equatable, Sendable {
    let relativePath: String
    let contents: String
    let byteCount: Int
}

struct YouziSkillPackageSecurityScope: Sendable {
    let start: @Sendable (URL) -> Bool
    let stop: @Sendable (URL) -> Void

    static let foundation = YouziSkillPackageSecurityScope(
        start: { $0.startAccessingSecurityScopedResource() },
        stop: { $0.stopAccessingSecurityScopedResource() }
    )
}

/// Read-only filesystem boundary for declarative skill packages.
///
/// Discovery validates exactly the entrypoint and resource paths supplied by
/// the caller. It never enumerates the package and never interprets or launches
/// scripts. Loads repeat validation so a changed package fails closed.
///
/// Path validation and descriptor validation substantially narrow filesystem
/// races, but Foundation does not expose a portable `openat` walk with pinned
/// directory descriptors. The caller must keep the selected package root stable
/// for the duration of a discovery or load operation.
struct YouziSkillPackageService: @unchecked Sendable {
    private enum DeclaredFileKind {
        case entrypoint
        case resource
    }

    private let limits: YouziSkillPackageLimits
    private let fileManager: FileManager
    private let securityScope: YouziSkillPackageSecurityScope

    init(
        limits: YouziSkillPackageLimits = .default,
        fileManager: FileManager = FileManager(),
        securityScope: YouziSkillPackageSecurityScope = .foundation
    ) {
        self.limits = limits
        self.fileManager = fileManager
        self.securityScope = securityScope
    }

    func discoverPackage(
        at packageRoot: URL,
        entrypoint: String = "SKILL.md",
        resourcePaths: [String] = []
    ) throws -> YouziSkillPackageManifest {
        try withSecurityScopedAccess(to: packageRoot) {
            try discoverPackageWithActiveAccess(
                at: packageRoot,
                entrypoint: entrypoint,
                resourcePaths: resourcePaths
            )
        }
    }

    private func discoverPackageWithActiveAccess(
        at packageRoot: URL,
        entrypoint: String,
        resourcePaths: [String]
    ) throws -> YouziSkillPackageManifest {
        try validateLimits()
        let root = try validatedRoot(packageRoot)
        let normalizedEntrypoint = try normalize(relativePath: entrypoint)
        let normalizedResources = try resourcePaths
            .map(normalize(relativePath:))
            .sorted()

        var declared = Set<String>()
        guard declared.insert(normalizedEntrypoint).inserted else {
            throw YouziSkillPackageError.duplicateDeclaredPath(
                relativePath: normalizedEntrypoint
            )
        }
        for path in normalizedResources where !declared.insert(path).inserted {
            throw YouziSkillPackageError.duplicateDeclaredPath(relativePath: path)
        }

        let entrypointText = try readTextFile(
            normalizedEntrypoint,
            kind: .entrypoint,
            beneath: root
        )
        var aggregateByteCount = try addingToAggregate(
            entrypointText.byteCount,
            current: 0
        )
        var resources: [YouziSkillPackageFile] = []
        resources.reserveCapacity(normalizedResources.count)
        for path in normalizedResources {
            let text = try readTextFile(path, kind: .resource, beneath: root)
            aggregateByteCount = try addingToAggregate(
                text.byteCount,
                current: aggregateByteCount
            )
            resources.append(
                YouziSkillPackageFile(relativePath: path, byteCount: text.byteCount)
            )
        }

        return YouziSkillPackageManifest(
            packageRoot: packageRoot,
            resolvedPackageRoot: root,
            entrypoint: YouziSkillPackageFile(
                relativePath: normalizedEntrypoint,
                byteCount: entrypointText.byteCount
            ),
            resources: resources,
            aggregateByteCount: aggregateByteCount
        )
    }

    func loadEntrypoint(
        from package: YouziSkillPackageManifest
    ) throws -> YouziSkillPackageTextFile {
        try withSecurityScopedAccess(to: package.packageRoot) {
            let refreshed = try discoverPackageWithActiveAccess(
                at: package.packageRoot,
                entrypoint: package.entrypointPath,
                resourcePaths: package.resourcePaths
            )
            return try readTextFile(
                refreshed.entrypointPath,
                kind: .entrypoint,
                beneath: refreshed.resolvedPackageRoot
            )
        }
    }

    func loadResource(
        _ relativePath: String,
        from package: YouziSkillPackageManifest
    ) throws -> YouziSkillPackageTextFile {
        let normalized = try normalize(relativePath: relativePath)
        guard package.resourcePaths.contains(normalized) else {
            throw YouziSkillPackageError.undeclaredResource(relativePath: normalized)
        }
        return try withSecurityScopedAccess(to: package.packageRoot) {
            let refreshed = try discoverPackageWithActiveAccess(
                at: package.packageRoot,
                entrypoint: package.entrypointPath,
                resourcePaths: package.resourcePaths
            )
            guard refreshed.resourcePaths.contains(normalized) else {
                // Rediscovery normally reports the more precise changed-package
                // error first. This guard pins the declared-only load invariant.
                throw YouziSkillPackageError.undeclaredResource(relativePath: normalized)
            }
            return try readTextFile(
                normalized,
                kind: .resource,
                beneath: refreshed.resolvedPackageRoot
            )
        }
    }

    private func validateLimits() throws {
        guard limits.maximumFileBytes > 0,
              limits.maximumAggregateBytes > 0 else {
            throw YouziSkillPackageError.invalidLimits
        }
    }

    private func normalize(relativePath: String) throws -> String {
        guard !relativePath.isEmpty else {
            throw YouziSkillPackageError.invalidRelativePath(.empty)
        }
        guard !relativePath.contains("\0") else {
            throw YouziSkillPackageError.invalidRelativePath(.nul)
        }
        guard !(relativePath as NSString).isAbsolutePath,
              !relativePath.lowercased().hasPrefix("file:") else {
            throw YouziSkillPackageError.invalidRelativePath(.absolute)
        }

        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        var normalized: [Substring] = []
        normalized.reserveCapacity(components.count)
        for component in components {
            if component.isEmpty {
                throw YouziSkillPackageError.invalidRelativePath(.emptyComponent)
            }
            if component == "." {
                throw YouziSkillPackageError.invalidRelativePath(.dotComponent)
            }
            if component == ".." {
                throw YouziSkillPackageError.invalidRelativePath(.parentTraversal)
            }
            normalized.append(component)
        }
        return normalized.joined(separator: "/")
    }

    private func validatedRoot(_ suppliedRoot: URL) throws -> URL {
        guard suppliedRoot.isFileURL,
              suppliedRoot.path.hasPrefix("/") else {
            throw YouziSkillPackageError.packageRootMustBeAbsoluteFileURL
        }
        let standardized = suppliedRoot.standardizedFileURL
        guard let type = itemType(at: standardized) else {
            throw YouziSkillPackageError.packageRootUnavailable
        }
        guard type != .typeSymbolicLink else {
            throw YouziSkillPackageError.packageRootIsSymbolicLink
        }
        guard type == .typeDirectory else {
            throw YouziSkillPackageError.packageRootIsNotDirectory
        }

        // Resolve only ancestors of the explicitly selected, non-link leaf.
        // This keeps ordinary macOS `/tmp` -> `/private/tmp` roots usable while
        // giving containment checks one canonical boundary.
        let canonical = standardized.resolvingSymlinksInPath().standardizedFileURL
        guard itemType(at: canonical) == .typeDirectory else {
            throw YouziSkillPackageError.packageRootUnavailable
        }
        return canonical
    }

    private func readTextFile(
        _ relativePath: String,
        kind: DeclaredFileKind,
        beneath root: URL
    ) throws -> YouziSkillPackageTextFile {
        let fileURL = try validatedFileURL(relativePath, kind: kind, beneath: root)
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: fileURL)
        } catch {
            throw YouziSkillPackageError.fileReadFailed(relativePath: relativePath)
        }
        defer { try? handle.close() }

        var info = stat()
        guard fstat(handle.fileDescriptor, &info) == 0 else {
            throw YouziSkillPackageError.fileReadFailed(relativePath: relativePath)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw YouziSkillPackageError.fileIsNotRegular(relativePath: relativePath)
        }
        if info.st_size > limits.maximumFileBytes {
            throw YouziSkillPackageError.fileTooLarge(
                relativePath: relativePath,
                maximumBytes: limits.maximumFileBytes
            )
        }

        var data = Data()
        data.reserveCapacity(max(0, Int(info.st_size)))
        do {
            while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
                guard chunk.count <= limits.maximumFileBytes - data.count else {
                    throw YouziSkillPackageError.fileTooLarge(
                        relativePath: relativePath,
                        maximumBytes: limits.maximumFileBytes
                    )
                }
                data.append(chunk)
            }
        } catch let error as YouziSkillPackageError {
            throw error
        } catch {
            throw YouziSkillPackageError.fileReadFailed(relativePath: relativePath)
        }
        guard let contents = String(data: data, encoding: .utf8) else {
            throw YouziSkillPackageError.invalidUTF8(relativePath: relativePath)
        }
        return YouziSkillPackageTextFile(
            relativePath: relativePath,
            contents: contents,
            byteCount: data.count
        )
    }

    private func validatedFileURL(
        _ relativePath: String,
        kind: DeclaredFileKind,
        beneath root: URL
    ) throws -> URL {
        let components = relativePath.split(separator: "/").map(String.init)
        var candidate = root
        for (index, component) in components.enumerated() {
            candidate.appendPathComponent(component, isDirectory: index < components.count - 1)
            guard let type = itemType(at: candidate) else {
                throw missingError(for: kind, relativePath: relativePath)
            }
            if type == .typeSymbolicLink {
                throw YouziSkillPackageError.pathContainsSymbolicLink(
                    relativePath: relativePath
                )
            }
            if index < components.count - 1, type != .typeDirectory {
                throw YouziSkillPackageError.pathComponentIsNotDirectory(
                    relativePath: relativePath
                )
            }
            if index == components.count - 1, type != .typeRegular {
                throw YouziSkillPackageError.fileIsNotRegular(relativePath: relativePath)
            }
        }

        let standardized = candidate.standardizedFileURL
        guard isSameOrDescendant(standardized, of: root) else {
            throw YouziSkillPackageError.pathEscapesPackage(relativePath: relativePath)
        }
        let resolved = standardized.resolvingSymlinksInPath().standardizedFileURL
        guard isSameOrDescendant(resolved, of: root) else {
            throw YouziSkillPackageError.pathEscapesPackage(relativePath: relativePath)
        }
        return standardized
    }

    private func missingError(
        for kind: DeclaredFileKind,
        relativePath: String
    ) -> YouziSkillPackageError {
        switch kind {
        case .entrypoint:
            return .missingEntrypoint(relativePath: relativePath)
        case .resource:
            return .missingResource(relativePath: relativePath)
        }
    }

    private func addingToAggregate(_ count: Int, current: Int) throws -> Int {
        guard count <= limits.maximumAggregateBytes - current else {
            throw YouziSkillPackageError.aggregateTooLarge(
                maximumBytes: limits.maximumAggregateBytes
            )
        }
        return current + count
    }

    private func withSecurityScopedAccess<Result>(
        to packageRoot: URL,
        _ operation: () throws -> Result
    ) rethrows -> Result {
        let didStart = securityScope.start(packageRoot)
        defer {
            if didStart {
                securityScope.stop(packageRoot)
            }
        }
        return try operation()
    }

    private func itemType(at url: URL) -> FileAttributeType? {
        (try? fileManager.attributesOfItem(atPath: url.path)[.type]) as? FileAttributeType
    }

    private func isSameOrDescendant(_ candidate: URL, of ancestor: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let ancestorPath = ancestor.standardizedFileURL.path
        if candidatePath == ancestorPath { return true }
        let prefix = ancestorPath == "/" ? "/" : ancestorPath + "/"
        return candidatePath.hasPrefix(prefix)
    }
}
