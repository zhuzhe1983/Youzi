#!/usr/bin/env python3
"""Run memory/domain regressions without compiling or launching the desktop app.

The temporary target uses production domain, lifecycle, product, service, queue,
and extraction sources. Only the unrelated chat history shape and HTTP URL
builder have minimal seams; no test invokes the transport. Full application
integration still needs the regular SwiftPM test/build gate.
"""

import os
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources" / "Rapid"
TESTS = [
    "MemoryStoreTests.swift",
    "YouziDomainTests.swift",
    "YouziDomainMigrationTests.swift",
    "YouziMemoryServiceTests.swift",
    "YouziMemoryIngestionQueueTests.swift",
]
MANIFEST = """// swift-tools-version:6.0
import PackageDescription
let package = Package(name: "MemoryIsolation", platforms: [.macOS(.v14)], targets: [
    .target(name: "Rapid"), .testTarget(name: "RapidTests", dependencies: ["Rapid"])
])
"""
SEAMS = """import Foundation
// Unrelated app boundaries only: production domain/product/memory code is linked unchanged.
enum ChatStreamClient {
    static func chatCompletionsURL(base: URL) -> URL { base.appendingPathComponent("v1/chat/completions") }
}
struct ChatConversation {
    let id: UUID; let title: String; let messages: [ChatMessage]
    let isArchived: Bool; let isPinned: Bool; let createdAt: Date; let updatedAt: Date
}
struct ChatMessage {
    enum Role { case user, assistant }
    enum Status { case failed, streaming, complete }
    let role: Role; let status: Status; let content: String
}
"""


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="youzi-memory-tests-") as directory:
        package = Path(directory)
        source_target = package / "Sources" / "Rapid"
        test_target = package / "Tests" / "RapidTests"
        source_target.mkdir(parents=True)
        test_target.mkdir(parents=True)
        production = [
            path
            for path in (SOURCES / "YouziDomain").glob("*.swift")
            if path.name not in {"YouziTaskActions.swift", "YouziShareHistory.swift"}
        ]
        production += [
            SOURCES / path
            for path in [
                "Chat/MemoryStore.swift",
                "Chat/MemoryExtractor.swift",
                "Chat/YouziMemoryIngestionQueue.swift",
                "Server/ApplicationSupportLocator.swift",
            ]
        ]
        for path in production:
            (source_target / path.name).symlink_to(path)
        for name in TESTS:
            (test_target / name).symlink_to(ROOT / "Tests" / "RapidTests" / name)
        (package / "Package.swift").write_text(MANIFEST)
        (source_target / "IsolationSeams.swift").write_text(SEAMS)
        environment = dict(os.environ, RAPID_DESKTOP_NO_PORT_SWEEP="1")
        return subprocess.run(
            ["swift", "test", "--jobs", "4"], cwd=package, env=environment
        ).returncode


if __name__ == "__main__":
    raise SystemExit(main())
