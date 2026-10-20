import Foundation
import LocalAuthentication
import Security

/// Minimal Keychain wrapper for storing per-provider API keys.
///
/// We deliberately model the surface as a protocol so the test
/// suite can swap in an in-memory implementation rather than
/// touching the real system Keychain (which would prompt on
/// access, leak across test runs, and require manual cleanup).
protocol KeychainStoring: Sendable {
    func read(account: String) -> String?
    func readWithoutUserInteraction(account: String) -> KeychainReadResult
    @discardableResult func write(account: String, secret: String) -> Bool
    @discardableResult func delete(account: String) -> Bool
}

enum KeychainReadResult: Equatable, Sendable {
    case found(String)
    case missing
    case unavailable
}

extension KeychainStoring {
    /// Test doubles and non-system stores do not have an authentication UI.
    /// The real Keychain implementation overrides this with a query that
    /// explicitly forbids macOS from presenting one.
    func readWithoutUserInteraction(account: String) -> KeychainReadResult {
        if let value = read(account: account) { return .found(value) }
        return .missing
    }
}

protocol KeychainItemAccessing: Sendable {
    func query(account: String, service: String) -> KeychainReadResult
    func queryAuthorizing(account: String, service: String) async -> KeychainReadResult
    func upsert(account: String, service: String, secret: String) -> Bool
    func remove(account: String, service: String) -> Bool
}

extension KeychainItemAccessing {
    // In-memory stores and test doubles have no system authorization UI.
    func queryAuthorizing(account: String, service: String) async -> KeychainReadResult {
        query(account: account, service: service)
    }
}

/// The legacy login-keychain interaction flag is process-wide. All app-owned
/// SecItem calls must pass this gate. Background callers fail fast while a
/// user-requested authorization is pending; none wait for a system dialog.
final class KeychainInteractionGate: @unchecked Sendable {
    static let shared = KeychainInteractionGate { SecKeychainSetUserInteractionAllowed($0) }
    private let lock = NSLock()
    private let setInteraction: @Sendable (Bool) -> OSStatus
    private var disabled = false

    init(setInteraction: @escaping @Sendable (Bool) -> OSStatus) {
        self.setInteraction = setInteraction
    }

    func perform<T>(interactive: Bool = false, unavailable: T, _ operation: () -> T) -> T {
        guard lock.try() else { return unavailable }
        defer { lock.unlock() }
        guard !disabled else { return unavailable }
        guard setInteraction(interactive) == errSecSuccess else {
            disabled = setInteraction(false) != errSecSuccess
            return unavailable
        }
        let result = operation()
        // Never leave prompts enabled, even after denial/cancellation. If the
        // OS refuses to restore the gate, stop issuing further SecItem calls.
        guard setInteraction(false) == errSecSuccess else {
            disabled = true
            return unavailable
        }
        return result
    }
}

/// Background operations never present authentication UI. The one explicit
/// authorization method runs off the main actor and takes the same global gate.
struct SecurityKeychainItems: KeychainItemAccessing {
    func query(account: String, service: String) -> KeychainReadResult {
        KeychainInteractionGate.shared.perform(unavailable: .unavailable) {
            Self.query(account: account, service: service, interactive: false)
        }
    }

