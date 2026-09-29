import CryptoKit
import Foundation

enum YouziBundledCapabilityCatalogError: Error, Equatable, Sendable {
    case catalogUnavailable
    case catalogIsNotRegularFile
    case catalogTooLarge(maximumBytes: Int)
    case catalogUnreadable
    case invalidCatalog
    case unsupportedSchemaVersion(Int)
    case invalidCatalogVersion
    case invalidSkill(UUID)
    case invalidHelper(UUID)
    case duplicateSkillID(UUID)
    case duplicateSkillSlug(String)
    case duplicateHelperID(UUID)
    case duplicateHelperSlug(String)
    case missingRecommendedSkill(helperID: UUID, skillID: UUID)
    case packagesRootUnavailable
    case invalidPackage(skillID: UUID)
}

struct YouziBundledCapabilityContent: Equatable, Sendable {
    let catalogVersion: String
    let helpers: [YouziHelper]
    let skills: [YouziSkill]
    let skillPackages: [YouziSkillPackageRecord]
    /// Validated declarative entrypoint text keyed by the stable skill ID.
    /// This is runtime input only; instructions are never duplicated into the
    /// durable domain document or interpreted as executable code.
    let instructionComponents: [UUID: String]

    var capabilitySeed: YouziCapabilitySeed {
        YouziCapabilitySeed(
            helpers: helpers,
            skills: skills,
            skillPackages: skillPackages
        )
    }
}

/// Loads the product-owned helper and skill catalog without granting any
/// capability. Skill packages remain declarative text: the package service
/// validates and reads only the catalog-declared files and never executes a
/// script found beside them.
struct YouziBundledCapabilityCatalogLoader: @unchecked Sendable {
    private static let supportedSchemaVersion = 1
    private static let maximumCatalogBytes = 1_048_576

    private let catalogURL: URL?
    private let packagesRootURL: URL?
    private let fileManager: FileManager
    private let packageService: YouziSkillPackageService

    init(
        catalogURL: URL? = nil,
        packagesRootURL: URL? = nil,
        fileManager: FileManager = FileManager(),
        packageService: YouziSkillPackageService = YouziSkillPackageService()
    ) {
        self.catalogURL = catalogURL
        self.packagesRootURL = packagesRootURL
        self.fileManager = fileManager
        self.packageService = packageService
    }

    func load(at date: Date = Date()) throws -> YouziBundledCapabilityContent {
        let catalogURL = try resolvedCatalogURL()
        let packagesRootURL = try resolvedPackagesRootURL()
        let catalog = try decodeCatalog(at: catalogURL)
        try validate(catalog)

        let skills = catalog.skills.map { descriptor in
            YouziSkill(
                id: descriptor.id,
                name: descriptor.name,
                summary: descriptor.summary,
                packageVersion: descriptor.packageVersion,
                entrypoint: descriptor.entrypoint,
                resourcePaths: descriptor.resourcePaths,
                executionLocation: descriptor.executionLocation,
                requestedPermissions: descriptor.requestedPermissions,
                connectorDependencyIDs: [],
                requiresFirstUseConfirmation: descriptor.requiresFirstUseConfirmation,
                source: YouziManifestSource(
                    kind: .builtIn,
                    identifier: "youzi.builtin.skill.\(descriptor.slug)",
                    version: descriptor.packageVersion
                ),
                createdAt: date,
                updatedAt: date
            )
        }

        let helpers = catalog.helpers.map { descriptor in
            YouziHelper(
                id: descriptor.id,
                name: descriptor.name,
                summary: descriptor.summary,
                systemInstructions: descriptor.systemInstructions,
                methodology: descriptor.methodology,
                recommendedSkillIDs: descriptor.recommendedSkillIDs,
                allowedConnectorIDs: [],
                preferredOutputTypes: descriptor.preferredOutputTypes,
                source: YouziManifestSource(
                    kind: .builtIn,
                    identifier: "youzi.builtin.helper.\(descriptor.slug)",
                    version: catalog.catalogVersion
                ),
                createdAt: date,
                updatedAt: date
            )
        }

        var instructionComponents: [UUID: String] = [:]
        let packages = try catalog.skills.map { descriptor in
            let root = packagesRootURL.appendingPathComponent(
                descriptor.slug,
                isDirectory: true
            )
            let manifest: YouziSkillPackageManifest
            do {
                manifest = try packageService.discoverPackage(
                    at: root,
                    entrypoint: descriptor.entrypoint,
                    resourcePaths: descriptor.resourcePaths
                )
            } catch {
                throw YouziBundledCapabilityCatalogError.invalidPackage(
                    skillID: descriptor.id
                )
            }
            let digest: String
            do {
                instructionComponents[descriptor.id] = try packageService
                    .loadEntrypoint(from: manifest).contents
                digest = try contentDigest(for: manifest)
            } catch {
                throw YouziBundledCapabilityCatalogError.invalidPackage(
                    skillID: descriptor.id
                )
            }
            return YouziSkillPackageRecord(
                id: descriptor.id,
                location: .bundled(resourcePath: "YouziSkills/\(descriptor.slug)"),
                packageVersion: descriptor.packageVersion,
                contentSHA256: digest,
                installedAt: date,
                verifiedAt: date,
                updatedAt: date
            )
        }

        return YouziBundledCapabilityContent(
            catalogVersion: catalog.catalogVersion,
            helpers: helpers,
            skills: skills,
            skillPackages: packages,
            instructionComponents: instructionComponents
        )
    }

