import Foundation
import Testing
@testable import Rapid

@Suite("ExternalModelRegistry — exact managed links")
struct ExternalModelRegistryTests {
    @Test("Registry location honors the HOME-aware application support root")
    func linksDirectoryHonorsHome() {
        let directory = ExternalModelRegistry.linksDirectory(
            environment: ["HOME": "/tmp/youzi-home"]
        )

        #expect(directory.path == "/tmp/youzi-home/Library/Application Support/Rapid/LinkedModels")
    }

    @Test("Environment contains only exact managed links in deterministic order")
    func environmentContainsExactLinksOnly() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let firstSource = try fixture.makeModel(named: "Zeta Model")
        let secondSource = try fixture.makeModel(named: "Alpha Model")
        let first = try linkedURL(from: ExternalModelLinker.linkModel(
            at: firstSource,
            into: fixture.links
        ))
        let second = try linkedURL(from: ExternalModelLinker.linkModel(
            at: secondSource,
            into: fixture.links
        ))

        let encoded = try #require(ExternalModelRegistry.encodedEnvironmentValue(
            in: fixture.links
        ))
        let paths = try JSONDecoder().decode([String].self, from: Data(encoded.utf8))

        #expect(paths == [first.path, second.path].sorted())
        #expect(!paths.contains(firstSource.path))
        #expect(!paths.contains(secondSource.path))
        #expect(!paths.contains(fixture.root.path))
    }

    @Test("Dangling links remain forgettable but are not advertised")
    func invalidLinksFailClosed() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = try fixture.makeModel(named: "Available")
        let valid = try linkedURL(from: ExternalModelLinker.linkModel(
            at: source,
            into: fixture.links
        ))
        let dangling = fixture.links.appendingPathComponent(
            ExternalModelLinker.managedLinkPrefix + "gone-0123456789abcdef"
        )
        try FileManager.default.createSymbolicLink(
            at: dangling,
            withDestinationURL: fixture.root.appendingPathComponent("missing")
        )

        let records = try ExternalModelRegistry.records(in: fixture.links)
        let encoded = try #require(ExternalModelRegistry.encodedEnvironmentValue(
            in: fixture.links
        ))
        let paths = try JSONDecoder().decode([String].self, from: Data(encoded.utf8))

        let recordsByName = Dictionary(
            uniqueKeysWithValues: records.map { ($0.linkURL.lastPathComponent, $0) }
        )
        #expect(
            records.map { $0.linkURL.lastPathComponent }
                == [valid, dangling].map(\.lastPathComponent).sorted()
        )
        #expect(recordsByName[valid.lastPathComponent]?.isAvailable == true)
        #expect(recordsByName[dangling.lastPathComponent]?.isAvailable == false)
        #expect(
            paths.map { URL(fileURLWithPath: $0).lastPathComponent }
                == [valid.lastPathComponent]
        )

        try ExternalModelLinker.removeManagedLink(at: dangling, from: fixture.links)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test("No valid links produces no environment override")
    func emptyRegistryHasNoEnvironmentValue() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        #expect(ExternalModelRegistry.encodedEnvironmentValue(in: fixture.links) == nil)
    }

    private func linkedURL(from outcome: ExternalModelLinker.LinkOutcome) throws -> URL {
        switch outcome {
        case .linked(let url), .alreadyLinked(let url): return url
        }
    }

    private struct Fixture {
        let root: URL
        let links: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "ExternalModelRegistryTests-\(UUID().uuidString)",
                isDirectory: true
            )
            links = root.appendingPathComponent(
                "Application Support/Linked Models",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func makeModel(named name: String) throws -> URL {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(#"{"model_type":"qwen2"}"#.utf8).write(
                to: directory.appendingPathComponent("config.json")
            )
            try Data("weights".utf8).write(
                to: directory.appendingPathComponent("model.safetensors")
            )
            return directory
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