    func queryAuthorizing(account: String, service: String) async -> KeychainReadResult {
        guard !Task.isCancelled else { return .unavailable }
        let job = Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled else { return KeychainReadResult.unavailable }
            return KeychainInteractionGate.shared.perform(interactive: true, unavailable: .unavailable) {
                Self.query(account: account, service: service, interactive: true)
            }
        }
        return await withTaskCancellationHandler {
            let result = await job.value
            return Task.isCancelled ? .unavailable : result
        } onCancel: {
            // Legacy SecurityAgent dialogs cannot reliably be interrupted by
            // LAContext.invalidate(). Discard cancelled results; the user can
            // dismiss the system dialog while the app remains responsive.
            job.cancel()
        }
    }

    private static func query(account: String, service: String, interactive: Bool,
                              context: LAContext = LAContext()) -> KeychainReadResult {
        context.interactionNotAllowed = !interactive
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return Self.readResult(status: status, data: item as? Data)
    }

    static func readResult(status: OSStatus, data: Data?) -> KeychainReadResult {
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess,
              let data,
              let value = String(data: data, encoding: .utf8) else {
            return .unavailable
        }
        return .found(value)
    }

    func upsert(account: String, service: String, secret: String) -> Bool {
        KeychainInteractionGate.shared.perform(unavailable: false) {
            upsertWithoutInteraction(account: account, service: service, secret: secret)
        }
    }

    private func upsertWithoutInteraction(account: String, service: String, secret: String) -> Bool {
        guard let data = secret.data(using: .utf8) else { return false }
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let updateAttrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        var updateQuery = baseQuery
        // `Skip` is a match-only option. For update, Security.framework's
        // current contract is an LAContext that forbids interaction; this is
        // the non-deprecated equivalent of kSecUseAuthenticationUIFail.
        let authenticationContext = LAContext()
        authenticationContext.interactionNotAllowed = true
        updateQuery[kSecUseAuthenticationContext as String] = authenticationContext
        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        if updateStatus != errSecItemNotFound { return false }

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    func remove(account: String, service: String) -> Bool {
        KeychainInteractionGate.shared.perform(unavailable: false) {
            removeWithoutInteraction(account: account, service: service)
        }
    }

    private func removeWithoutInteraction(account: String, service: String) -> Bool {
        let authenticationContext = LAContext()
        authenticationContext.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseAuthenticationContext as String: authenticationContext,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// Real-system implementation. Each entry is a ``kSecClassGenericPassword``
/// keyed by a code-identity-scoped service + provider account. We use the
/// generic-password class (not internet-password) because provider keys are
/// static credentials, not per-URL secrets.
///
/// Codex audit batch 6 finding (KeychainStore.swift:63, P2):
/// access policy is ``kSecAttrAccessibleWhenUnlockedThisDeviceOnly``.
/// The pre-audit shape used ``kSecAttrAccessibleAfterFirstUnlock``,
/// which (a) makes the key readable while the machine is locked
/// after the user's first post-boot login (any background process
/// running under the user account can read it) and (b) allows the
/// secret to be migrated off-device via Keychain sync / Time
/// Machine restore. ``WhenUnlockedThisDeviceOnly`` keeps the secret
/// readable only while the screen is unlocked and only on the
/// originating Mac.
struct SystemKeychain: KeychainStoring {
    /// The original unscoped service is read-only migration input. Local
    /// ad-hoc builds used the same service as notarized releases, so an item
    /// they created could carry an ACL that did not trust the release binary.
    private static let legacyService = "com.rapidmlx.rapid.api-keys"

    private static let signingIdentity = currentSigningIdentity()
    static let service = serviceNamespace(
        teamIdentifier: signingIdentity.teamIdentifier,
        isDeveloperIDApplication: signingIdentity.isDeveloperIDApplication
    )

    private let items: any KeychainItemAccessing
    private let primaryService: String
    private let legacyMigrationService: String?
    private var recoveryService: String { "\(primaryService).recovery" }

    init() {
        items = SecurityKeychainItems()
        primaryService = Self.service
        // Apple Development and ad-hoc builds must never inspect production's
        // historical namespace, even when they carry the same Team ID.
        legacyMigrationService = Self.signingIdentity.isDeveloperIDApplication
            ? Self.legacyService
            : nil
    }

    init(
        items: any KeychainItemAccessing,
        primaryService: String,
        legacyMigrationService: String? = nil
    ) {
        self.items = items
        self.primaryService = primaryService
        self.legacyMigrationService = legacyMigrationService
    }

    func read(account: String) -> String? {
        guard case .found(let value) = readWithoutUserInteraction(account: account) else {
            return nil
        }
        return value.isEmpty ? nil : value
    }

    func readWithoutUserInteraction(account: String) -> KeychainReadResult {
        let recovery = items.query(account: account, service: recoveryService)
        if recovery != .missing { return recovery }

        let current = items.query(account: account, service: primaryService)
        if current != .missing { return current }

        guard let legacyMigrationService else { return .missing }
        return items.query(account: account, service: legacyMigrationService)
    }

    static func serviceNamespace(
        teamIdentifier: String?,
        isDeveloperIDApplication: Bool
    ) -> String {
        guard isDeveloperIDApplication,
              let teamIdentifier,
              !teamIdentifier.isEmpty else {
            return "\(legacyService).development"
        }
        return "\(legacyService).release.\(teamIdentifier)"
    }

    @discardableResult
    func write(account: String, secret: String) -> Bool {
        // Once a replacement slot exists it remains authoritative. Otherwise
        // try the normal release-identity slot, then create the replacement
        // slot if that update is denied by a stale/mismatched ACL.
        switch items.query(account: account, service: recoveryService) {
        case .found:
            return items.upsert(account: account, service: recoveryService, secret: secret)
        case .unavailable:
            return false
        case .missing:
            if items.upsert(account: account, service: primaryService, secret: secret) {
                return true
            }
            return items.upsert(account: account, service: recoveryService, secret: secret)
        }
    }

    @discardableResult
    func delete(account: String) -> Bool {
        let services = [recoveryService, primaryService, legacyMigrationService].compactMap { $0 }
        let removedEverywhere = services
            .map { items.remove(account: account, service: $0) }
            .allSatisfy { $0 }
        if removedEverywhere { return true }

        // A mismatched ACL can make an old item impossible to remove without a
        // system prompt. Mask it for this app with a non-secret tombstone, but
        // report failure so Settings never claims the stored secret was erased.
        _ = write(account: account, secret: "")
        return false
    }

    private struct SigningIdentity {
        let teamIdentifier: String?
        let isDeveloperIDApplication: Bool
    }

    private static func currentSigningIdentity() -> SigningIdentity {
        guard let executableURL = Bundle.main.executableURL else {
            return SigningIdentity(teamIdentifier: nil, isDeveloperIDApplication: false)
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(executableURL as CFURL, [], &code) == errSecSuccess,
              let code else {
            return SigningIdentity(teamIdentifier: nil, isDeveloperIDApplication: false)
        }
        var signingInfo: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &signingInfo) == errSecSuccess,
              let info = signingInfo as? [String: Any] else {
            return SigningIdentity(teamIdentifier: nil, isDeveloperIDApplication: false)
        }
        let team = info[kSecCodeInfoTeamIdentifier as String] as? String
        return SigningIdentity(
            teamIdentifier: team,
            isDeveloperIDApplication: isDeveloperIDApplication(code)
        )
    }

    private static let developerIDApplicationRequirement =
        "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"

    private static func developerIDApplicationCodeRequirement() -> SecRequirement? {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            developerIDApplicationRequirement as CFString,
            [],
            &requirement
        ) == errSecSuccess else {
            return nil
        }
        return requirement
    }

    private static func isDeveloperIDApplication(_ code: SecStaticCode) -> Bool {
        guard let requirement = developerIDApplicationCodeRequirement() else { return false }
        return SecStaticCodeCheckValidity(
            code,
            developerIDApplicationValidationFlags,
            requirement
        ) == errSecSuccess
    }

    /// The namespace decision only needs to establish that the signing
    /// certificate satisfies the Developer ID Application requirement. Do not
    /// revalidate the executable or every sealed app resource here: this runs
    /// while the app constructs its settings model, before the first window.
    static let developerIDApplicationValidationFlags = SecCSFlags(
        rawValue: kSecCSDoNotValidateResources | kSecCSDoNotValidateExecutable
    )

    static func developerIDApplicationRequirementCompiles() -> Bool {
        developerIDApplicationCodeRequirement() != nil
    }
}

/// In-memory backing for tests. Same surface as ``SystemKeychain``
/// but everything lives in a dictionary that dies with the
/// instance — no system-Keychain side effects, no popups, no
/// cross-test pollution. Thread-safe via a serial DispatchQueue
/// because the tool dispatcher may call into it from background
/// actor hops.
final class InMemoryKeychain: KeychainStoring, @unchecked Sendable {
    private var storage: [String: String] = [:]
    private let queue = DispatchQueue(label: "rapid.in-memory-keychain")

    func read(account: String) -> String? {
        queue.sync { storage[account] }
    }

    @discardableResult
    func write(account: String, secret: String) -> Bool {
        queue.sync { storage[account] = secret }
        return true
    }

    @discardableResult
    func delete(account: String) -> Bool {
        queue.sync { _ = storage.removeValue(forKey: account) }
        return true
    }
}
