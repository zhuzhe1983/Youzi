import Foundation
import Testing
@testable import Rapid

private final class LegacyRemoteKeys: KeychainItemAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private var queries: [String] = []
    private var mutations = 0
    let result: KeychainReadResult
    init(_ result: KeychainReadResult = .unavailable) { self.result = result }
    var queryCount: Int { lock.withLock { queries.count } }
    var mutationCount: Int { lock.withLock { mutations } }
    func query(account: String, service: String) -> KeychainReadResult {
        #expect(service == RemoteModelSettingsSecrets.legacyService)
        lock.withLock { queries.append(account) }
        return result
    }
    func upsert(account: String, service: String, secret: String) -> Bool {
        lock.withLock { mutations += 1 }; return false
    }
    func remove(account: String, service: String) -> Bool {
        lock.withLock { mutations += 1 }; return false
    }
}

@Suite("Remote model keys in Youzi settings")
@MainActor
struct RemoteModelSettingsSecretsTests {
    private func fixture() -> (UserDefaults, String) {
        let suite = "RemoteSettingsKeys." + UUID().uuidString
        return (UserDefaults(suiteName: suite)!, suite)
    }

    @Test func saveAndReloadAllWorkflowsWithoutKeychainAccess() throws {
        let (defaults, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = LegacyRemoteKeys()
        let secrets = RemoteModelSettingsSecrets(defaults: defaults, legacyItems: legacy)
        let repository = RemoteModelRepository(defaults: defaults, secrets: secrets)
        let settings = RemoteModelSettings(repository: repository)
        for slot in RemoteModelSlot.allCases {
            let model = RemoteModelConfiguration(modelID: "fixture-\(slot.rawValue)", baseURL: "https://provider.example/v1", slot: slot)
            try settings.save(model, key: "fixture-settings-key")
        }
        // A fresh repository must bind its default credential store to the
        // supplied preferences domain, including on application restart.
        let reopened = RemoteModelRepository(defaults: UserDefaults(suiteName: suite)!)
        for model in try reopened.load().models {
            #expect(try reopened.endpoint(alias: model.alias)?.apiKey == "fixture-settings-key")
        }
        let metadata = try #require(defaults.data(forKey: RemoteModelRepository.key))
        #expect(!String(decoding: metadata, as: UTF8.self).contains("fixture-settings-key"))
        #expect(legacy.queryCount == 0)
        #expect(legacy.mutationCount == 0)
    }

    @Test func newKeylessModelsNeverEnterLegacyMigration() throws {
        let (defaults, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = LegacyRemoteKeys(.found("obsolete-fixture"))
        let repository = RemoteModelRepository(defaults: defaults, secrets: RemoteModelSettingsSecrets(defaults: defaults, legacyItems: legacy))
        let settings = RemoteModelSettings(repository: repository)
        let model = RemoteModelConfiguration(modelID: "keyless", baseURL: "https://provider.example/v1")
        try settings.save(model, key: nil)
        #expect(try repository.endpoint(alias: model.alias)?.apiKey == nil)
        #expect(legacy.queryCount == 0)
    }

    @Test func readableLegacyKeyMigratesOnceAndSurvivesRestart() throws {
        let (defaults, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = LegacyRemoteKeys(.found("legacy-fixture-key"))
        let repository = RemoteModelRepository(defaults: defaults, secrets: RemoteModelSettingsSecrets(defaults: defaults, legacyItems: legacy))
        let model = RemoteModelConfiguration(modelID: "old", baseURL: "https://provider.example/v1")
        try repository.save(RemoteModelDocument(models: [model]))
        #expect(try repository.endpoint(alias: model.alias)?.apiKey == "legacy-fixture-key")
        #expect(try repository.endpoint(alias: model.alias)?.apiKey == "legacy-fixture-key")
        #expect(legacy.queryCount == 1)
        let blocked = LegacyRemoteKeys()
        let reopened = RemoteModelRepository(defaults: defaults, secrets: RemoteModelSettingsSecrets(defaults: defaults, legacyItems: blocked))
        #expect(try reopened.endpoint(alias: model.alias)?.apiKey == "legacy-fixture-key")
        #expect(blocked.queryCount == 0)
        #expect(legacy.mutationCount == 0)
    }

    @Test func unavailableLegacyKeyRequiresEntryInsteadOfAnonymousRequestOrAnotherPrompt() throws {
        let (defaults, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = LegacyRemoteKeys()
        let repository = RemoteModelRepository(defaults: defaults, secrets: RemoteModelSettingsSecrets(defaults: defaults, legacyItems: legacy))
        let model = RemoteModelConfiguration(modelID: "old", baseURL: "https://provider.example/v1")
        try repository.save(RemoteModelDocument(models: [model]))
        let settings = RemoteModelSettings(repository: repository)
        #expect(settings.loadError == nil)
        #expect(settings.document.models == [model])
        #expect(throws: (any Error).self) { try repository.endpoint(alias: model.alias) }
        #expect(throws: (any Error).self) { try settings.discoveryEndpoint(model, key: nil) }
        let reopened = RemoteModelSettings(repository: repository)
        #expect(throws: (any Error).self) { try reopened.repository.endpoint(alias: model.alias) }
        #expect(legacy.queryCount == 1)
        try reopened.save(model, key: "replacement-fixture")
        #expect(try repository.endpoint(alias: model.alias)?.apiKey == "replacement-fixture")
        #expect(legacy.queryCount == 1)
        #expect(legacy.mutationCount == 0)
    }

    @Test func missingLegacyCredentialPreservesIntentionalKeylessEndpoint() throws {
        let (defaults, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = LegacyRemoteKeys(.missing)
        let repository = RemoteModelRepository(defaults: defaults, secrets: RemoteModelSettingsSecrets(defaults: defaults, legacyItems: legacy))
        let model = RemoteModelConfiguration(modelID: "old-keyless", baseURL: "https://provider.example/v1")
        try repository.save(RemoteModelDocument(models: [model]))
        #expect(try repository.endpoint(alias: model.alias)?.apiKey == nil)
        #expect(try repository.endpoint(alias: model.alias)?.apiKey == nil)
        #expect(legacy.queryCount == 1)
    }

    @Test func serverReuseCopiesSettingsKeyAndRejectsChangedDestination() throws {
        let (defaults, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = LegacyRemoteKeys()
        let repository = RemoteModelRepository(defaults: defaults, secrets: RemoteModelSettingsSecrets(defaults: defaults, legacyItems: legacy))
        let settings = RemoteModelSettings(repository: repository)
        let source = RemoteModelConfiguration(modelID: "chat", baseURL: "https://provider.example/v1")
        try settings.save(source, key: "source-fixture")
        var target = RemoteModelConfiguration(modelID: "image", baseURL: source.baseURL, slot: .image)
        #expect(try settings.discoveryEndpoint(target, key: nil, inheritingFrom: source.id).apiKey == "source-fixture")
        target.baseURL = "https://other.example/v1"
        #expect(throws: (any Error).self) { try settings.save(target, key: nil, inheritingFrom: source.id) }
        target.baseURL = source.baseURL
        try settings.save(target, key: nil, inheritingFrom: source.id)
        try settings.remove(source.id)
        #expect(try repository.endpoint(alias: target.alias)?.apiKey == "source-fixture")
        #expect(try repository.secrets.read(source.id) == nil)
        #expect(legacy.queryCount == 0)
        #expect(legacy.mutationCount == 0)
    }

    @Test func clearAndDeleteCannotResurrectLegacyKeys() throws {
        let (defaults, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = LegacyRemoteKeys(.found("legacy-fixture"))
        let repository = RemoteModelRepository(defaults: defaults, secrets: RemoteModelSettingsSecrets(defaults: defaults, legacyItems: legacy))
        let model = RemoteModelConfiguration(modelID: "old", baseURL: "https://provider.example/v1")
        try repository.save(RemoteModelDocument(models: [model]))
        let settings = RemoteModelSettings(repository: repository)
        try settings.save(model, key: "")
        #expect(try repository.endpoint(alias: model.alias)?.apiKey == nil)
        try settings.remove(model.id)
        // Even restoring old model metadata does not restore a removed secret.
        try repository.save(RemoteModelDocument(models: [model]))
        #expect(try repository.endpoint(alias: model.alias)?.apiKey == nil)
        #expect(legacy.queryCount == 1)
        #expect(legacy.mutationCount == 0)
    }

    @Test func corruptCredentialIsPreservedUntilExplicitReplacement() throws {
        let (defaults, suite) = fixture()
        defer { defaults.removePersistentDomain(forName: suite) }
        let legacy = LegacyRemoteKeys(.found("obsolete-fixture"))
        let repository = RemoteModelRepository(defaults: defaults, secrets: RemoteModelSettingsSecrets(defaults: defaults, legacyItems: legacy))
        let model = RemoteModelConfiguration(modelID: "old", baseURL: "https://provider.example/v1")
        try repository.save(RemoteModelDocument(models: [model]))
        let corrupt = Data("not-json".utf8)
        defaults.set(corrupt, forKey: RemoteModelSettingsSecrets.storageKey(model.id))
        #expect(throws: (any Error).self) { try repository.endpoint(alias: model.alias) }
        #expect(defaults.data(forKey: RemoteModelSettingsSecrets.storageKey(model.id)) == corrupt)
        #expect(legacy.queryCount == 0)
        try RemoteModelSettings(repository: repository).save(model, key: "fixed-fixture")
        #expect(try repository.endpoint(alias: model.alias)?.apiKey == "fixed-fixture")
    }
}
