import Foundation
import Testing
@testable import Rapid

@MainActor
@Suite("Youzi scoped chat turn", .serialized)
struct YouziScopedChatTurnTests {
    @Test("Legacy send retains the complete enabled registry and needs no domain authorizer")
    func legacyCompatibility() async throws {
        ScopedTurnProtocol.reset([
            .toolCall(name: "alpha", id: "legacy_call"),
            .terminal("legacy complete"),
        ])
        let registry = ScopedTurnRegistry()
        let model = makeModel(registry: registry)

        model.send("Use the normal tools", alias: "test-model")
        await model._testingWaitForCurrentTurn()

        #expect(registry.calls.map(\.function.name) == ["alpha"])
        let bodies = ScopedTurnProtocol.capturedBodies()
        #expect(bodies.count == 2)
        #expect(try toolNames(in: bodies[0]) == ["alpha", "beta"])
        #expect(try toolNames(in: bodies[1]) == ["alpha", "beta"])
        #expect(model.messages.last?.content == "legacy complete")
    }

    @Test("Exact scoped definitions and instructions stay frozen on every tool-loop round")
    func frozenContextAcrossRoundsAndMutation() async throws {
        ScopedTurnProtocol.reset([
            .toolCall(name: "alpha", id: "frozen_call"),
            .terminal("scoped complete"),
        ])
        let registry = ScopedTurnRegistry()
        let authorizer = RecordingDispatchAuthorizer(decision: .authorized)
        let model = makeModel(registry: registry)
        registry.onRun = {
            // Global UI state changes after the first dispatch. The immutable
            // turn snapshot must neither widen to beta nor lose alpha midway.
            model.setToolEnabled("alpha", false)
            model.setToolEnabled("beta", true)
        }
        let instruction = "[VERIFIED TASK CONTEXT]\nUse only verified project facts."
        var context = YouziScopedChatTurnContext(
            subject: .interactiveTask(id(1)),
            instructionComponent: instruction,
            advertisedToolNames: ["alpha"]
        )

        model.send(
            "Run the scoped task",
            alias: "test-model",
            executionContext: context,
            dispatchAuthorizer: authorizer
        )
        // Reassign the caller's value before the async task gets a chance to
        // run; send already captured the original struct and definitions.
        context = YouziScopedChatTurnContext(
            subject: .interactiveTask(id(2)),
            instructionComponent: "MUTATED CONTEXT",
            advertisedToolNames: ["beta"]
        )
        _ = context
        await model._testingWaitForCurrentTurn()

        let bodies = ScopedTurnProtocol.capturedBodies()
        #expect(bodies.count == 2)
        #expect(try toolNames(in: bodies[0]) == ["alpha"])
        #expect(try toolNames(in: bodies[1]) == ["alpha"])
        let firstSystemText = try systemText(in: bodies[0])
        let secondSystemText = try systemText(in: bodies[1])
        #expect(firstSystemText.contains(instruction))
        #expect(secondSystemText.contains(instruction))
        #expect(!firstSystemText.contains("MUTATED CONTEXT"))
        #expect(authorizer.requests == [
            .init(subject: .interactiveTask(id(1)), toolName: "alpha")
        ])
        #expect(registry.calls.map(\.function.name) == ["alpha"])
        #expect(!model.messages.contains { $0.content.contains("VERIFIED TASK CONTEXT") })
        #expect(!model.messages.contains { $0.role == .system })
    }

    @Test("Explicit empty scoped advertisement sends and runs no tools")
    func explicitEmpty() async throws {
        ScopedTurnProtocol.reset([.terminal("direct answer")])
        let registry = ScopedTurnRegistry()
        let authorizer = RecordingDispatchAuthorizer(decision: .authorized)
        let model = makeModel(registry: registry)
        let context = YouziScopedChatTurnContext(
            subject: .interactiveTask(id(1)),
            instructionComponent: "Answer directly.",
            advertisedToolNames: []
        )

        model.send(
            "No tools",
            alias: "test-model",
            executionContext: context,
            dispatchAuthorizer: authorizer
        )
        await model._testingWaitForCurrentTurn()

        let body = try #require(ScopedTurnProtocol.capturedBodies().first)
        #expect(try toolNames(in: body).isEmpty)
        #expect(registry.calls.isEmpty)
        #expect(authorizer.requests.isEmpty)
    }

    @Test("Unselected and invented calls are refused before authorization or registry dispatch")
    func inventedToolRefusal() async throws {
        ScopedTurnProtocol.reset([
            .toolCall(name: "beta", id: "invented_call"),
            .terminal("answered without it"),
        ])
        let registry = ScopedTurnRegistry()
        let authorizer = RecordingDispatchAuthorizer(decision: .authorized)
        let model = makeModel(registry: registry)
        let context = YouziScopedChatTurnContext(
            subject: .interactiveTask(id(1)),
            instructionComponent: "Use the selected tool only.",
            advertisedToolNames: ["alpha"]
        )

        model.send(
            "Try an unselected tool",
            alias: "test-model",
            executionContext: context,
            dispatchAuthorizer: authorizer
        )
        await model._testingWaitForCurrentTurn()

        #expect(authorizer.requests.isEmpty)
        #expect(registry.calls.isEmpty)
        let toolRow = try #require(model.messages.first { $0.role == .tool })
        #expect(toolRow.toolCallID == "invented_call")
        #expect(toolRow.status == .failed)
        #expect(toolRow.content.contains("isn't available"))
        let secondBody = try #require(ScopedTurnProtocol.capturedBodies().last)
        let paired = try #require(toolMessages(in: secondBody).first)
        #expect(paired["tool_call_id"] as? String == "invented_call")
    }

    @Test("Missing scoped authorizer fails closed with a paired stable result")
    func missingAuthorizerFailsClosed() async throws {
        ScopedTurnProtocol.reset([
            .toolCall(name: "alpha", id: "missing_auth_call"),
            .terminal("continued safely"),
        ])
        let registry = ScopedTurnRegistry()
        let model = makeModel(registry: registry)
        let context = YouziScopedChatTurnContext(
            subject: .interactiveTask(id(1)),
            instructionComponent: "Scoped instructions",
            advertisedToolNames: ["alpha"]
        )

        model.send(
            "Requires authorization",
            alias: "test-model",
            executionContext: context
        )
        await model._testingWaitForCurrentTurn()

        #expect(registry.calls.isEmpty)
        let toolRow = try #require(model.messages.first { $0.role == .tool })
        #expect(toolRow.toolCallID == "missing_auth_call")
        #expect(toolRow.status == .failed)
        #expect(toolRow.content ==
            "Scoped tool authorization is unavailable. Continue without using the tool.")
        let secondBody = try #require(ScopedTurnProtocol.capturedBodies().last)
        let paired = try #require(toolMessages(in: secondBody).first)
        #expect(paired["tool_call_id"] as? String == "missing_auth_call")
        #expect(paired["content"] as? String == toolRow.content)
    }

    @Test("Typed authorization denial is paired and never dispatches raw arguments")
    func denialResultPairing() async throws {
        ScopedTurnProtocol.reset([
            .toolCall(name: "alpha", id: "denied_call", arguments: #"{"secret":"do-not-pass"}"#),
            .terminal("permission explained"),
        ])
        let registry = ScopedTurnRegistry()
        let authorizer = RecordingDispatchAuthorizer(
            decision: .denied(.domainPermissionRequired)
        )
        let model = makeModel(registry: registry)
        let subject = YouziExecutionPermissionSubject.automation(id: id(9), revision: 4)
        let context = YouziScopedChatTurnContext(
            subject: subject,
            instructionComponent: "Automation instructions",
            advertisedToolNames: ["alpha"]
        )

        model.send(
            "Scheduled task",
            alias: "test-model",
            executionContext: context,
            dispatchAuthorizer: authorizer
        )
        await model._testingWaitForCurrentTurn()

        #expect(authorizer.requests == [.init(subject: subject, toolName: "alpha")])
        #expect(registry.calls.isEmpty)
        let toolRow = try #require(model.messages.first { $0.role == .tool })
        #expect(toolRow.toolCallID == "denied_call")
        #expect(toolRow.content == "Permission is required before this task can use the tool.")
        #expect(!toolRow.content.contains("do-not-pass"))
        let finalBody = try #require(ScopedTurnProtocol.capturedBodies().last)
        let paired = try #require(toolMessages(in: finalBody).first)
        #expect(paired["tool_call_id"] as? String == "denied_call")
        #expect(paired["content"] as? String == toolRow.content)
    }

    @Test("Cancellation discards scoped state and the next legacy turn cannot inherit it")
    func cancellationDoesNotBleed() async throws {
        ScopedTurnProtocol.reset([.hanging])
        let registry = ScopedTurnRegistry()
        let authorizer = RecordingDispatchAuthorizer(decision: .authorized)
        let model = makeModel(registry: registry)
        let marker = "SCOPED-CANCEL-MARKER"
        let context = YouziScopedChatTurnContext(
            subject: .interactiveTask(id(1)),
            instructionComponent: marker,
            advertisedToolNames: ["alpha"]
        )

        model.send(
            "Cancel this scoped turn",
            alias: "test-model",
            executionContext: context,
            dispatchAuthorizer: authorizer
        )
        try await waitUntil { ScopedTurnProtocol.capturedBodies().count == 1 }
        model.stop()
        try await waitUntil { !model.isStreaming && ScopedTurnProtocol.stopCount > 0 }

        ScopedTurnProtocol.enqueue(.terminal("legacy after cancel"))
        model.send("Next legacy turn", alias: "test-model")
        await model._testingWaitForCurrentTurn()

        let bodies = ScopedTurnProtocol.capturedBodies()
        #expect(bodies.count == 2)
        #expect(try toolNames(in: bodies[0]) == ["alpha"])
        #expect(try toolNames(in: bodies[1]) == ["alpha", "beta"])
        let scopedSystemText = try systemText(in: bodies[0])
        let legacySystemText = try systemText(in: bodies[1])
        #expect(scopedSystemText.contains(marker))
        #expect(!legacySystemText.contains(marker))
        #expect(authorizer.requests.isEmpty)
        #expect(registry.calls.isEmpty)
        #expect(model.messages.last?.content == "legacy after cancel")
    }

    private func makeModel(registry: ScopedTurnRegistry) -> ChatViewModel {
        let defaults = UserDefaults(suiteName: "YouziScopedChatTurnTests.\(UUID().uuidString)")!
        return ChatViewModel(
            client: ChatStreamClient(
                baseURL: URL(string: "fake://youzi-scoped-turn")!,
                session: ScopedTurnProtocol.session()
            ),
            tools: registry,
            toolDefaults: defaults,
            persistsConversations: false
        )
    }

    private func toolNames(in body: Data) throws -> [String] {
        let json = try bodyJSON(body)
        let tools = json["tools"] as? [[String: Any]] ?? []
        return tools.compactMap { tool in
            (tool["function"] as? [String: Any])?["name"] as? String
        }
    }

    private func systemText(in body: Data) throws -> String {
        let messages = try #require(bodyJSON(body)["messages"] as? [[String: Any]])
        return messages.first(where: { $0["role"] as? String == "system" })?["content"]
            as? String ?? ""
    }

    private func toolMessages(in body: Data) throws -> [[String: Any]] {
        let messages = try #require(bodyJSON(body)["messages"] as? [[String: Any]])
        return messages.filter { $0["role"] as? String == "tool" }
    }

    private func bodyJSON(_ body: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition(), "Timed out waiting for the scoped turn checkpoint")
    }

    private func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }
}

