import Foundation
import Testing
@testable import Rapid

@Suite("YouziSkillPackageService — safe declarative packages")
struct YouziSkillPackageServiceTests {
    private final class SecurityScopeProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var starts = 0
        private var stops = 0

        func start() -> Bool {
            lock.withLock { starts += 1 }
            return true
        }

        func stop() {
            lock.withLock { stops += 1 }
        }

        var counts: (starts: Int, stops: Int) {
            lock.withLock { (starts, stops) }
        }
    }

    private struct Fixture {
        let sandbox: URL
        let packageRoot: URL
        let outside: URL

        init(createPackageRoot: Bool = true) throws {
            let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(
                "youzi-skill-package-\(UUID().uuidString)",
                isDirectory: true
            )
            self.sandbox = sandbox
            packageRoot = sandbox.appendingPathComponent("package", isDirectory: true)
            outside = sandbox.appendingPathComponent("outside", isDirectory: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            if createPackageRoot {
                try FileManager.default.createDirectory(
                    at: packageRoot,
                    withIntermediateDirectories: true
                )
            }
        }

        func remove() {
            try? FileManager.default.removeItem(at: sandbox)
        }

        @discardableResult
        func write(
            _ relativePath: String,
            text: String,
            beneath root: URL? = nil
        ) throws -> URL {
            try write(relativePath, data: Data(text.utf8), beneath: root)
        }

        @discardableResult
        func write(
            _ relativePath: String,
            data: Data,
            beneath root: URL? = nil
        ) throws -> URL {
            let selectedRoot = root ?? packageRoot
            let url = selectedRoot.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url)
            return url
        }
    }

    @Test("Default entrypoint and declared resources load as deterministic UTF-8 values")
    func defaultPackageLoads() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let skill = try fixture.write("SKILL.md", text: "# Safe skill\n")
        let zeta = try fixture.write("refs/zeta.md", text: "zeta")
        let alpha = try fixture.write("refs/alpha.md", text: "alpha")
        let service = YouziSkillPackageService()

        let package = try service.discoverPackage(
            at: fixture.packageRoot,
            resourcePaths: ["refs/zeta.md", "refs/alpha.md"]
        )

        let skillByteCount = try Data(contentsOf: skill).count
        let alphaByteCount = try Data(contentsOf: alpha).count
        let zetaByteCount = try Data(contentsOf: zeta).count
        #expect(package.entrypointPath == "SKILL.md")
        #expect(package.resourcePaths == ["refs/alpha.md", "refs/zeta.md"])
        #expect(package.entrypoint.byteCount == skillByteCount)
        #expect(
            package.aggregateByteCount
                == skillByteCount + alphaByteCount + zetaByteCount
        )
        #expect(try service.loadEntrypoint(from: package).contents == "# Safe skill\n")
        #expect(
            try service.loadResource("refs/alpha.md", from: package)
                == YouziSkillPackageTextFile(
                    relativePath: "refs/alpha.md",
                    contents: "alpha",
                    byteCount: 5
                )
        )
    }

    @Test("An explicit nested alternate entrypoint is supported")
    func alternateEntrypointLoads() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("instructions/main.md", text: "alternate")

        let service = YouziSkillPackageService()
        let package = try service.discoverPackage(
            at: fixture.packageRoot,
            entrypoint: "instructions/main.md"
        )

        #expect(package.entrypointPath == "instructions/main.md")
        #expect(try service.loadEntrypoint(from: package).contents == "alternate")
    }

    @Test("Security-scoped root access is balanced on success and failure")
    func securityScopedAccessIsBalanced() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let skill = try fixture.write("SKILL.md", text: "safe")
        let probe = SecurityScopeProbe()
        let service = YouziSkillPackageService(
            securityScope: YouziSkillPackageSecurityScope(
                start: { _ in probe.start() },
                stop: { _ in probe.stop() }
            )
        )

        let package = try service.discoverPackage(at: fixture.packageRoot)
        #expect(probe.counts.starts == 1)
        #expect(probe.counts.stops == 1)

        try FileManager.default.removeItem(at: skill)
        #expect(
            throws: YouziSkillPackageError.missingEntrypoint(relativePath: "SKILL.md")
        ) {
            try service.loadEntrypoint(from: package)
        }
        #expect(probe.counts.starts == 2)
        #expect(probe.counts.stops == 2)
    }

    @Test("Undeclared content and executable scripts are never enumerated or run")
    func scriptsAreInertAndUndeclaredFilesAreUnread() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("SKILL.md", text: "instructions")
        try fixture.write("secret.bin", data: Data([0xC3, 0x28]))
        let marker = fixture.outside.appendingPathComponent("executed")
        let script = try fixture.write(
            "scripts/run.sh",
            text: "#!/bin/sh\nprintf ran > \"\(marker.path)\"\n"
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: script.path
        )

        let service = YouziSkillPackageService()
        let package = try service.discoverPackage(at: fixture.packageRoot)

        #expect(package.resourcePaths.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(
            throws: YouziSkillPackageError.undeclaredResource(relativePath: "secret.bin")
        ) {
            try service.loadResource("secret.bin", from: package)
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("Missing and non-directory roots have distinct stable errors")
    func invalidPackageRootsAreRejected() throws {
        let fixture = try Fixture(createPackageRoot: false)
        defer { fixture.remove() }
        let service = YouziSkillPackageService()

        #expect(throws: YouziSkillPackageError.packageRootUnavailable) {
            try service.discoverPackage(at: fixture.packageRoot)
        }

        try fixture.write("package", text: "not a folder", beneath: fixture.sandbox)
        #expect(throws: YouziSkillPackageError.packageRootIsNotDirectory) {
            try service.discoverPackage(at: fixture.packageRoot)
        }
        #expect(throws: YouziSkillPackageError.packageRootMustBeAbsoluteFileURL) {
            try service.discoverPackage(at: try #require(URL(string: "https://example.invalid/skill")))
        }
    }

    @Test("A symbolic-link package root is rejected")
    func symbolicLinkRootIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("SKILL.md", text: "safe")
        let link = fixture.sandbox.appendingPathComponent("package-link")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: fixture.packageRoot
        )

        #expect(throws: YouziSkillPackageError.packageRootIsSymbolicLink) {
            try YouziSkillPackageService().discoverPackage(at: link)
        }
    }

    @Test("Absolute, empty, dot, empty-component, and NUL paths are rejected")
    func malformedRelativePathsAreRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("SKILL.md", text: "safe")
        let service = YouziSkillPackageService()

        let cases: [(String, YouziSkillPackagePathProblem)] = [
            ("", .empty),
            ("/tmp/escape", .absolute),
            ("file:///tmp/escape", .absolute),
            (".", .dotComponent),
            ("docs/./guide.md", .dotComponent),
            ("docs//guide.md", .emptyComponent),
            ("docs/", .emptyComponent),
            ("bad\0path", .nul),
        ]
        for (path, problem) in cases {
            #expect(throws: YouziSkillPackageError.invalidRelativePath(problem)) {
                try service.discoverPackage(at: fixture.packageRoot, entrypoint: path)
            }
        }
    }

    @Test("Every parent-traversal shape is rejected before filesystem access")
    func traversalVariantsAreRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("SKILL.md", text: "safe")
        let service = YouziSkillPackageService()

        for path in ["../outside", "docs/../guide.md", "docs/../../outside", "a/b/.."] {
            #expect(
                throws: YouziSkillPackageError.invalidRelativePath(.parentTraversal)
            ) {
                try service.discoverPackage(at: fixture.packageRoot, entrypoint: path)
            }
        }
    }

    @Test("A leaf symlink is rejected even when its target is a regular UTF-8 file")
    func leafSymlinkEscapeIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let outside = try fixture.write("outside.md", text: "outside", beneath: fixture.outside)
        let link = fixture.packageRoot.appendingPathComponent("SKILL.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        #expect(
            throws: YouziSkillPackageError.pathContainsSymbolicLink(
                relativePath: "SKILL.md"
            )
        ) {
            try YouziSkillPackageService().discoverPackage(at: fixture.packageRoot)
        }
    }

    @Test("A nested symlink component cannot escape the package")
    func nestedSymlinkEscapeIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("SKILL.md", text: "safe")
        try fixture.write("guide.md", text: "outside", beneath: fixture.outside)
        let nested = fixture.packageRoot.appendingPathComponent("nested")
        try FileManager.default.createSymbolicLink(at: nested, withDestinationURL: fixture.outside)

        #expect(
            throws: YouziSkillPackageError.pathContainsSymbolicLink(
                relativePath: "nested/guide.md"
            )
        ) {
            try YouziSkillPackageService().discoverPackage(
                at: fixture.packageRoot,
                resourcePaths: ["nested/guide.md"]
            )
        }
    }

    @Test("A regular file cannot stand in for an intermediate directory")
    func nonDirectoryComponentIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("SKILL.md", text: "safe")
        try fixture.write("not-a-folder", text: "file")

        #expect(
            throws: YouziSkillPackageError.pathComponentIsNotDirectory(
                relativePath: "not-a-folder/resource.md"
            )
        ) {
            try YouziSkillPackageService().discoverPackage(
                at: fixture.packageRoot,
                resourcePaths: ["not-a-folder/resource.md"]
            )
        }
    }

    @Test("Missing entrypoint and resource errors remain distinguishable")
    func missingFilesAreRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = YouziSkillPackageService()

        #expect(
            throws: YouziSkillPackageError.missingEntrypoint(relativePath: "SKILL.md")
        ) {
            try service.discoverPackage(at: fixture.packageRoot)
        }

        try fixture.write("SKILL.md", text: "safe")
        #expect(
            throws: YouziSkillPackageError.missingResource(relativePath: "missing.md")
        ) {
            try service.discoverPackage(
                at: fixture.packageRoot,
                resourcePaths: ["missing.md"]
            )
        }
    }

    @Test("Directories cannot be used as entrypoints or resources")
    func directoryAsFileIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let skillDirectory = fixture.packageRoot.appendingPathComponent("SKILL.md")
        try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        let service = YouziSkillPackageService()

        #expect(
            throws: YouziSkillPackageError.fileIsNotRegular(relativePath: "SKILL.md")
        ) {
            try service.discoverPackage(at: fixture.packageRoot)
        }

        try FileManager.default.removeItem(at: skillDirectory)
        try fixture.write("SKILL.md", text: "safe")
        let resourceDirectory = fixture.packageRoot.appendingPathComponent("resource")
        try FileManager.default.createDirectory(
            at: resourceDirectory,
            withIntermediateDirectories: true
        )
        #expect(
            throws: YouziSkillPackageError.fileIsNotRegular(relativePath: "resource")
        ) {
            try service.discoverPackage(
                at: fixture.packageRoot,
                resourcePaths: ["resource"]
            )
        }
    }

    @Test("Invalid UTF-8 is rejected for entrypoints and explicitly declared resources")
    func invalidUTF8IsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let invalid = Data([0xC3, 0x28])
        let service = YouziSkillPackageService()

        try fixture.write("SKILL.md", data: invalid)
        #expect(
            throws: YouziSkillPackageError.invalidUTF8(relativePath: "SKILL.md")
        ) {
            try service.discoverPackage(at: fixture.packageRoot)
        }

        try fixture.write("SKILL.md", text: "safe")
        try fixture.write("invalid.md", data: invalid)
        #expect(
            throws: YouziSkillPackageError.invalidUTF8(relativePath: "invalid.md")
        ) {
            try service.discoverPackage(
                at: fixture.packageRoot,
                resourcePaths: ["invalid.md"]
            )
        }
    }

    @Test("Single-file limits apply to both entrypoint and resource content")
    func singleFileLimitIsEnforced() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = YouziSkillPackageService(
            limits: YouziSkillPackageLimits(
                maximumFileBytes: 4,
                maximumAggregateBytes: 20
            )
        )

        try fixture.write("SKILL.md", text: "12345")
        #expect(
            throws: YouziSkillPackageError.fileTooLarge(
                relativePath: "SKILL.md",
                maximumBytes: 4
            )
        ) {
            try service.discoverPackage(at: fixture.packageRoot)
        }

        try fixture.write("SKILL.md", text: "1234")
        try fixture.write("resource.md", text: "12345")
        #expect(
            throws: YouziSkillPackageError.fileTooLarge(
                relativePath: "resource.md",
                maximumBytes: 4
            )
        ) {
            try service.discoverPackage(
                at: fixture.packageRoot,
                resourcePaths: ["resource.md"]
            )
        }
    }

    @Test("Aggregate limits include the entrypoint and every declared resource")
    func aggregateLimitIsEnforced() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("SKILL.md", text: "1234")
        try fixture.write("resource.md", text: "12345")
        let service = YouziSkillPackageService(
            limits: YouziSkillPackageLimits(
                maximumFileBytes: 10,
                maximumAggregateBytes: 8
            )
        )

        #expect(
            throws: YouziSkillPackageError.aggregateTooLarge(maximumBytes: 8)
        ) {
            try service.discoverPackage(
                at: fixture.packageRoot,
                resourcePaths: ["resource.md"]
            )
        }
    }

    @Test("Invalid injected bounds fail closed")
    func invalidLimitsAreRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("SKILL.md", text: "safe")
        let service = YouziSkillPackageService(
            limits: YouziSkillPackageLimits(
                maximumFileBytes: 0,
                maximumAggregateBytes: 10
            )
        )

        #expect(throws: YouziSkillPackageError.invalidLimits) {
            try service.discoverPackage(at: fixture.packageRoot)
        }
    }

    @Test("Duplicate resources and entrypoint aliases are rejected deterministically")
    func duplicateDeclarationsAreRejected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("SKILL.md", text: "safe")
        try fixture.write("guide.md", text: "guide")
        let service = YouziSkillPackageService()

        #expect(
            throws: YouziSkillPackageError.duplicateDeclaredPath(
                relativePath: "guide.md"
            )
        ) {
            try service.discoverPackage(
                at: fixture.packageRoot,
                resourcePaths: ["guide.md", "guide.md"]
            )
        }
        #expect(
            throws: YouziSkillPackageError.duplicateDeclaredPath(
                relativePath: "SKILL.md"
            )
        ) {
            try service.discoverPackage(
                at: fixture.packageRoot,
                resourcePaths: ["SKILL.md"]
            )
        }
    }

    @Test("A resource replaced by a symlink after discovery fails closed on load")
    func packageReplacementIsRevalidated() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("SKILL.md", text: "safe")
        let resource = try fixture.write("guide.md", text: "original")
        let outside = try fixture.write("guide.md", text: "replacement", beneath: fixture.outside)
        let service = YouziSkillPackageService()
        let package = try service.discoverPackage(
            at: fixture.packageRoot,
            resourcePaths: ["guide.md"]
        )

        try FileManager.default.removeItem(at: resource)
        try FileManager.default.createSymbolicLink(at: resource, withDestinationURL: outside)

        #expect(
            throws: YouziSkillPackageError.pathContainsSymbolicLink(
                relativePath: "guide.md"
            )
        ) {
            try service.loadResource("guide.md", from: package)
        }
    }

    @Test("A resource that grows past its bound after discovery fails closed on load")
    func changedSizeIsRevalidated() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("SKILL.md", text: "one")
        try fixture.write("guide.md", text: "two")
        let service = YouziSkillPackageService(
            limits: YouziSkillPackageLimits(
                maximumFileBytes: 5,
                maximumAggregateBytes: 10
            )
        )
        let package = try service.discoverPackage(
            at: fixture.packageRoot,
            resourcePaths: ["guide.md"]
        )

        try fixture.write("guide.md", text: "123456")
        #expect(
            throws: YouziSkillPackageError.fileTooLarge(
                relativePath: "guide.md",
                maximumBytes: 5
            )
        ) {
            try service.loadResource("guide.md", from: package)
        }
    }

    @Test("Recovery descriptions never expose the selected machine path")
    func localizedErrorsDoNotLeakMachinePaths() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = YouziSkillPackageService()

        do {
            _ = try service.discoverPackage(at: fixture.packageRoot)
            Issue.record("Expected a missing entrypoint")
        } catch let error as YouziSkillPackageError {
            #expect(error == .missingEntrypoint(relativePath: "SKILL.md"))
            #expect(!error.localizedDescription.contains(fixture.sandbox.path))
            #expect(!error.localizedDescription.contains(fixture.packageRoot.path))
        }
    }
}
