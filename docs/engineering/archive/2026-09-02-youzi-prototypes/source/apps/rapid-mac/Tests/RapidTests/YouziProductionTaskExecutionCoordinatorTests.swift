import Foundation
import Testing
@testable import Rapid

@MainActor
@Suite("Youzi production execution composition", .serialized)
struct YouziProductionTaskExecutionCoordinatorTests {
    @Test("Missing alias and active-conversation conflicts create no transcript or request")
    func sideEffectsRequireAliasAndReservation() async throws {
        WS28Protocol.reset()
        let fixture = try Fixture(alias: nil)
        defer { fixture.cleanup() }
        let taskID = UUID()
        try fixture.saveTask(id: taskID)
        let request = Fixture.interactive(taskID)

        #expect(await fixture.coordinator.execute(taskID: taskID, request: request)
            == .retryableFailure(recoveryCode: .runtimeUnavailable))
        #expect(fixture.chat.conversationSnapshot(id: taskID) == nil)
        #expect(WS28Protocol.requestCount == 0)

        let activeID = fixture.chat.activeConversationID
        try fixture.saveTask(id: activeID)
        let activeWorkspaceIDsBefore = try fixture.store.load().workspaces.map(\.id)
        fixture.alias = "fast-model"
        let activeRequest = Fixture.interactive(activeID)
        #expect(await fixture.coordinator.execute(taskID: activeID, request: activeRequest)
            == .retryableFailure(recoveryCode: .runtimeUnavailable))
        #expect(fixture.chat.messages.isEmpty)
        #expect(fixture.chat.conversationSnapshot(id: activeID) == nil)
        #expect(WS28Protocol.requestCount == 0)
        let afterConflict = try fixture.store.load()
        #expect(afterConflict.workspaces.map(\.id) == activeWorkspaceIDsBefore)
        #expect(afterConflict.tasks.first(where: { $0.id == activeID })?.workspaceID == nil)
    }

    @Test("Cancellation targets only the exact task and origin handle")
    func exactCancellation() async throws {
        WS28Protocol.reset()
        let fixture = try Fixture(alias: "held-model")
        defer { fixture.cleanup() }
        let taskID = UUID()
        try fixture.saveTask(id: taskID)
        let request = Fixture.interactive(taskID)
        let execution = Task { await fixture.coordinator.execute(taskID: taskID, request: request) }
        await waitUntilReserved(chat: fixture.chat, id: taskID)
        #expect(fixture.chat.reserveBackgroundConversation(id: taskID) == nil)

        await fixture.coordinator.cancel(
            taskID: taskID,
            origin: .automation(automationID: UUID(), revision: 1, runID: UUID())
        )
        await Task.yield()
        #expect(fixture.chat.reserveBackgroundConversation(id: taskID) == nil)
        await fixture.coordinator.cancel(taskID: taskID, origin: .interactive)

        #expect(await execution.value == .cancelled)
        let released = try #require(fixture.chat.reserveBackgroundConversation(id: taskID))
        fixture.chat.releaseBackgroundConversation(released)
    }

    @Test("Background completion uses the shared runner and preserves sidebar metadata")
    func sharedRunnerAndMetadataMerge() async throws {
        WS28Protocol.reset()
        let fixture = try Fixture(alias: "fast-model")
        defer { fixture.cleanup() }
        #expect(fixture.chat.assistantTurnRunner === fixture.runner)
        let taskID = UUID()
        try fixture.saveTask(id: taskID, title: "Generated title")
        let folder = try #require(fixture.chat.createFolder(named: "Scheduled"))
        let conversationDate = Date(timeIntervalSinceReferenceDate: 800)
        let original = ChatConversation(
            id: taskID,
            title: "Generated title",
            messages: [ChatMessage(role: .user, content: "old")],
            createdAt: conversationDate,
            updatedAt: conversationDate,
            isPinned: true,
            isArchived: false,
            hasCustomTitle: false,
            hasGeneratedTitle: true,
            customInstructions: "Keep metadata",
            folderID: folder.id
        )
        #expect(fixture.chat.upsertBackgroundConversation(original) != nil)
        #expect(fixture.chat.renameConversation(taskID, to: "User title"))
        fixture.chat.moveConversation(taskID, toFolder: folder.id)

        let request = Fixture.interactive(taskID)
        #expect(await fixture.coordinator.execute(taskID: taskID, request: request)
            == .completed(summary: .init("fast complete")))

        let merged = try #require(fixture.chat.conversationSnapshot(id: taskID))
        #expect(merged.title == "User title")
        #expect(merged.hasCustomTitle)
        #expect(merged.isPinned)
        #expect(merged.folderID == folder.id)
        #expect(merged.customInstructions == "Keep metadata")
        #expect(merged.messages.last?.content == "fast complete")
        #expect(WS28Protocol.requestCount == 1)
    }

    @Test("Automation grant snapshot mismatch fails before runner or transcript")
    func permissionSnapshotFailsClosed() async throws {
        WS28Protocol.reset()
        let fixture = try Fixture(alias: "fast-model")
        defer { fixture.cleanup() }
        let now = Date(timeIntervalSinceReferenceDate: 900)
        let automationID = UUID()
        let runID = UUID()
        let permissionID = UUID()
        let grantID = UUID()
        let action = YouziAutomationAction(
            request: "scheduled",
            skillIDs: [],
            connectionAccountIDs: []
        )
        try fixture.store.save(.init(
            permissions: [YouziPermissionRecord(
                id: permissionID,
                automationID: automationID,
                automationRevision: 1,
                kind: .networkAccess,
                targetIdentifier: "builtin.network",
                purpose: "Scheduled request",
                duration: .persistent,
                decision: .allowed,
                requestedAt: now,
                decidedAt: now
            )],
            permissionGrants: [YouziPermissionGrant(
                id: grantID,
                permissionRecordID: permissionID,
                automationID: automationID,
                automationRevision: 1,
                kind: .networkAccess,
                targetIdentifier: "builtin.network",
                duration: .persistent,
                grantedAt: now
            )],
            automations: [YouziAutomation(
                id: automationID,
                name: "Scheduled",
                trigger: .manual,
                action: action,
                permissionRecordIDs: [permissionID],
                permissionGrantIDs: [grantID],
                state: .active,
                confirmedAt: now,
                createdAt: now,
                updatedAt: now
            )],
            automationRuns: [YouziAutomationRun(
                id: runID,
                automationID: automationID,
                automationRevision: 1,
                permissionGrantIDs: [grantID],
                attemptCount: 0,
                status: .queued,
                createdAt: now,
                startedAt: nil
            )]
        ))
        fixture.productModel.refresh()
        let request = YouziTaskExecutionRequest(
            origin: .automation(automationID: automationID, revision: 1, runID: runID),
            input: .automationAction(action),
            permissionGrantIDs: []
        )

        #expect(await fixture.coordinator.prepare(request)
            == .unavailable(recoveryCode: .automationRevisionChanged))
        #expect(try fixture.store.load().tasks.isEmpty)
        #expect(WS28Protocol.requestCount == 0)
    }

    @Test("Artifact persistence fails closed before publishing a completed transcript")
    func artifactFailurePreventsCompletionAndTranscriptWrite() async throws {
        WS28Protocol.reset()
        let artifactSink = RecordingArtifactSink(shouldFail: true)
        let fixture = try Fixture(alias: "fast-model", artifactSink: artifactSink)
        defer { fixture.cleanup() }
        let taskID = UUID()
        try fixture.saveTask(id: taskID)

        #expect(await fixture.coordinator.execute(
            taskID: taskID,
            request: Fixture.interactive(taskID)
        ) == .retryableFailure(recoveryCode: .runtimeUnavailable))

        let task = try #require(try fixture.store.load().tasks.first(where: { $0.id == taskID }))
        #expect(task.status == .failed)
        #expect(task.completedAt == nil)
        #expect(task.failureSummary == "任务结果保存失败，请稍后重试。")
        #expect(fixture.chat.conversationSnapshot(id: taskID) == nil)
        #expect(artifactSink.requests.count == 1)
        #expect(artifactSink.requests[0].taskID == taskID)
        #expect(artifactSink.requests[0].conversationID == taskID)
        #expect(artifactSink.requests[0].workspaceID == task.workspaceID)
        #expect(WS28Protocol.requestCount == 1)
    }

    @Test("RapidApp wires one store, coordinator, center, lifecycle, and termination path")
    func rapidAppCompositionContract() throws {
        let testURL = URL(fileURLWithPath: #filePath)
        let appURL = testURL.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/Rapid/RapidApp.swift")
        let source = try String(contentsOf: appURL, encoding: .utf8)

        #expect(source.components(separatedBy: "let youziDomainStore = YouziDomainStore()").count == 2)
        #expect(source.contains("store: youziDomainStore,\n            productModel: productModel,\n            chat: chat"))
        #expect(source.contains("runtimeSnapshot: { mcpRuntimeOwner.snapshot() }"))
        #expect(source.contains("coordinator: productionTaskCoordinator"))
        #expect(source.contains("_automationCenter = State(initialValue: automationCenter)"))
        #expect(source.contains("AppDelegate.shared.automationCenter = automationCenter"))
        #expect(source.contains("await automationCenter.start()"))
        #expect(source.contains("await automationCenter.foregroundWake()"))
        #expect(source.contains("automationCenter?.requestShutdownForTermination()"))
    }

    private func waitUntilReserved(chat: ChatViewModel, id: UUID) async {
        for _ in 0..<10_000 {
            if let probe = chat.reserveBackgroundConversation(id: id) {
                chat.releaseBackgroundConversation(probe)
                await Task.yield()
            } else {
                return
            }
        }
    }
}