@MainActor
private final class ScopedTurnRegistry: ToolRegistry {
    let definitions = [
        ToolDefinition(
            name: "alpha",
            description: "Alpha tool",
            parameters: .object([
                "type": .string("object"),
                "properties": .object(["value": .object(["type": .string("string")])]),
            ])
        ),
        ToolDefinition(
            name: "beta",
            description: "Beta tool",
            parameters: .object(["type": .string("object")])
        ),
    ]
    private(set) var calls: [ToolCall] = []
    var onRun: (@MainActor () -> Void)?

    func run(_ call: ToolCall) async -> ToolCallResult {
        calls.append(call)
        onRun?()
        return ToolCallResult(toolCallID: call.id, content: "Result for \(call.function.name)")
    }
}

@MainActor
private final class RecordingDispatchAuthorizer: YouziToolDispatchAuthorizing {
    private(set) var requests: [YouziToolDispatchAuthorizationRequest] = []
    var decision: YouziToolDispatchAuthorizationDecision

    init(decision: YouziToolDispatchAuthorizationDecision) {
        self.decision = decision
    }

    func authorize(
        _ request: YouziToolDispatchAuthorizationRequest
    ) async -> YouziToolDispatchAuthorizationDecision {
        requests.append(request)
        return decision
    }
}

