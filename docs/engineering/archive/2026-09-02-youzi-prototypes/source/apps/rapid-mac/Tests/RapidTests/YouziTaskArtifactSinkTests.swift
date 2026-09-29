import Foundation
import Testing
@testable import Rapid

@Suite("Youzi task artifact persistence", .serialized)
struct YouziTaskArtifactSinkTests {
    @Test("Explicit local files persist once and replay by stable identity")
    func fileArtifactIsIdempotent() throws {
        let fixture = try ArtifactSinkFixture()
        defer { fixture.cleanup() }
        let source = fixture.root.appendingPathComponent("report.md")
        try Data("first result".utf8).write(to: source)
        let candidate = AssistantTurnArtifact(
            kind: .file,
            stableKey: "tool-call-7/report",
            title: "Research report",
            location: source.path,
            contentTypeIdentifier: "net.daringfireball.markdown",
            previewText: "first result"
        )

        let first = try fixture.sink.persist(fixture.request([candidate]))
        let second = try fixture.sink.persist(fixture.request([candidate]))
        let document = try fixture.store.load()

        #expect(first.count == 1)
        #expect(second == first)
        #expect(document.artifacts == first)
        #expect(document.files.count == 1)
        #expect(document.tasks[0].artifactIDs == [first[0].id])
        #expect(document.tasks[0].conversationID == fixture.conversationID)
        #expect(document.tasks[0].workspaceID == fixture.workspaceID)
        #expect(document.tasks[0].projectID == fixture.projectID)
        #expect(try fixture.persistedBytes(for: first[0]) == Data("first result".utf8))

        try Data("changed under same key".utf8).write(to: source)
        #expect(throws: YouziTaskArtifactPersistenceError.identityConflict(first[0].id)) {
            _ = try fixture.sink.persist(fixture.request([candidate]))
        }
        #expect(try fixture.persistedBytes(for: first[0]) == Data("first result".utf8))
    }

    @Test("Metadata is bounded JSON and remote content is never fetched")
    func metadataArtifact() throws {
        let fixture = try ArtifactSinkFixture()
        defer { fixture.cleanup() }
        let candidate = AssistantTurnArtifact(
            kind: .metadata,
            stableKey: "mcp:docs:resource:https://example.invalid/result/42",
            title: "Connected document",
            location: "https://example.invalid/result/42",
            contentTypeIdentifier: "text/markdown",
            previewText: "A concise preview",
            inlineContent: "# Produced by the connected app"
        )

        let artifacts = try fixture.sink.persist(fixture.request([candidate]))
        let artifact = try #require(artifacts.first)
        let data = try fixture.persistedBytes(for: artifact)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        #expect(artifact.kind == .document)
        #expect(object["formatIdentifier"] as? String
            == "com.rapidmlx.youzi.task-artifact-metadata")
        #expect(object["location"] as? String == candidate.location)
        #expect(object["inlineContent"] as? String == candidate.inlineContent)
        #expect(try fixture.store.load().files[0].contentTypeIdentifier == "public.json")
    }

    @Test("Grounding sources remain citations and never become Results records")
    func sourceIsNotDeliverable() throws {
        let fixture = try ArtifactSinkFixture()
        defer { fixture.cleanup() }
        let source = AssistantTurnArtifact(
            kind: .source,
            stableKey: "https://example.com/source",
            title: "Evidence",
            location: "https://example.com/source"
        )

        #expect(try fixture.sink.persist(fixture.request([source])).isEmpty)
        #expect(try fixture.store.load().artifacts.isEmpty)
        #expect(try fixture.store.load().files.isEmpty)
    }

    @Test("Conversation, workspace, and project ownership fail before byte writes")
    func exactOwnershipFailsClosed() throws {
        let fixture = try ArtifactSinkFixture()
        defer { fixture.cleanup() }
        let source = fixture.root.appendingPathComponent("private.txt")
        try Data("must not copy".utf8).write(to: source)
        let candidate = AssistantTurnArtifact(
            kind: .file,
            stableKey: "private-output",
            title: "Output",
            location: source.path
        )
        let mismatch = YouziTaskArtifactPersistenceRequest(
            taskID: fixture.taskID,
            conversationID: UUID(),
            workspaceID: fixture.workspaceID,
            projectID: fixture.projectID,
            artifacts: [candidate]
        )

        #expect(throws: YouziTaskArtifactPersistenceError.ownershipMismatch(
            taskID: fixture.taskID
        )) {
            _ = try fixture.sink.persist(mismatch)
        }
        #expect(try fixture.store.load().artifacts.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.filesRoot.path) == false)
    }

    @Test("A producer cannot alias two different outputs onto one stable key")
    func conflictingBatchFailsBeforeWrites() throws {
        let fixture = try ArtifactSinkFixture()
        defer { fixture.cleanup() }
        let first = AssistantTurnArtifact(
            kind: .metadata,
            stableKey: "same",
            title: "First",
            location: "urn:first"
        )
        let second = AssistantTurnArtifact(
            kind: .metadata,
            stableKey: "same",
            title: "Second",
            location: "urn:second"
        )

        #expect(throws: YouziTaskArtifactPersistenceError.duplicateStableKey("same")) {
            _ = try fixture.sink.persist(fixture.request([first, second]))
        }
        #expect(try fixture.store.load().artifacts.isEmpty)
    }

    @Test("MCP standard resource blocks become typed artifacts, not parsed prose")
    func mcpStructuredResources() throws {
        let response = MCPCatalog.ExecuteResponse(
            tool_name: "docs__create",
            content: .array([
                .object([
                    "type": .string("resource_link"),
                    "name": .string("Budget.xlsx"),
                    "uri": .string("https://docs.example.invalid/budget"),
                    "mimeType": .string("application/vnd.ms-excel"),
                ]),
                .object([
                    "type": .string("text"),
                    "text": .string("/tmp/looks-like-a-path.txt"),
                ]),
            ]),
            is_error: false,
            error_message: nil
        )

        #expect(response.artifacts.count == 1)
        #expect(response.artifacts[0].kind == .metadata)
        #expect(response.artifacts[0].title == "Budget.xlsx")
        #expect(response.artifacts[0].stableKey.contains("docs__create"))
    }
}