@MainActor
private final class Fixture {
    let root: URL
    let store: YouziDomainStore
    let productModel: YouziProductModel
    let runner: AssistantTurnRunner
    let chat: ChatViewModel
    let coordinator: YouziProductionTaskExecutionCoordinator
    private let aliasBox: AliasBox
    var alias: String? {
        get { aliasBox.value }
        set { aliasBox.value = newValue }
    }

    init(
        alias: String?,
        artifactSink: (any YouziTaskArtifactPersisting)? = nil
    ) throws {
        let aliasBox = AliasBox(alias)
        self.aliasBox = aliasBox
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("youzi-production-coordinator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = YouziDomainStore(fileURL: root.appendingPathComponent("domain.json"))
        productModel = YouziProductModel(store: store)
        runner = AssistantTurnRunner(
            client: ChatStreamClient(
                baseURL: URL(string: "fake://ws28")!,
                session: WS28Protocol.session()
            ),
            tools: EmptyToolRegistry()
        )
        chat = ChatViewModel(
            tools: EmptyToolRegistry(),
            assistantTurnRunner: runner,
            persistsConversations: false
        )
        let preparation = YouziCanonicalTaskPreparationService(
            store: store,
            productModel: productModel,
            lifecycle: YouziLifecycleRepository(
                store: store,
                workspaceAccess: YouziWorkspaceAccessCoordinator(
                    managedRoot: root.appendingPathComponent("workspaces", isDirectory: true)
                )
            )
        )
        coordinator = YouziProductionTaskExecutionCoordinator(
            store: store,
            productModel: productModel,
            chat: chat,
            preparation: preparation,
            artifactSink: artifactSink,
            runtimeSnapshot: { .init(connectorsEnabled: false) },
            aliasProvider: { aliasBox.value }
        )
    }

    func saveTask(id: UUID, title: String = "Task") throws {
        _ = try store.update { document in
            document.upsert(YouziTask(
                id: id,
                title: title,
                request: "Run task",
                conversationID: id,
                status: .draft
            ))
        }
        productModel.refresh()
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    static func interactive(_ taskID: UUID) -> YouziTaskExecutionRequest {
        .init(origin: .interactive, input: .existingTask(taskID: taskID), permissionGrantIDs: [])
    }
}

private final class RecordingArtifactSink: YouziTaskArtifactPersisting, @unchecked Sendable {
    enum Failure: Error { case injected }

    let shouldFail: Bool
    private(set) var requests: [YouziTaskArtifactPersistenceRequest] = []

    init(shouldFail: Bool) { self.shouldFail = shouldFail }

    func persist(_ request: YouziTaskArtifactPersistenceRequest) throws -> [YouziArtifact] {
        requests.append(request)
        if shouldFail { throw Failure.injected }
        return []
    }
}

@MainActor
private final class AliasBox {
    var value: String?
    init(_ value: String?) { self.value = value }
}

private final class WS28Protocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var requests = 0

    static var requestCount: Int { lock.withLock { requests } }
    static func reset() { lock.withLock { requests = 0 } }
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WS28Protocol.self]
        return URLSession(configuration: configuration)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self.requests += 1 }
        let body = request.httpBody ?? readBody()
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let alias = object?["model"] as? String
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        guard alias != "held-model" else { return }
        let stream = """
        data: {"choices":[{"delta":{"content":"fast complete"},"finish_reason":"stop"}]}

        data: [DONE]

        """
        client?.urlProtocol(self, didLoad: Data(stream.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func readBody() -> Data {
        guard let input = request.httpBodyStream else { return Data() }
        input.open()
        defer { input.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while input.hasBytesAvailable {
            let count = input.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