private final class ScopedTurnProtocol: URLProtocol, @unchecked Sendable {
    enum Response {
        case terminal(String)
        case toolCall(name: String, id: String, arguments: String = "{}")
        case hanging
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [Response] = []
    nonisolated(unsafe) private static var bodies: [Data] = []
    nonisolated(unsafe) private static var stops = 0

    static var stopCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return stops
    }

    static func reset(_ newResponses: [Response]) {
        lock.lock()
        responses = newResponses
        bodies = []
        stops = 0
        lock.unlock()
    }

    static func enqueue(_ response: Response) {
        lock.lock()
        responses.append(response)
        lock.unlock()
    }

    static func capturedBodies() -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        return bodies
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScopedTurnProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.requestBody(from: request)
        Self.lock.lock()
        Self.bodies.append(body)
        let response = Self.responses.isEmpty ? .terminal("default") : Self.responses.removeFirst()
        Self.lock.unlock()

        guard case .hanging = response else {
            send(response)
            return
        }
        // Intentionally stay open until ChatViewModel cancellation reaches
        // URLSession and calls stopLoading().
    }

    override func stopLoading() {
        Self.lock.lock()
        Self.stops += 1
        Self.lock.unlock()
    }

    private func send(_ canned: Response) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        let event: String
        switch canned {
        case let .terminal(content):
            event = """
            data: {"choices":[{"delta":{"content":\(Self.jsonString(content))},"finish_reason":"stop"}]}

            data: [DONE]

            """
        case let .toolCall(name, id, arguments):
            event = """
            data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":\(Self.jsonString(id)),"type":"function","function":{"name":\(Self.jsonString(name)),"arguments":\(Self.jsonString(arguments))}}]},"finish_reason":"tool_calls"}]}

            data: [DONE]

            """
        case .hanging:
            return
        }
        client?.urlProtocol(self, didLoad: Data(event.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func jsonString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let array = String(data: data, encoding: .utf8)
        else { return "\"\"" }
        return String(array.dropFirst().dropLast())
    }

    private static func requestBody(from request: URLRequest) -> Data {
        guard let input = request.httpBodyStream else { return request.httpBody ?? Data() }
        input.open()
        defer { input.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while input.hasBytesAvailable {
            let count = input.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
