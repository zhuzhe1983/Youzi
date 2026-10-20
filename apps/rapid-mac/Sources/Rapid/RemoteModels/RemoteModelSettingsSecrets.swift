import Foundation

/// Remote model API keys belong to Youzi's own settings. The Keychain adapter
/// is read only, and used once per legacy model for silent migration.
struct RemoteModelSettingsSecrets: RemoteModelSecrets, @unchecked Sendable {
    private struct Record: Codable {
        var apiKey: String?
        var needsEntry: Bool
    }

    private static let lock = NSLock()
    static let legacyService = "com.youzi.remote-models.api-key.v1"
    static func storageKey(_ id: UUID) -> String {
        "youzi.models.remote.apiKey.v1." + id.uuidString.lowercased()
    }
    var defaults: UserDefaults = .standard
    var legacyItems: any KeychainItemAccessing = SecurityKeychainItems()

    func read(_ id: UUID) throws -> String? {
        try Self.lock.withLock {
            guard let object = defaults.object(forKey: Self.storageKey(id)) else { return nil }
            guard let data = object as? Data,
                  let record = try? JSONDecoder().decode(Record.self, from: data),
                  !record.needsEntry || record.apiKey == nil else {
                throw RemoteModelError.corruptSettings
            }
            guard !record.needsEntry else { throw RemoteModelError.credentialMigrationRequired }
            return record.apiKey?.isEmpty == false ? record.apiKey : nil
        }
    }

    func write(_ value: String?, for id: UUID) throws {
        try Self.lock.withLock {
            // An explicit empty record prevents a cleared/deleted key from
            // being resurrected by a later migration or metadata restore.
            try save(Record(apiKey: value?.isEmpty == false ? value : nil, needsEntry: false), for: id)
        }
    }

    func migrateLegacy(_ ids: [UUID]) throws {
        try Self.lock.withLock {
            for id in ids where defaults.object(forKey: Self.storageKey(id)) == nil {
                let record: Record
                switch legacyItems.query(account: id.uuidString, service: Self.legacyService) {
                case .found(let value): record = Record(apiKey: value, needsEntry: false)
                case .missing: record = Record(apiKey: nil, needsEntry: false)
                case .unavailable: record = Record(apiKey: nil, needsEntry: true)
                }
                // Unavailable is persisted too: future launches/requests use
                // settings only and require re-entry rather than prompting.
                try save(record, for: id)
            }
        }
    }

    private func save(_ record: Record, for id: UUID) throws {
        defaults.set(try JSONEncoder().encode(record), forKey: Self.storageKey(id))
    }
}