    private func resolvedCatalogURL() throws -> URL {
        if let catalogURL { return catalogURL }
        if let main = Bundle.main.url(
            forResource: "youzi-capabilities-v1",
            withExtension: "json"
        ) {
            return main
        }
        if let module = Bundle.module.url(
            forResource: "youzi-capabilities-v1",
            withExtension: "json"
        ) {
            return module
        }
        throw YouziBundledCapabilityCatalogError.catalogUnavailable
    }

    private func resolvedPackagesRootURL() throws -> URL {
        if let packagesRootURL { return packagesRootURL }
        if let mainRoot = Bundle.main.resourceURL?.appendingPathComponent(
            "YouziSkills",
            isDirectory: true
        ), isDirectory(mainRoot) {
            return mainRoot
        }
        if let moduleRoot = Bundle.module.resourceURL?.appendingPathComponent(
            "YouziSkills",
            isDirectory: true
        ), isDirectory(moduleRoot) {
            return moduleRoot
        }
        throw YouziBundledCapabilityCatalogError.packagesRootUnavailable
    }

    private func decodeCatalog(at url: URL) throws -> Catalog {
        guard url.isFileURL,
              let values = try? url.resourceValues(forKeys: [
                  .isRegularFileKey,
                  .fileSizeKey,
              ]) else {
            throw YouziBundledCapabilityCatalogError.catalogUnavailable
        }
        guard values.isRegularFile == true else {
            throw YouziBundledCapabilityCatalogError.catalogIsNotRegularFile
        }
        if let size = values.fileSize, size > Self.maximumCatalogBytes {
            throw YouziBundledCapabilityCatalogError.catalogTooLarge(
                maximumBytes: Self.maximumCatalogBytes
            )
        }

        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw YouziBundledCapabilityCatalogError.catalogUnreadable
        }
        guard data.count <= Self.maximumCatalogBytes else {
            throw YouziBundledCapabilityCatalogError.catalogTooLarge(
                maximumBytes: Self.maximumCatalogBytes
            )
        }
        do {
            return try JSONDecoder().decode(Catalog.self, from: data)
        } catch {
            throw YouziBundledCapabilityCatalogError.invalidCatalog
        }
    }

    private func validate(_ catalog: Catalog) throws {
        guard catalog.schemaVersion == Self.supportedSchemaVersion else {
            throw YouziBundledCapabilityCatalogError.unsupportedSchemaVersion(
                catalog.schemaVersion
            )
        }
        guard isVersion(catalog.catalogVersion) else {
            throw YouziBundledCapabilityCatalogError.invalidCatalogVersion
        }

        var skillIDs = Set<UUID>()
        var skillSlugs = Set<String>()
        for skill in catalog.skills {
            guard skillIDs.insert(skill.id).inserted else {
                throw YouziBundledCapabilityCatalogError.duplicateSkillID(skill.id)
            }
            guard skillSlugs.insert(skill.slug).inserted else {
                throw YouziBundledCapabilityCatalogError.duplicateSkillSlug(skill.slug)
            }
            guard isSlug(skill.slug),
                  hasText(skill.name),
                  hasText(skill.summary),
                  isVersion(skill.packageVersion),
                  hasText(skill.entrypoint),
                  Set(skill.resourcePaths).count == skill.resourcePaths.count,
                  Set(skill.requestedPermissions).count == skill.requestedPermissions.count else {
                throw YouziBundledCapabilityCatalogError.invalidSkill(skill.id)
            }
        }

        var helperIDs = Set<UUID>()
        var helperSlugs = Set<String>()
        for helper in catalog.helpers {
            guard helperIDs.insert(helper.id).inserted else {
                throw YouziBundledCapabilityCatalogError.duplicateHelperID(helper.id)
            }
            guard helperSlugs.insert(helper.slug).inserted else {
                throw YouziBundledCapabilityCatalogError.duplicateHelperSlug(helper.slug)
            }
            guard isSlug(helper.slug),
                  hasText(helper.name),
                  hasText(helper.summary),
                  hasText(helper.systemInstructions),
                  !helper.methodology.isEmpty,
                  helper.methodology.allSatisfy(hasText),
                  Set(helper.recommendedSkillIDs).count == helper.recommendedSkillIDs.count,
                  helper.preferredOutputTypes.allSatisfy(hasText) else {
                throw YouziBundledCapabilityCatalogError.invalidHelper(helper.id)
            }
            for skillID in helper.recommendedSkillIDs where !skillIDs.contains(skillID) {
                throw YouziBundledCapabilityCatalogError.missingRecommendedSkill(
                    helperID: helper.id,
                    skillID: skillID
                )
            }
        }
    }

    private func contentDigest(for manifest: YouziSkillPackageManifest) throws -> String {
        var hasher = SHA256()
        let entrypoint = try packageService.loadEntrypoint(from: manifest)
        update(&hasher, relativePath: entrypoint.relativePath, contents: entrypoint.contents)
        for path in manifest.resourcePaths.sorted() {
            let resource = try packageService.loadResource(path, from: manifest)
            update(&hasher, relativePath: resource.relativePath, contents: resource.contents)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func update(_ hasher: inout SHA256, relativePath: String, contents: String) {
        update(&hasher, data: Data(relativePath.utf8))
        update(&hasher, data: Data(contents.utf8))
    }

    private func update(_ hasher: inout SHA256, data: Data) {
        var count = UInt64(data.count).bigEndian
        withUnsafeBytes(of: &count) { hasher.update(bufferPointer: $0) }
        hasher.update(data: data)
    }

    private func hasText(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func isVersion(_ value: String) -> Bool {
        value.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$"#,
                    options: .regularExpression) != nil
    }

    private func isSlug(_ value: String) -> Bool {
        value.range(of: #"^[a-z0-9]+(?:-[a-z0-9]+)*$"#,
                    options: .regularExpression) != nil
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private struct Catalog: Decodable {
        let schemaVersion: Int
        let catalogVersion: String
        let skills: [SkillDescriptor]
        let helpers: [HelperDescriptor]
    }

    private struct SkillDescriptor: Decodable {
        let id: UUID
        let slug: String
        let name: String
        let summary: String
        let packageVersion: String
        let entrypoint: String
        let resourcePaths: [String]
        let executionLocation: YouziSkillExecutionLocation
        let requestedPermissions: [YouziPermissionKind]
        let requiresFirstUseConfirmation: Bool
    }

    private struct HelperDescriptor: Decodable {
        let id: UUID
        let slug: String
        let name: String
        let summary: String
        let systemInstructions: String
        let methodology: [String]
        let recommendedSkillIDs: [UUID]
        let preferredOutputTypes: [String]
    }
}
