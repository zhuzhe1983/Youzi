import Foundation
import Testing
@testable import Rapid

@MainActor
@Suite("AssistantTurnRunner canonical execution", .serialized)
struct AssistantTurnRunnerTests {
    @Test("independent handles complete and cancel without cross-turn cancellation")
    func independentCancellation() async throws {
        AssistantTurnRunnerProtocol.reset()
        let runner = AssistantTurnRunner(
            client: ChatStreamClient(
                baseURL: URL(string: "fake://assistant-runner")!,
                session: AssistantTurnRunnerProtocol.session()
            ),
            tools: EmptyToolRegistry()
        )
        let held = runner.start(request(alias: "held-model", prompt: "hold"))
        let fast = runner.start(request(alias: "fast-model", prompt: "finish"))

        let fastOutcome = try #require(await runner.awaitOutcome(fast.handle))
        runner.cancel(held.handle)
        let heldOutcome = try #require(await runner.awaitOutcome(held.handle))

        #expect(fastOutcome.status == .completed)
        #expect(fastOutcome.messages.last?.content == "fast complete")
        #expect(heldOutcome.status == .cancelled)
        #expect(heldOutcome.messages.last?.status == .complete)
        #expect(heldOutcome.messages.last?.errorMessage == "Stopped.")
        #expect(!runner.isRunning(fast.handle))
        #expect(!runner.isRunning(held.handle))
    }

    @Test("typed events and outcome carry one canonical transcript")
    func typedEventsCarryCanonicalTranscript() async throws {
        AssistantTurnRunnerProtocol.reset()
        let runner = AssistantTurnRunner(
            client: ChatStreamClient(
                baseURL: URL(string: "fake://assistant-runner")!,
                session: AssistantTurnRunnerProtocol.session()
            ),
            tools: EmptyToolRegistry()
        )
        let started = runner.start(request(alias: "fast-model", prompt: "finish"))
        #expect(started.initialMessages.map(\.role) == [.user, .assistant])
        #expect(started.initialMessages.last?.status == .streaming)

        let outcome = try #require(await runner.awaitOutcome(started.handle))
        var events: [AssistantTurnRunner.Event] = []
        for await event in started.events { events.append(event) }

        #expect(events.first?.phase == .started)
        #expect(events.contains { $0.phase == .completed })
        #expect(events.last?.messages == outcome.messages)
        #expect(outcome.summary == "fast complete")
        #expect(outcome.artifacts.isEmpty)
        #expect(outcome.executedToolCount == 0)
    }

    private func request(alias: String, prompt: String) -> AssistantTurnRunner.Request {
        AssistantTurnRunner.Request(
            conversationID: UUID(),
            alias: alias,
            messages: [ChatMessage(role: .user, content: prompt)],
            supportsImageInput: false,
            definitions: []
        )
    }
}

@MainActor
@Suite("ChatViewModel canonical background persistence", .serialized)
struct AssistantTurnPersistenceTests {
    @Test("background upsert preserves user-managed metadata and notifies observer")
    func metadataPreserved() throws {
        let model = ChatViewModel(persistsConversations: false)
        let observer = AssistantTurnConversationObserver()
        model.setConversationLifecycleObserver(observer)
        let id = UUID()
        let folder = try #require(model.createFolder(named: "Scheduled"))
        let original = conversation(
            id: id,
            title: "Automatic title",
            answer: "first",
            instructions: "Keep this instruction"
        )
        #expect(model.upsertBackgroundConversation(original) != nil)
        #expect(model.renameConversation(id, to: "User title"))
        model.moveConversation(id, toFolder: folder.id)
        model.setConversationArchived(id, true)

        let replacement = conversation(
            id: id,
            title: "Replacement title",
            answer: "second",
            instructions: nil
        )
        let merged = try #require(model.upsertBackgroundConversation(replacement))

        #expect(merged.title == "User title")
        #expect(merged.hasCustomTitle)
        #expect(merged.isArchived)
        #expect(merged.folderID == folder.id)
        #expect(merged.customInstructions == "Keep this instruction")
        #expect(merged.messages.last?.content == "second")
        #expect(model.conversationSnapshot(id: id) == merged)
        #expect(observer.persisted.last == merged)

        model.setConversationPinned(id, true)
        let pinned = try #require(model.upsertBackgroundConversation(replacement))
        #expect(pinned.isPinned)
        #expect(!pinned.isArchived)
    }

