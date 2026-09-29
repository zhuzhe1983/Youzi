import Foundation
import Testing
@testable import Rapid

@Suite("Youzi bundled capability catalog")
struct YouziBundledCapabilityCatalogTests {
    @Test("Product catalog loads every curated helper and declarative skill")
    func productCatalogLoads() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let content = try YouziBundledCapabilityCatalogLoader().load(at: date)

        #expect(content.catalogVersion == "1.0.0")
        #expect(content.skills.count == 8)
        #expect(content.helpers.count == 8)
        #expect(content.skillPackages.count == 8)
        #expect(content.capabilitySeed.skillPackages == content.skillPackages)
        #expect(Set(content.skills.map(\.id)) == Set(content.skillPackages.map(\.id)))
        #expect(content.skills.allSatisfy { $0.createdAt == date && $0.updatedAt == date })
        #expect(content.helpers.allSatisfy { $0.createdAt == date && $0.updatedAt == date })
        #expect(
            content.skillPackages.allSatisfy {
                $0.installedAt == date && $0.verifiedAt == date && $0.updatedAt == date
            }
        )
    }

    @Test("Stable product identities do not depend on display names")
    func stableProductIdentities() throws {
        let content = try YouziBundledCapabilityCatalogLoader().load(
            at: Date(timeIntervalSince1970: 1)
        )

        #expect(
            content.skills.map(\.source.identifier).sorted() == [
                "youzi.builtin.skill.data-insight",
                "youzi.builtin.skill.decision-support",
                "youzi.builtin.skill.document-organizer",
                "youzi.builtin.skill.family-coordinator",
                "youzi.builtin.skill.grounded-research",
                "youzi.builtin.skill.project-pilot",
                "youzi.builtin.skill.thoughtful-writing",
                "youzi.builtin.skill.weekly-planner",
            ]
        )
        #expect(content.helpers.allSatisfy { $0.source.kind == .builtIn })
        #expect(content.skills.allSatisfy { $0.source.kind == .builtIn })
    }

    @Test("Every helper recommendation resolves to a catalog skill")
    func helperReferencesResolve() throws {
        let content = try YouziBundledCapabilityCatalogLoader().load()
        let skillIDs = Set(content.skills.map(\.id))

        for helper in content.helpers {
            #expect(!helper.recommendedSkillIDs.isEmpty)
            #expect(helper.recommendedSkillIDs.allSatisfy(skillIDs.contains))
        }
    }

    @Test("Package digests and locations are deterministic and content-addressed")
    func packageDigestsAreDeterministic() throws {
        let date = Date(timeIntervalSince1970: 42)
        let first = try YouziBundledCapabilityCatalogLoader().load(at: date)
        let second = try YouziBundledCapabilityCatalogLoader().load(at: date)

        #expect(first == second)
        for package in first.skillPackages {
            #expect(package.contentSHA256.count == 64)
            #expect(
                package.contentSHA256.range(
                    of: #"^[0-9a-f]{64}$"#,
                    options: .regularExpression
                ) != nil
            )
            guard case let .bundled(resourcePath) = package.location else {
                Issue.record("A built-in package must use a bundled location")
                continue
            }
            #expect(resourcePath.hasPrefix("YouziSkills/"))
            #expect(!resourcePath.contains(".."))
        }
    }

    @Test("Unsupported schemas and malformed versions fail closed")
    func schemaAndVersionValidation() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        try fixture.writeCatalog(fixture.catalog(schemaVersion: 2))
        #expect(
            throws: YouziBundledCapabilityCatalogError.unsupportedSchemaVersion(2)
        ) {
            try fixture.loader().load()
        }

        try fixture.writeCatalog(fixture.catalog(catalogVersion: "latest"))
        #expect(throws: YouziBundledCapabilityCatalogError.invalidCatalogVersion) {
            try fixture.loader().load()
        }
    }

    @Test("Duplicate IDs and slugs fail closed before package access")
    func duplicatesFailClosed() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        try fixture.writeCatalog(fixture.catalog(extraSkill: fixture.skillJSON))
        #expect(
            throws: YouziBundledCapabilityCatalogError.duplicateSkillID(fixture.skillID)
        ) {
            try fixture.loader().load()
        }

        let otherID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let sameSlug = fixture.skillJSON.replacingOccurrences(
            of: fixture.skillID.uuidString.lowercased(),
            with: otherID
        )
        try fixture.writeCatalog(fixture.catalog(extraSkill: sameSlug))
        #expect(
            throws: YouziBundledCapabilityCatalogError.duplicateSkillSlug("safe-skill")
        ) {
            try fixture.loader().load()
        }
    }

    @Test("A helper cannot cite a missing skill")
    func missingHelperDependencyFailsClosed() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let helper = fixture.helperJSON(
            recommendedSkillID: "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
        )
        try fixture.writeCatalog(fixture.catalog(helper: helper))

        #expect(
            throws: YouziBundledCapabilityCatalogError.missingRecommendedSkill(
                helperID: fixture.helperID,
                skillID: UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!
            )
        ) {
            try fixture.loader().load()
        }
    }

    @Test("A declared package must exist and pass safe package validation")
    func invalidPackageFailsClosed() throws {
        let fixture = try Fixture(createSkillFile: false)
        defer { fixture.remove() }
        try fixture.writeCatalog(fixture.catalog())

        #expect(
            throws: YouziBundledCapabilityCatalogError.invalidPackage(
                skillID: fixture.skillID
            )
        ) {
            try fixture.loader().load()
        }
    }

    private struct Fixture {
        let root: URL
        let catalogURL: URL
        let packagesRootURL: URL
        let skillID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        let helperID = UUID(uuidString: "dddddddd-dddd-4ddd-8ddd-dddddddddddd")!

        init(createSkillFile: Bool = true) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "youzi-catalog-\(UUID().uuidString)",
                isDirectory: true
            )
            catalogURL = root.appendingPathComponent("catalog.json")
            packagesRootURL = root.appendingPathComponent("YouziSkills", isDirectory: true)
            let package = packagesRootURL.appendingPathComponent("safe-skill", isDirectory: true)
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            if createSkillFile {
                try Data("# Safe\n".utf8).write(
                    to: package.appendingPathComponent("SKILL.md")
                )
            }
        }

        var skillJSON: String {
            """
            {
              "id":"\(skillID.uuidString.lowercased())",
              "slug":"safe-skill",
              "name":"安全技能",
              "summary":"只读取声明的文本。",
              "packageVersion":"1.0.0",
              "entrypoint":"SKILL.md",
              "resourcePaths":[],
              "executionLocation":"local",
              "requestedPermissions":[],
              "requiresFirstUseConfirmation":false
            }
            """
        }

        func helperJSON(recommendedSkillID: String? = nil) -> String {
            """
            {
              "id":"\(helperID.uuidString.lowercased())",
              "slug":"safe-helper",
              "name":"安全助手",
              "summary":"可靠地帮助用户。",
              "systemInstructions":"只使用已经验证的能力。",
              "methodology":["理解目标"],
              "recommendedSkillIDs":["\(recommendedSkillID ?? skillID.uuidString.lowercased())"],
              "preferredOutputTypes":["document"]
            }
            """
        }

        func catalog(
            schemaVersion: Int = 1,
            catalogVersion: String = "1.0.0",
            extraSkill: String? = nil,
            helper: String? = nil
        ) -> String {
            let skills = [skillJSON, extraSkill].compactMap { $0 }.joined(separator: ",")
            return """
            {
              "schemaVersion":\(schemaVersion),
              "catalogVersion":"\(catalogVersion)",
              "skills":[\(skills)],
              "helpers":[\(helper ?? helperJSON())]
            }
            """
        }

        func writeCatalog(_ contents: String) throws {
            try Data(contents.utf8).write(to: catalogURL)
        }

        func loader() -> YouziBundledCapabilityCatalogLoader {
            YouziBundledCapabilityCatalogLoader(
                catalogURL: catalogURL,
                packagesRootURL: packagesRootURL
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
