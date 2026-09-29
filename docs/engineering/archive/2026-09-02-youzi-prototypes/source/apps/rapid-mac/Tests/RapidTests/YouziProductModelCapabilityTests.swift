import Foundation
import Testing
@testable import Rapid

@MainActor
@Suite("YouziProductModel capability lifecycle")
struct YouziProductModelCapabilityTests {
    @Test("The app-owned model seeds and exposes the verified product catalog")
    func seedAndExposeCatalog() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let model = YouziProductModel(store: fixture.store)

        model.seedBundledCapabilities(at: Date(timeIntervalSince1970: 100))

        #expect(model.lastPersistenceError == nil)
        #expect(model.helpers.count == 8)
        #expect(model.skills.count == 8)
        #expect(model.skillPackages.count == 8)
        #expect(Set(model.skills.map(\.id)) == Set(model.skillPackages.map(\.id)))
        #expect(try fixture.store.load() == model.document)
    }

    @Test("Favorite helper state updates the one durable graph")
    func helperFavoritePersists() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let model = YouziProductModel(store: fixture.store)
        model.seedBundledCapabilities(at: Date(timeIntervalSince1970: 100))
        let helper = try #require(model.helpers.first)

        model.setHelperFavorite(
            id: helper.id,
            favorite: true,
            at: Date(timeIntervalSince1970: 200)
        )

        #expect(model.helper(id: helper.id)?.isFavorite == true)
        #expect(
            try fixture.store.load().helpers.first(where: { $0.id == helper.id })?.isFavorite
                == true
        )
    }

    @Test("A damaged bundled package reports failure without replacing product data")
    func damagedCatalogDoesNotReplaceData() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let model = YouziProductModel(store: fixture.store)
        let project = try #require(model.createProject(name: "保留项目"))
        let before = try Data(contentsOf: fixture.fileURL)
        let emptyPackages = fixture.root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(
            at: emptyPackages,
            withIntermediateDirectories: true
        )

        model.seedBundledCapabilities(
            loader: YouziBundledCapabilityCatalogLoader(packagesRootURL: emptyPackages),
            at: Date(timeIntervalSince1970: 300)
        )

        #expect(model.lastPersistenceError != nil)
        #expect(model.project(id: project.id) == project)
        #expect(try Data(contentsOf: fixture.fileURL) == before)
    }

    private struct Fixture {
        let root: URL
        let fileURL: URL
        let store: YouziDomainStore

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "youzi-product-capability-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            fileURL = root.appendingPathComponent("domain.json")
            store = YouziDomainStore(fileURL: fileURL)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