    @Test("background upsert refuses the active conversation instead of overwriting it")
    func activeConversationConflict() {
        let model = ChatViewModel(persistsConversations: false)
        let incoming = conversation(
            id: model.activeConversationID,
            title: "Must not land",
            answer: "background",
            instructions: nil
        )

        #expect(model.upsertBackgroundConversation(incoming) == nil)
        #expect(model.messages.isEmpty)
        #expect(model.conversationSnapshot(id: incoming.id) == nil)
    }

    @Test("reservation rejects active and occupied IDs and blocks foreground selection")
    func reservationBlocksSelection() throws {
        let model = ChatViewModel(persistsConversations: false)
        #expect(model.reserveBackgroundConversation(id: model.activeConversationID) == nil)

        let backgroundID = UUID()
        let incoming = conversation(
            id: backgroundID,
            title: "Scheduled",
            answer: "ready",
            instructions: nil
        )
        #expect(model.upsertBackgroundConversation(incoming) != nil)
        let foregroundID = model.activeConversationID
        let reservation = try #require(
            model.reserveBackgroundConversation(id: backgroundID)
        )
        #expect(model.reserveBackgroundConversation(id: backgroundID) == nil)

        model.selectConversation(backgroundID)
        #expect(model.activeConversationID == foregroundID)
        #expect(model.messages.isEmpty)

        model.releaseBackgroundConversation(reservation)
        model.selectConversation(backgroundID)
        #expect(model.activeConversationID == backgroundID)
        #expect(model.messages.last?.content == "ready")
    }

    @Test("a stale release cannot unlock a newer reservation")
    func reservationReleaseIsExact() throws {
        let model = ChatViewModel(persistsConversations: false)
        let id = UUID()
        let first = try #require(model.reserveBackgroundConversation(id: id))
        model.releaseBackgroundConversation(first)
        let second = try #require(model.reserveBackgroundConversation(id: id))

        model.releaseBackgroundConversation(first)
        #expect(model.reserveBackgroundConversation(id: id) == nil)

        model.releaseBackgroundConversation(second)
        #expect(model.reserveBackgroundConversation(id: id) != nil)
    }

    private func conversation(
        id: UUID,
        title: String,
        answer: String,
        instructions: String?
    ) -> ChatConversation {
        let created = Date(timeIntervalSince1970: 1_800_000_000)
        return ChatConversation(
            id: id,
            title: title,
            messages: [
                ChatMessage(role: .user, content: "scheduled request", createdAt: created),
                ChatMessage(
                    role: .assistant,
                    content: answer,
                    createdAt: created.addingTimeInterval(1)
                ),
            ],
            createdAt: created,
            updatedAt: created.addingTimeInterval(2),
            customInstructions: instructions
        )
    }
}

@MainActor
private final class AssistantTurnConversationObserver: ChatConversationLifecycleObserver {
    var persisted: [ChatConversation] = []

    func conversationHistoryDidLoad(_ conversations: [ChatConversation]) {}
    func conversationDidPersist(_ conversation: ChatConversation) {
        persisted.append(conversation)
    }
    func conversationWasDeleted(id: UUID) {}
}

private final class AssistantTurnRunnerProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var aliases: [String] = []

    static func reset() {
        lock.withLock { aliases = [] }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AssistantTurnRunnerProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = readBody(from: request)
        let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let alias = object?["model"] as? String ?? "unknown"
        Self.lock.withLock { Self.aliases.append(alias) }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if alias == "held-model" {
            client?.urlProtocol(
                self,
                didLoad: Data("data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n\n".utf8)
            )
            return
        }
        let stream = """
        data: {"choices":[{"delta":{"content":"fast complete"},"finish_reason":"stop"}]}

        data: [DONE]

        """
        client?.urlProtocol(self, didLoad: Data(stream.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func readBody(from request: URLRequest) -> Data {
        guard let input = request.httpBodyStream else { return request.httpBody ?? Data() }
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
