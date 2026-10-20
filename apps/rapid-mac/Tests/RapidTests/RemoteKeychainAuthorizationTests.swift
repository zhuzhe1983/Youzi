import Foundation
import Security
import Testing
@testable import Rapid

private final class AuthorizationItems: KeychainItemAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: String] = [:]
    private var accounts: [String] = []
    var requested: [String] { lock.withLock { accounts } }
    let authorize: @Sendable () async -> KeychainReadResult
    init(authorize: @escaping @Sendable () async -> KeychainReadResult = { .found("fixture-key") }) {
        self.authorize = authorize
    }
    func query(account: String, service: String) -> KeychainReadResult {
        lock.withLock { stored[account].map(KeychainReadResult.found) ?? .unavailable }
    }
    func queryAuthorizing(account: String, service: String) async -> KeychainReadResult {
        lock.withLock { accounts.append(account) }
        return await authorize()
    }
    func upsert(account: String, service: String, secret: String) -> Bool {
        lock.withLock { stored[account] = secret }; return true
    }
    func remove(account: String, service: String) -> Bool {
        lock.withLock { _ = stored.removeValue(forKey: account) }; return true
    }
}

private actor AuthorizationLatch {
    private var continuation: CheckedContinuation<KeychainReadResult, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    func read() async -> KeychainReadResult {
        await withCheckedContinuation {
            continuation = $0
            waiter?.resume(); waiter = nil
        }
    }
    func waitUntilReading() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func finish() { continuation?.resume(returning: .found("fixture-key")); continuation = nil }
}

private final class GateSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var changes: [Bool] = []
    var failRestore = false
    var values: [Bool] { lock.withLock { changes } }
    func set(_ allowed: Bool) -> OSStatus {
        lock.withLock { changes.append(allowed); return !allowed && failRestore ? errSecNotAvailable : errSecSuccess }
    }
}

@Suite("Remote Keychain authorization")
struct RemoteKeychainAuthorizationTests {
    @Test func backgroundCallsFailFastDuringAuthorizationAndRestoreSilence() {
        let mode = GateSwitch()
        let gate = KeychainInteractionGate(setInteraction: mode.set)
        let result = gate.perform(interactive: true, unavailable: false) {
            #expect(!gate.perform(unavailable: false) { Issue.record("Background operation ran during authorization"); return true })
            #expect(!gate.perform(interactive: true, unavailable: false) { Issue.record("Concurrent authorization ran"); return true })
            return true
        }
        #expect(result)
        #expect(mode.values == [true, false])
        #expect(gate.perform(unavailable: false) { true })
        #expect(mode.values == [true, false, false, false])
    }

    @Test func failedAuthorizationStillRestoresSilenceAndFailedRestoreQuarantinesAccess() {
        let mode = GateSwitch()
        let gate = KeychainInteractionGate(setInteraction: mode.set)
        #expect(!gate.perform(interactive: true, unavailable: false) { false })
        #expect(mode.values == [true, false])
        mode.failRestore = true
        #expect(!gate.perform(interactive: true, unavailable: false) { true })
        #expect(!gate.perform(unavailable: false) { Issue.record("Ran after failed restoration"); return true })
        #expect(mode.values == [true, false, true, false])
    }

    @Test func explicitReadAuthorizesOnceAndReplacementInvalidatesSessionValue() async throws {
        let items = AuthorizationItems()
        let secrets = RemoteModelKeychain(items: items, authorizedKeys: RemoteModelAuthorizedKeys())
        let id = UUID()
        #expect(throws: (any Error).self) { try secrets.read(id) }
        #expect(items.requested.isEmpty)
        #expect(try await secrets.readAuthorizing(id) == "fixture-key")
        #expect(try secrets.read(id) == "fixture-key")
        #expect(items.requested == [id.uuidString])
        try secrets.write("replacement", for: id)
        #expect(try secrets.read(id) == "replacement")
        try secrets.write(nil, for: id)
        #expect(throws: (any Error).self) { try secrets.read(id) }
    }

