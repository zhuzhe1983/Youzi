import Foundation
import Testing
@testable import Rapid

@Suite("Youzi connectors — Keychain credential vault")
struct YouziConnectorCredentialVaultTests {
    private let accountID = UUID(uuidString: "00000000-0000-0000-0000-0000000000aa")!

    @Test("Secret is stored under a deterministic non-secret account reference")
    func storeAndRead() throws {
        let keychain = ConnectorVaultKeychainSpy()
        let vault = YouziKeychainConnectorCredentialVault(keychain: keychain)
        let sentinel = "test-secret-sentinel-\(UUID().uuidString)"

        let reference = try vault.store(sentinel, for: accountID)

        #expect(reference == "youzi.connector.00000000-0000-0000-0000-0000000000aa")
        #expect(reference == YouziKeychainConnectorCredentialVault.reference(for: accountID))
        #expect(!reference.contains(sentinel))
        #expect(keychain.lastWriteAccount == reference)
        #expect(keychain.lastWriteSecret == sentinel)
        #expect(vault.read(reference: reference, for: accountID) == .found(sentinel))
    }

    @Test("References round-trip only in canonical lowercase form")
    func canonicalReference() {
        let reference = YouziKeychainConnectorCredentialVault.reference(for: accountID)
        #expect(YouziKeychainConnectorCredentialVault.accountID(from: reference) == accountID)
        #expect(YouziKeychainConnectorCredentialVault.accountID(from: reference.uppercased()) == nil)
        #expect(YouziKeychainConnectorCredentialVault.accountID(from: "keychain:\(accountID)") == nil)
        #expect(YouziKeychainConnectorCredentialVault.accountID(from: "youzi.connector.not-a-uuid") == nil)
    }

    @Test("Cross-account reads fail closed without probing Keychain")
    func crossAccountRead() throws {
        let keychain = ConnectorVaultKeychainSpy()
        let vault = YouziKeychainConnectorCredentialVault(keychain: keychain)
        let reference = try vault.store("sentinel", for: accountID)
        keychain.readAccounts.removeAll()

        let otherID = UUID(uuidString: "00000000-0000-0000-0000-0000000000bb")!
        #expect(vault.read(reference: reference, for: otherID) == .unavailable)
        #expect(keychain.readAccounts.isEmpty)
    }

    @Test("Empty Keychain tombstones are never returned as credentials")
    func tombstoneIsMissing() {
        let keychain = ConnectorVaultKeychainSpy()
        let reference = YouziKeychainConnectorCredentialVault.reference(for: accountID)
        keychain.storage[reference] = ""
        let vault = YouziKeychainConnectorCredentialVault(keychain: keychain)
        #expect(vault.read(reference: reference, for: accountID) == .missing)
    }

    @Test("Empty writes and denied writes produce typed non-secret errors")
    func writeFailures() {
        let keychain = ConnectorVaultKeychainSpy()
        let vault = YouziKeychainConnectorCredentialVault(keychain: keychain)
        #expect(throws: YouziConnectorCredentialVaultError.emptySecret) {
            _ = try vault.store("", for: accountID)
        }
        keychain.writeSucceeds = false
        #expect(throws: YouziConnectorCredentialVaultError.writeFailed) {
            _ = try vault.store("not-in-the-error", for: accountID)
        }
        #expect(!YouziConnectorCredentialVaultError.writeFailed.localizedDescription
            .contains("not-in-the-error"))
    }

    @Test("Delete validates ownership and reports Keychain denial")
    func deleteFailures() throws {
        let keychain = ConnectorVaultKeychainSpy()
        let vault = YouziKeychainConnectorCredentialVault(keychain: keychain)
        let reference = try vault.store("sentinel", for: accountID)
        let otherID = UUID(uuidString: "00000000-0000-0000-0000-0000000000bb")!

        #expect(throws: YouziConnectorCredentialVaultError.invalidReference) {
            try vault.delete(reference: reference, for: otherID)
        }
        #expect(keychain.deleteAccounts.isEmpty)

        keychain.deleteSucceeds = false
        #expect(throws: YouziConnectorCredentialVaultError.deleteFailed) {
            try vault.delete(reference: reference, for: accountID)
        }
        #expect(keychain.deleteAccounts == [reference])
    }

    @Test("Successful delete removes the only stored copy")
    func delete() throws {
        let keychain = ConnectorVaultKeychainSpy()
        let vault = YouziKeychainConnectorCredentialVault(keychain: keychain)
        let reference = try vault.store("sentinel", for: accountID)
        try vault.delete(reference: reference, for: accountID)
        #expect(vault.read(reference: reference, for: accountID) == .missing)
    }
}

private final class ConnectorVaultKeychainSpy: KeychainStoring, @unchecked Sendable {
    var storage: [String: String] = [:]
    var writeSucceeds = true
    var deleteSucceeds = true
    var lastWriteAccount: String?
    var lastWriteSecret: String?
    var readAccounts: [String] = []
    var deleteAccounts: [String] = []

    func read(account: String) -> String? {
        readAccounts.append(account)
        return storage[account]
    }

    func readWithoutUserInteraction(account: String) -> KeychainReadResult {
        readAccounts.append(account)
        return storage[account].map(KeychainReadResult.found) ?? .missing
    }

    func write(account: String, secret: String) -> Bool {
        lastWriteAccount = account
        lastWriteSecret = secret
        guard writeSucceeds else { return false }
        storage[account] = secret
        return true
    }

    func delete(account: String) -> Bool {
        deleteAccounts.append(account)
        guard deleteSucceeds else { return false }
        storage.removeValue(forKey: account)
        return true
    }
}