@MainActor
@Suite("Assistant turn typed artifact channel", .serialized)
struct AssistantTurnArtifactChannelTests {
    @Test("Successful tool artifacts reach the outcome without an extra chat row")
    func runnerCarriesTypedArtifact() async throws {
        ArtifactRunnerProtocol.reset()
        let artifact = AssistantTurnArtifact(
            kind: .metadata,
            stableKey: "create/42",
            title: "Created note",
            location: "notion://page/42"
        )
        let registry = ArtifactToolRegistry(artifact: artifact)
        let runner = AssistantTurnRunner(
            client: ChatStreamClient(
                baseURL: URL(string: "fake://artifact-runner")!,
                session: ArtifactRunnerProtocol.session()
            ),
            tools: registry
        )
        let started = runner.start(.init(
            conversationID: UUID(),
            alias: "artifact-model",
            messages: [ChatMessage(role: .user, content: "Create it")],
            supportsImageInput: false,
            definitions: registry.definitions
        ))

        let outcome = try #require(await runner.awaitOutcome(started.handle))
        #expect(outcome.status == .completed)
        #expect(outcome.artifacts == [artifact])
        #expect(outcome.messages.filter { $0.role == .tool }.count == 1)
        #expect(outcome.messages.filter { $0.role == .assistant }.count == 2)
        #expect(outcome.messages.last?.content == "Created successfully")
    }
}

private final class ArtifactSinkFixture {
    let root: URL
    let filesRoot: URL
    let taskID = UUID()
    let conversationID = UUID()
    let workspaceID = UUID()
    let projectID = UUID()
    let store: YouziDomainStore
    let sink: YouziTaskArtifactSink

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "youzi-artifact-sink-\(UUID().uuidString)",
            isDirectory: true
        )
        filesRoot = root.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = YouziDomainStore(fileURL: root.appendingPathComponent("domain.json"))
        let workspace = YouziWorkspace(
            id: workspaceID,
            name: "Workspace",
            location: .managed(relativePath: workspaceID.uuidString.lowercased())
        )
        let project = YouziProject(id: projectID, name: "Project")
        let task = YouziTask(
            id: taskID,
            title: "Task",
            request: "Produce a result",
            conversationID: conversationID,
            workspaceID: workspaceID,
            projectID: projectID
        )
        try store.save(.init(tasks: [task], workspaces: [workspace], projects: [project]))
        let workspaceAccess = YouziWorkspaceAccessCoordinator(
            managedRoot: root.appendingPathComponent("workspaces", isDirectory: true)
        )
        sink = YouziTaskArtifactSink(
            store: store,
            fileStore: YouziManagedFileStore(
                root: filesRoot,
                workspaceAccess: workspaceAccess
            ),
            now: { Date(timeIntervalSinceReferenceDate: 1_000) }
        )
    }

    func request(_ artifacts: [AssistantTurnArtifact]) -> YouziTaskArtifactPersistenceRequest {
        .init(
            taskID: taskID,
            conversationID: conversationID,
            workspaceID: workspaceID,
            projectID: projectID,
            artifacts: artifacts
        )
    }

    func persistedBytes(for artifact: YouziArtifact) throws -> Data {
        let document = try store.load()
        let file = try #require(document.files.first(where: { $0.id == artifact.fileID }))
        guard case .appManaged(let relativePath) = file.location else {
            throw YouziTaskArtifactPersistenceError.identityConflict(artifact.id)
        }
        return try Data(contentsOf: filesRoot.appendingPathComponent(relativePath))
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@MainActor
private final class ArtifactToolRegistry: ToolRegistry {
    let artifact: AssistantTurnArtifact
    let definitions = [
        ToolDefinition(
            name: "create_result",
            description: "Create a result",
            parameters: .object(["type": .string("object")])
        ),
    ]

    init(artifact: AssistantTurnArtifact) { self.artifact = artifact }

    func run(_ call: ToolCall) async -> ToolCallResult {
        ToolCallResult(
            toolCallID: call.id,
            content: "created",
            artifacts: [artifact]
        )
    }
}

private final class ArtifactRunnerProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requestCount = 0

    static func reset() { lock.withLock { requestCount = 0 } }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ArtifactRunnerProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let count = Self.lock.withLock {
            Self.requestCount += 1
            return Self.requestCount
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let stream: String
        if count == 1 {
            stream = """
            data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"create_result","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}

            data: [DONE]

            """
        } else {
            stream = """
            data: {"choices":[{"delta":{"content":"Created successfully"},"finish_reason":"stop"}]}

            data: [DONE]

            """
        }
        client?.urlProtocol(self, didLoad: Data(stream.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
