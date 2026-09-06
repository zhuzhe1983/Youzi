import Foundation
import Testing
@testable import Rapid

private final class AuthWireProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var paused = false
    nonisolated(unsafe) static var pending: [AuthWireProtocol] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        if Self.paused {
            Self.pending.append(self)
            Self.lock.unlock()
            return
        }
        Self.lock.unlock()
        respond()
    }
    private func respond() {
        Self.lock.lock()
        let status = Self.status
        Self.lock.unlock()
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 1024)
            var data = Data()
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                data.append(contentsOf: bytes.prefix(count))
            }
            body = data
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body ?? Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static func reset(status: Int = 200, paused: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        self.status = status; self.paused = paused; requests = []; pending = []
    }
    static func resume() {
        lock.lock()
        let responses = pending; pending = []; paused = false
        lock.unlock()
        for response in responses { response.respond() }
    }
    static func captured() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
}

@MainActor @Suite(.serialized)
struct ModelServiceAuthTests {
    private func fixture(state: ServerState = .ready(alias: "test")) throws -> (ServerManager, UserDefaults, String, ModelServiceAuthClient) {
        let name = "test.youzi.auth." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AuthWireProtocol.self]
        let server = ServerManager(testingState: state, activeBearer: state == .stopped ? nil : "test-only-key", sessionDefaults: defaults)
        return (server, defaults, name, ModelServiceAuthClient(session: URLSession(configuration: config)))
    }

    @Test func savesWithoutChangingModelPortOrKey() async throws {
        AuthWireProtocol.reset()
        let (server, defaults, name, client) = try fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        let originalPort = server.activePort
        for enabled in [true, false, true] {
            defaults.set(enabled, forKey: ModelServicePreference.anonymousInferenceKey)
            try await server.applySavedAuthentication(client: client)
            #expect(server.activeAnonymousInferenceAllowed == enabled)
            #expect(server.state == .ready(alias: "test"))
            #expect(server.activeBearer == "test-only-key")
            #expect(server.activePort == originalPort)
        }
        let requests = AuthWireProtocol.captured()
        #expect(requests.count == 3)
        #expect(requests.allSatisfy { $0.httpMethod == "PUT" && $0.url?.path == "/v1/service/auth" })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer test-only-key" })
    }

    @Test func failureDoesNotPublishFalseSuccess() async throws {
        AuthWireProtocol.reset(status: 404)
        let (server, defaults, name, client) = try fixture()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: ModelServicePreference.anonymousInferenceKey)
        await #expect(throws: (any Error).self) { try await server.applySavedAuthentication(client: client) }
        #expect(!server.activeAnonymousInferenceAllowed)
        #expect(defaults.bool(forKey: ModelServicePreference.anonymousInferenceKey))
    }

    @Test func preferenceChangedDuringSaveRequiresRetry() async throws {
        AuthWireProtocol.reset(paused: true)
        let (server, defaults, name, client) = try fixture()
        defer { AuthWireProtocol.resume(); defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: ModelServicePreference.anonymousInferenceKey)
        let save = Task { try await server.applySavedAuthentication(client: client) }
        for _ in 0..<100 {
            if !AuthWireProtocol.captured().isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(AuthWireProtocol.captured().count == 1)
        // A second Save cannot race the first PUT.
        await #expect(throws: (any Error).self) { try await server.applySavedAuthentication(client: client) }
        defaults.set(false, forKey: ModelServicePreference.anonymousInferenceKey)
        AuthWireProtocol.resume()
        await #expect(throws: ModelServiceAuthClient.Failure.staleSession) { try await save.value }
        // Publish the actual acknowledged backend policy, not the new unsaved preference.
        #expect(server.activeAnonymousInferenceAllowed)
        #expect(!defaults.bool(forKey: ModelServicePreference.anonymousInferenceKey))
        try await server.applySavedAuthentication(client: client)
        #expect(!server.activeAnonymousInferenceAllowed)
        #expect(server.state == .ready(alias: "test"))
    }

    @Test func stoppedSaveDoesNotStartService() async throws {
        AuthWireProtocol.reset()
        let (server, defaults, name, client) = try fixture(state: .stopped)
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(true, forKey: ModelServicePreference.anonymousInferenceKey)
        try await server.applySavedAuthentication(client: client)
        #expect(server.state == .stopped)
        #expect(AuthWireProtocol.captured().isEmpty)
    }

    @Test func startingRequiresRetry() async throws {
        AuthWireProtocol.reset()
        let (server, defaults, name, client) = try fixture(state: .starting(alias: "test"))
        defer { defaults.removePersistentDomain(forName: name) }
        await #expect(throws: (any Error).self) { try await server.applySavedAuthentication(client: client) }
        #expect(AuthWireProtocol.captured().isEmpty)
    }
}
