import Foundation

enum YouziConnectorCredentialVaultError: Error, Equatable, Sendable {
    case emptySecret
    case invalidReference
    case writeFailed
    case deleteFailed
}

extension YouziConnectorCredentialVaultError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .emptySecret:
            return "The credential is empty."
        case .invalidReference:
            return "The saved credential reference does not belong to this connection."
        case .writeFailed:
            return "The credential could not be saved securely."
        case .deleteFailed:
            return "The credential could not be removed from secure storage."
        }
    }
}

/// Narrow vault boundary for connected applications. Domain records persist
/// only the deterministic reference returned here; the secret remains inside
/// the existing code-identity-scoped macOS Keychain store.
protocol YouziConnectorCredentialVault: Sendable {
    func store(_ secret: String, for accountID: UUID) throws -> String
    func read(reference: String, for accountID: UUID) -> KeychainReadResult
    func delete(reference: String, for accountID: UUID) throws
}

struct YouziKeychainConnectorCredentialVault: YouziConnectorCredentialVault {
    static let referencePrefix = "youzi.connector."

    private let keychain: any KeychainStoring

    init(keychain: any KeychainStoring = SystemKeychain()) {
        self.keychain = keychain
    }

    func store(_ secret: String, for accountID: UUID) throws -> String {
        guard !secret.isEmpty else {
            throw YouziConnectorCredentialVaultError.emptySecret
        }
        let reference = Self.reference(for: accountID)
        guard keychain.write(account: reference, secret: secret) else {
            throw YouziConnectorCredentialVaultError.writeFailed
        }
        return reference
    }

    func read(reference: String, for accountID: UUID) -> KeychainReadResult {
        guard reference == Self.reference(for: accountID) else { return .unavailable }
        switch keychain.readWithoutUserInteraction(account: reference) {
        case .found(let secret) where secret.isEmpty:
            // SystemKeychain can use an empty recovery tombstone to mask an
            // undeletable legacy item. It is never an executable credential.
            return .missing
        case let result:
            return result
        }
    }

    func delete(reference: String, for accountID: UUID) throws {
        guard reference == Self.reference(for: accountID) else {
            throw YouziConnectorCredentialVaultError.invalidReference
        }
        guard keychain.delete(account: reference) else {
            throw YouziConnectorCredentialVaultError.deleteFailed
        }
    }

    static func reference(for accountID: UUID) -> String {
        referencePrefix + accountID.uuidString.lowercased()
    }

    static func accountID(from reference: String) -> UUID? {
        guard reference.hasPrefix(referencePrefix) else { return nil }
        let suffix = String(reference.dropFirst(referencePrefix.count))
        guard suffix == suffix.lowercased(),
              let id = UUID(uuidString: suffix),
              reference == Self.reference(for: id)
        else { return nil }
        return id
    }
}
