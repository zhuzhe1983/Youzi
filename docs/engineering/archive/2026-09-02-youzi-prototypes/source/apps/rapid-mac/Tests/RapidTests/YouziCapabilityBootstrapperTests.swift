import Foundation
import Testing
@testable import Rapid

@Suite("Youzi capability bootstrapper")
struct YouziCapabilityBootstrapperTests {
    @Test("Bootstrap installs the complete verified built-in catalog atomically")
    func completeCatalogIsInstalled() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let date = Date(timeIntervalSince1970: 1_800_100_000)

        let document = try YouziCapabilityBootstrapper(store: fixture.store)
            .bootstrap(at: date)

        #expect(document.helpers.count == 8)
        #expect(document.skills.count == 8)
        #expect(document.skillPackages.count == 8)
        #expect(Set(document.skills.map(\.id)) == Set(document.skillPackages.map(\.id)))
        #expect(document.helpers.allSatisfy { $0.source.kind == .builtIn })
        #expect(document.skills.allSatisfy { $0.source.kind == .builtIn })
        #expect(try fixture.store.load() == document)
    }

    @Test("An invalid package leaves existing durable state byte-for-byte unchanged")
    func invalidCatalogCannotPartiallySeed() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let existing = YouziProject(name: "保留的项目")
        _ = try fixture.store.update { $0.upsert(existing) }
        let before = try Data(contentsOf: fixture.fileURL)

        let customRoot = fixture.root.appendingPathComponent("packages", isDirectory: true)
        try FileManager.default.createDirectory(at: customRoot, withIntermediateDirectories: true)
        let loader = YouziBundledCapabilityCatalogLoader(packagesRootURL: customRoot)

        #expect(throws: YouziBundledCapabilityCatalogError.self) {
            try YouziCapabilityBootstrapper(store: fixture.store, catalogLoader: loader)
                .bootstrap()
        }
        #expect(try Data(contentsOf: fixture.fileURL) == before)
        #expect(try fixture.store.load().projects == [existing])
    }

    @Test("Repeated bootstrap does not duplicate catalog identities")
    func repeatedBootstrapDoesNotDuplicate() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let bootstrapper = YouziCapabilityBootstrapper(store: fixture.store)

        _ = try bootstrapper.bootstrap(at: Date(timeIntervalSince1970: 10))
        let second = try bootstrapper.bootstrap(at: Date(timeIntervalSince1970: 20))

        #expect(second.helpers.count == 8)
        #expect(second.skills.count == 8)
        #expect(second.skillPackages.count == 8)
        #expect(Set(second.helpers.map(\.id)).count == 8)
        #expect(Set(second.skills.map(\.id)).count == 8)
        #expect(Set(second.skillPackages.map(\.id)).count == 8)
    }

    private struct Fixture {
        let root: URL
        let fileURL: URL
        let store: YouziDomainStore

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "youzi-capability-bootstrap-\(UUID().uuidString)",
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