    @Test func deniedAuthorizationNeverBecomesAnAnonymousCredential() async {
        let secrets = RemoteModelKeychain(items: AuthorizationItems { .unavailable }, authorizedKeys: RemoteModelAuthorizedKeys())
        let id = UUID()
        await #expect(throws: (any Error).self) { try await secrets.readAuthorizing(id) }
        #expect(throws: (any Error).self) { try secrets.read(id) }
    }

    @Test func cancelledAuthorizationDoesNotCacheItsLateResult() async {
        let latch = AuthorizationLatch()
        let secrets = RemoteModelKeychain(items: AuthorizationItems { await latch.read() }, authorizedKeys: RemoteModelAuthorizedKeys())
        let id = UUID()
        let job = Task { try await secrets.readAuthorizing(id) }
        await latch.waitUntilReading()
        job.cancel()
        await latch.finish()
        await #expect(throws: CancellationError.self) { try await job.value }
        #expect(throws: (any Error).self) { try secrets.read(id) }
    }

    @Test func replacementWinsOverLateAuthorization() async throws {
        let latch = AuthorizationLatch()
        let secrets = RemoteModelKeychain(items: AuthorizationItems { await latch.read() }, authorizedKeys: RemoteModelAuthorizedKeys())
        let id = UUID()
        let job = Task { try await secrets.readAuthorizing(id) }
        await latch.waitUntilReading()
        try secrets.write("replacement", for: id)
        await latch.finish()
        await #expect(throws: CancellationError.self) { try await job.value }
        #expect(try secrets.read(id) == "replacement")
    }

    @Test @MainActor func reusedServerCanDiscoverAndSaveAfterAuthorization() async throws {
        let suite = "RemoteAuthorization." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let items = AuthorizationItems()
        let secrets = RemoteModelKeychain(items: items, authorizedKeys: RemoteModelAuthorizedKeys())
        let repository = RemoteModelRepository(defaults: defaults, secrets: secrets)
        let source = RemoteModelConfiguration(modelID: "chat", baseURL: "https://provider.example/v1")
        try repository.save(RemoteModelDocument(models: [source]))
        let settings = RemoteModelSettings(repository: repository)
        let draft = RemoteModelConfiguration(modelID: "image", baseURL: source.baseURL, slot: .image)
        #expect(throws: (any Error).self) { try settings.discoveryEndpoint(draft, key: nil, inheritingFrom: source.id) }
        #expect(items.requested.isEmpty)
        let endpoint = try await settings.authorizedDiscoveryEndpoint(draft, key: nil, inheritingFrom: source.id)
        #expect(endpoint.apiKey == "fixture-key")
        try settings.save(draft, key: nil, inheritingFrom: source.id)
        #expect(try repository.endpoint(alias: draft.alias)?.apiKey == "fixture-key")
        #expect(items.requested == [source.id.uuidString])
        #expect(!String(decoding: defaults.data(forKey: RemoteModelRepository.key)!, as: UTF8.self).contains("fixture-key"))
    }

    @Test @MainActor func changedSourceIsRejectedBeforeAuthorizationAndAfterSuspension() async throws {
        let suite = "RemoteAuthorization." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let latch = AuthorizationLatch()
        let items = AuthorizationItems { await latch.read() }
        let repository = RemoteModelRepository(defaults: defaults, secrets: RemoteModelKeychain(items: items, authorizedKeys: RemoteModelAuthorizedKeys()))
        let source = RemoteModelConfiguration(modelID: "chat", baseURL: "https://provider.example/v1")
        try repository.save(RemoteModelDocument(models: [source]))
        let settings = RemoteModelSettings(repository: repository)
        var draft = RemoteModelConfiguration(baseURL: "https://other.example/v1")
        await #expect(throws: (any Error).self) { try await settings.authorizedDiscoveryEndpoint(draft, key: nil, inheritingFrom: source.id) }
        #expect(items.requested.isEmpty)
        draft.baseURL = source.baseURL
        let job = Task { [draft] in try await settings.authorizedDiscoveryEndpoint(draft, key: nil, inheritingFrom: source.id) }
        await latch.waitUntilReading()
        try settings.update { $0.models.removeAll() }
        await latch.finish()
        await #expect(throws: (any Error).self) { try await job.value }
    }
}
