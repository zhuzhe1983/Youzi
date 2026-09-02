import Foundation
import Testing
@testable import Rapid

@Suite("ExternalModelLinker — single-model reuse")
struct ExternalModelLinkerTests {
    @Test("A valid flat MLX model creates exactly one link and leaves source bytes untouched")
    func validModelCreatesOneLink() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let originalConfig = Data(#"{"model_type":"qwen2"}"#.utf8)
        let originalWeights = Data("model bytes".utf8)
        try fixture.makeValidModel(config: originalConfig, weights: originalWeights)

        let outcome = try ExternalModelLinker.linkModel(
            at: fixture.source,
            into: fixture.links
        )
        let link = try linkedURL(from: outcome)

        #expect(link.deletingLastPathComponent() == fixture.links)
        #expect(itemType(link) == .typeSymbolicLink)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.links.path).count == 1)
        #expect(try Data(contentsOf: fixture.config) == originalConfig)
        #expect(try Data(contentsOf: fixture.weights) == originalWeights)
        #expect(
            try ExternalModelLinker.destinationOfManagedLink(
                at: link,
                in: fixture.links
            ) == fixture.source.resolvingSymlinksInPath()
        )
    }

    @Test("A file cannot be imported as a model directory")
    func fileSourceIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let file = fixture.root.appendingPathComponent("not-a-directory")
        try Data("x".utf8).write(to: file)

        #expect(throws: ExternalModelLinker.LinkError.sourceIsNotDirectory) {
            try ExternalModelLinker.linkModel(at: file, into: fixture.links)
        }
    }

    @Test("A model without config.json is rejected before a links directory is created")
    func missingManifestIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("weights".utf8).write(to: fixture.weights)

        #expect(throws: ExternalModelLinker.LinkError.missingManifest) {
            try ExternalModelLinker.linkModel(at: fixture.source, into: fixture.links)
        }
        #expect(itemType(fixture.links) == nil)
    }

    @Test("An invalid config.json is rejected")
    func invalidManifestIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("not json".utf8).write(to: fixture.config)
        try Data("weights".utf8).write(to: fixture.weights)

        #expect(throws: ExternalModelLinker.LinkError.invalidManifest) {
            try ExternalModelLinker.linkModel(at: fixture.source, into: fixture.links)
        }
    }

    @Test("A model without root loader weights is rejected")
    func missingWeightsIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.makeManifest()
        try Data("adapter".utf8).write(
            to: fixture.source.appendingPathComponent("adapter.safetensors")
        )

        #expect(throws: ExternalModelLinker.LinkError.missingWeights) {
            try ExternalModelLinker.linkModel(at: fixture.source, into: fixture.links)
        }
    }

    @Test("An indexed model must contain every declared shard")
    func incompleteIndexedWeightsAreRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.makeManifest()
        let index = fixture.source.appendingPathComponent("model.safetensors.index.json")
        try Data(
            #"{"weight_map":{"a":"model-00001-of-00002.safetensors","b":"model-00002-of-00002.safetensors"}}"#.utf8
        ).write(to: index)
        try Data("first shard".utf8).write(
            to: fixture.source.appendingPathComponent("model-00001-of-00002.safetensors")
        )

        #expect(throws: ExternalModelLinker.LinkError.missingWeights) {
            try ExternalModelLinker.linkModel(at: fixture.source, into: fixture.links)
        }
    }

    @Test("A complete indexed model is accepted")
    func completeIndexedWeightsAreAccepted() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.makeManifest()
        let index = fixture.source.appendingPathComponent("model.safetensors.index.json")
        try Data(
            #"{"weight_map":{"a":"model-00001-of-00002.safetensors","b":"model-00002-of-00002.safetensors"}}"#.utf8
        ).write(to: index)
        for name in ["model-00001-of-00002.safetensors", "model-00002-of-00002.safetensors"] {
            try Data(name.utf8).write(to: fixture.source.appendingPathComponent(name))
        }

        let outcome = try ExternalModelLinker.linkModel(
            at: fixture.source,
            into: fixture.links
        )
        #expect(itemType(try linkedURL(from: outcome)) == .typeSymbolicLink)
    }

    @Test("Selecting a whole Hugging Face cache is refused")
    func wholeCacheIsRejected() throws {
        let fixture = try Fixture(createSource: false)
        defer { fixture.remove() }
        let repo = fixture.root.appendingPathComponent("hub/models--org--repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)

        #expect(throws: ExternalModelLinker.LinkError.sourceIsCacheRoot) {
            try ExternalModelLinker.linkModel(
                at: repo.deletingLastPathComponent(),
                into: fixture.links
            )
        }
    }

    @Test("The stable name distinguishes same-named folders and uses catalog-safe characters")
    func stableTargetName() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let otherParent = fixture.root.appendingPathComponent("other")
        let other = otherParent.appendingPathComponent(fixture.source.lastPathComponent)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)

        let first = ExternalModelLinker.targetName(for: fixture.source)
        #expect(first == ExternalModelLinker.targetName(for: fixture.source))
        #expect(first != ExternalModelLinker.targetName(for: other))
        #expect(first.hasPrefix(ExternalModelLinker.managedLinkPrefix))
        #expect(first.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) })
    }

    @Test("Linking the same canonical source twice is inode-preserving and idempotent")
    func idempotentLink() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.makeValidModel()

        let first = try linkedURL(from: ExternalModelLinker.linkModel(
            at: fixture.source,
            into: fixture.links
        ))
        let inodeBefore = try inode(first)
        let second = try ExternalModelLinker.linkModel(
            at: fixture.source.appendingPathComponent("."),
            into: fixture.links
        )

        #expect(second == .alreadyLinked(first))
        #expect(try inode(first) == inodeBefore)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.links.path).count == 1)
    }

    @Test("A relative existing link to the same source is idempotent")
    func relativeSameLinkIsIdempotent() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.makeValidModel()
        try FileManager.default.createDirectory(at: fixture.links, withIntermediateDirectories: true)
        let link = fixture.links.appendingPathComponent(
            ExternalModelLinker.targetName(for: fixture.source),
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: "../\(fixture.source.lastPathComponent)"
        )

        #expect(
            try ExternalModelLinker.linkModel(at: fixture.source, into: fixture.links)
                == .alreadyLinked(link)
        )
    }

    @Test("An existing non-link target is a collision and is not modified")
    func regularCollisionIsPreserved() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.makeValidModel()
        try FileManager.default.createDirectory(at: fixture.links, withIntermediateDirectories: true)
        let target = fixture.links.appendingPathComponent(
            ExternalModelLinker.targetName(for: fixture.source)
        )
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let marker = target.appendingPathComponent("owner-data")
        try Data("keep".utf8).write(to: marker)

        #expect(throws: ExternalModelLinker.LinkError.targetCollision) {
            try ExternalModelLinker.linkModel(at: fixture.source, into: fixture.links)
        }
        #expect(try Data(contentsOf: marker) == Data("keep".utf8))
    }

    @Test("A link to a different source is a collision and is not repointed")
    func otherLinkCollisionIsPreserved() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.makeValidModel()
        try FileManager.default.createDirectory(at: fixture.links, withIntermediateDirectories: true)
        let other = fixture.root.appendingPathComponent("other-model")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let target = fixture.links.appendingPathComponent(
            ExternalModelLinker.targetName(for: fixture.source)
        )
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: other)

        #expect(throws: ExternalModelLinker.LinkError.targetCollision) {
            try ExternalModelLinker.linkModel(at: fixture.source, into: fixture.links)
        }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: target.path) == other.path)
    }

    @Test("A dangling target is reported and never silently replaced")
    func danglingLinkIsPreserved() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.makeValidModel()
        try FileManager.default.createDirectory(at: fixture.links, withIntermediateDirectories: true)
        let target = fixture.links.appendingPathComponent(
            ExternalModelLinker.targetName(for: fixture.source)
        )
        let missing = fixture.root.appendingPathComponent("missing-model")
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: missing)

        #expect(throws: ExternalModelLinker.LinkError.danglingTarget) {
            try ExternalModelLinker.linkModel(at: fixture.source, into: fixture.links)
        }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: target.path) == missing.path)
    }

    @Test("Self, descendant, and managed-root source cycles are rejected")
    func selfAndCycleShapesAreRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.makeValidModel()

        #expect(throws: ExternalModelLinker.LinkError.sourceAndLinksDirectoryOverlap) {
            try ExternalModelLinker.linkModel(at: fixture.source, into: fixture.source)
        }
        let nestedLinks = fixture.source.appendingPathComponent("links")
        #expect(throws: ExternalModelLinker.LinkError.sourceAndLinksDirectoryOverlap) {
            try ExternalModelLinker.linkModel(at: fixture.source, into: nestedLinks)
        }
        #expect(itemType(nestedLinks) == nil)

        let managedRoot = fixture.root.appendingPathComponent("managed")
        let nestedSource = managedRoot.appendingPathComponent("nested-model")
        try FileManager.default.createDirectory(at: nestedSource, withIntermediateDirectories: true)
        try Fixture.makeValidModel(at: nestedSource)
        #expect(throws: ExternalModelLinker.LinkError.sourceAndLinksDirectoryOverlap) {
            try ExternalModelLinker.linkModel(at: nestedSource, into: managedRoot)
        }

        let cycle = fixture.root.appendingPathComponent("cycle")
        try FileManager.default.createSymbolicLink(atPath: cycle.path, withDestinationPath: cycle.path)
        #expect(throws: ExternalModelLinker.LinkError.sourceIsSymbolicLink) {
            try ExternalModelLinker.linkModel(at: cycle, into: fixture.links)
        }
    }

    @Test("A symlink escaping a flat model tree is rejected")
    func escapedModelLeafIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let outside = fixture.root.appendingPathComponent("outside-config.json")
        try Data(#"{"model_type":"qwen2"}"#.utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: fixture.config, withDestinationURL: outside)
        try Data("weights".utf8).write(to: fixture.weights)

        #expect(throws: ExternalModelLinker.LinkError.unsafeModelTree) {
            try ExternalModelLinker.linkModel(at: fixture.source, into: fixture.links)
        }
    }

    @Test("Standard Hugging Face snapshot blob links are accepted when contained by one repo")
    func huggingFaceSnapshotBlobLinksAreAccepted() throws {
        let fixture = try Fixture(createSource: false)
        defer { fixture.remove() }
        let repository = fixture.root.appendingPathComponent("models--org--model")
        let blobs = repository.appendingPathComponent("blobs")
        let snapshot = repository.appendingPathComponent("snapshots/revision")
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        let configBlob = blobs.appendingPathComponent("config-digest")
        let weightBlob = blobs.appendingPathComponent("weight-digest")
        try Data(#"{"model_type":"qwen2"}"#.utf8).write(to: configBlob)
        try Data("weights".utf8).write(to: weightBlob)
        try FileManager.default.createSymbolicLink(
            atPath: snapshot.appendingPathComponent("config.json").path,
            withDestinationPath: "../../blobs/config-digest"
        )
        try FileManager.default.createSymbolicLink(
            atPath: snapshot.appendingPathComponent("model.safetensors").path,
            withDestinationPath: "../../blobs/weight-digest"
        )

        let outcome = try ExternalModelLinker.linkModel(at: snapshot, into: fixture.links)
        #expect(
            try ExternalModelLinker.destinationOfManagedLink(
                at: linkedURL(from: outcome),
                in: fixture.links
            ) == snapshot.resolvingSymlinksInPath()
        )
    }

    @Test("Removal deletes only a direct managed symlink and never source bytes")
    func managedRemovalPreservesSource() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let weights = Data("irreplaceable source weights".utf8)
        try fixture.makeValidModel(weights: weights)
        let link = try linkedURL(from: ExternalModelLinker.linkModel(
            at: fixture.source,
            into: fixture.links
        ))

        #expect(
            try ExternalModelLinker.removeManagedLink(at: link, from: fixture.links)
                == .removed
        )
        #expect(itemType(link) == nil)
        #expect(try Data(contentsOf: fixture.weights) == weights)

        try Data("not a link".utf8).write(to: link)
        #expect(throws: ExternalModelLinker.LinkError.unmanagedLink) {
            try ExternalModelLinker.removeManagedLink(at: link, from: fixture.links)
        }
        #expect(try Data(contentsOf: link) == Data("not a link".utf8))
    }

    @Test("Removal refuses links outside the managed directory and unprefixed links inside it")
    func unmanagedRemovalIsRefused() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.makeValidModel()
        try FileManager.default.createDirectory(at: fixture.links, withIntermediateDirectories: true)
        let outside = fixture.root.appendingPathComponent(
            ExternalModelLinker.targetName(for: fixture.source)
        )
        try FileManager.default.createSymbolicLink(at: outside, withDestinationURL: fixture.source)
        #expect(throws: ExternalModelLinker.LinkError.unmanagedLink) {
            try ExternalModelLinker.removeManagedLink(at: outside, from: fixture.links)
        }
        #expect(itemType(outside) == .typeSymbolicLink)

        let unprefixed = fixture.links.appendingPathComponent("model")
        try FileManager.default.createSymbolicLink(at: unprefixed, withDestinationURL: fixture.source)
        #expect(throws: ExternalModelLinker.LinkError.unmanagedLink) {
            try ExternalModelLinker.removeManagedLink(at: unprefixed, from: fixture.links)
        }
        #expect(itemType(unprefixed) == .typeSymbolicLink)
    }

    @Test("Explicit removal can clean up a dangling managed link without touching any target")
    func danglingManagedLinkCanBeRemoved() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.makeValidModel()
        try FileManager.default.createDirectory(at: fixture.links, withIntermediateDirectories: true)
        let link = fixture.links.appendingPathComponent(
            ExternalModelLinker.targetName(for: fixture.source)
        )
        let missing = fixture.root.appendingPathComponent("missing")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: missing)

        #expect(
            try ExternalModelLinker.removeManagedLink(at: link, from: fixture.links)
                == .removed
        )
        #expect(itemType(link) == nil)
        #expect(itemType(missing) == nil)
    }

    @Test("Managed link enumeration includes valid and dangling links only")
    func managedLinkEnumerationIsDirectAndNonResolving() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.makeValidModel()
        let valid = try linkedURL(from: ExternalModelLinker.linkModel(
            at: fixture.source,
            into: fixture.links
        ))
        let dangling = fixture.links.appendingPathComponent(
            ExternalModelLinker.managedLinkPrefix + "missing-0123456789abcdef"
        )
        try FileManager.default.createSymbolicLink(
            at: dangling,
            withDestinationURL: fixture.root.appendingPathComponent("gone")
        )
        let ordinary = fixture.links.appendingPathComponent("ordinary-link")
        try FileManager.default.createSymbolicLink(at: ordinary, withDestinationURL: fixture.source)
        let collision = fixture.links.appendingPathComponent(
            ExternalModelLinker.managedLinkPrefix + "file-fedcba9876543210"
        )
        try Data("not a link".utf8).write(to: collision)

        let links = try ExternalModelLinker.managedLinkURLs(in: fixture.links)

        #expect(
            Set(links.map(\.lastPathComponent))
                == Set([valid, dangling].map(\.lastPathComponent))
        )
    }

    @Test("A missing managed links directory enumerates as empty")
    func missingManagedLinksDirectoryIsEmpty() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        #expect(try ExternalModelLinker.managedLinkURLs(in: fixture.links).isEmpty)
    }

    private func linkedURL(
        from outcome: ExternalModelLinker.LinkOutcome
    ) throws -> URL {
        switch outcome {
        case .linked(let url), .alreadyLinked(let url):
            return url
        }
    }

    private func itemType(_ url: URL) -> FileAttributeType? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type]) as? FileAttributeType
    }

    private func inode(_ url: URL) throws -> UInt64 {
        let value = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber]
        return try #require((value as? NSNumber)?.uint64Value)
    }

    private struct Fixture {
        let root: URL
        let source: URL
        let links: URL

        var config: URL { source.appendingPathComponent("config.json") }
        var weights: URL { source.appendingPathComponent("model.safetensors") }

        init(createSource: Bool = true) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "ExternalModelLinkerTests-\(UUID().uuidString)",
                isDirectory: true
            )
            source = root.appendingPathComponent("Selected Model", isDirectory: true)
            links = root.appendingPathComponent("managed-links", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if createSource {
                try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            }
        }

        func makeManifest() throws {
            try Data(#"{"model_type":"qwen2"}"#.utf8).write(to: config)
        }

        func makeValidModel(
            config: Data = Data(#"{"model_type":"qwen2"}"#.utf8),
            weights: Data = Data("weights".utf8)
        ) throws {
            try config.write(to: self.config)
            try weights.write(to: self.weights)
        }

        static func makeValidModel(at directory: URL) throws {
            try Data(#"{"model_type":"qwen2"}"#.utf8).write(
                to: directory.appendingPathComponent("config.json")
            )
            try Data("weights".utf8).write(
                to: directory.appendingPathComponent("model.safetensors")
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
