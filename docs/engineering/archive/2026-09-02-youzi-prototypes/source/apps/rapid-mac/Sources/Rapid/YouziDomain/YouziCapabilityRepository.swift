import Foundation

struct YouziCapabilitySeed: Equatable, Sendable {
    var helpers: [YouziHelper]
    var skills: [YouziSkill]
    var skillPackages: [YouziSkillPackageRecord]
    var connectors: [YouziConnector]

    init(
        helpers: [YouziHelper] = [],
        skills: [YouziSkill] = [],
        skillPackages: [YouziSkillPackageRecord] = [],
        connectors: [YouziConnector] = []
    ) {
        self.helpers = helpers
        self.skills = skills
        self.skillPackages = skillPackages
        self.connectors = connectors
    }
}

enum YouziCapabilityRepositoryError: Error, Equatable, Sendable {
    case helperNotFound(UUID)
    case skillNotFound(UUID)
    case connectorNotFound(UUID)
    case accountNotFound(UUID)
    case accountAlreadyExists(UUID)
    case bindingNotFound(UUID)
    case bindingAlreadyExists(UUID)
    case accountConnectorMismatch(accountID: UUID, connectorID: UUID)
    case accountStillReferenced(UUID)
    case invalidRuntimeBinding(UUID)
    case bindingRevisionConflict(expected: Int?, actual: Int?)
    case invalidPackage(UUID)
    case credentialCleanupNotPending(UUID)
    case credentialCleanupPending(UUID)
}

final class YouziCapabilityRepository: @unchecked Sendable {
    private let store: YouziDomainStore

    init(store: YouziDomainStore = YouziDomainStore()) {
        self.store = store
    }

    @discardableResult
    func seedCatalog(_ seed: YouziCapabilitySeed, at date: Date) throws -> YouziDomainDocument {
        let skillIDs = seed.skills.map(\.id)
        let packageIDs = seed.skillPackages.map(\.id)
        guard Set(skillIDs).count == skillIDs.count,
              Set(packageIDs).count == packageIDs.count else {
            throw YouziCapabilityRepositoryError.invalidPackage(
                packageIDs.first ?? skillIDs.first ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
            )
        }
        let skillsByID = Dictionary(uniqueKeysWithValues: seed.skills.map { ($0.id, $0) })
        guard Set(skillsByID.keys) == Set(seed.skillPackages.map(\.id)),
              seed.skillPackages.allSatisfy({ package in
                  guard let skill = skillsByID[package.id] else { return false }
                  return skill.packageVersion == package.packageVersion
                      && package.contentSHA256.count == 64
                      && package.contentSHA256.allSatisfy { $0.isHexDigit && !$0.isUppercase }
              }) else {
            throw YouziCapabilityRepositoryError.invalidPackage(
                seed.skillPackages.first?.id ?? seed.skills.first?.id
                    ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
            )
        }
        return try store.update { document in
            for helper in seed.helpers {
                if let existing = document.helpers.first(where: { $0.id == helper.id }),
                   existing.source.version == helper.source.version { continue }
                let existing = document.helpers.first(where: { $0.id == helper.id })
                document.upsert(
                    YouziHelper(
                        id: helper.id,
                        name: helper.name,
                        summary: helper.summary,
                        systemInstructions: helper.systemInstructions,
                        methodology: helper.methodology,
                        recommendedSkillIDs: helper.recommendedSkillIDs,
                        allowedConnectorIDs: helper.allowedConnectorIDs,
                        preferredOutputTypes: helper.preferredOutputTypes,
                        source: helper.source,
                        state: Self.preservedCatalogState(existing?.state, fallback: helper.state),
                        isFavorite: existing?.isFavorite ?? helper.isFavorite,
                        createdAt: existing?.createdAt ?? helper.createdAt,
                        updatedAt: date
                    )
                )
            }
            for skill in seed.skills {
                if let existing = document.skills.first(where: { $0.id == skill.id }),
                   existing.source.version == skill.source.version { continue }
                let existing = document.skills.first(where: { $0.id == skill.id })
                document.upsert(
                    YouziSkill(
                        id: skill.id,
                        name: skill.name,
                        summary: skill.summary,
                        packageVersion: skill.packageVersion,
                        entrypoint: skill.entrypoint,
                        resourcePaths: skill.resourcePaths,
                        executionLocation: skill.executionLocation,
                        requestedPermissions: skill.requestedPermissions,
                        connectorDependencyIDs: skill.connectorDependencyIDs,
                        requiresFirstUseConfirmation: skill.requiresFirstUseConfirmation,
                        source: skill.source,
                        state: Self.preservedCatalogState(existing?.state, fallback: skill.state),
                        lastUsedAt: existing?.lastUsedAt ?? skill.lastUsedAt,
                        createdAt: existing?.createdAt ?? skill.createdAt,
                        updatedAt: date
                    )
                )
            }
            for package in seed.skillPackages {
                let existing = document.skillPackages.first(where: { $0.id == package.id })
                if let existing,
                   existing.location == package.location,
                   existing.packageVersion == package.packageVersion,
                   existing.contentSHA256 == package.contentSHA256,
                   existing.recoveryCode == package.recoveryCode,
                   existing.verifiedAt == package.verifiedAt {
                    continue
                }
                document.upsert(
                    YouziSkillPackageRecord(
                        id: package.id,
                        location: package.location,
                        packageVersion: package.packageVersion,
                        contentSHA256: package.contentSHA256,
                        recoveryCode: package.recoveryCode,
                        installedAt: existing?.installedAt ?? package.installedAt,
                        verifiedAt: package.verifiedAt,
                        updatedAt: date
                    )
                )
            }
            for connector in seed.connectors {
                if let existing = document.connectors.first(where: { $0.id == connector.id }),
                   existing.source.version == connector.source.version { continue }
                let existing = document.connectors.first(where: { $0.id == connector.id })
                document.upsert(
                    YouziConnector(
                        id: connector.id,
                        name: connector.name,
                        summary: connector.summary,
                        adapter: connector.adapter,
                        authentication: connector.authentication,
                        declaredScopes: connector.declaredScopes,
                        toolNames: connector.toolNames,
                        source: connector.source,
                        state: Self.preservedCatalogState(existing?.state, fallback: connector.state),
                        createdAt: existing?.createdAt ?? connector.createdAt,
                        updatedAt: date
                    )
                )
            }
        }
    }

    @discardableResult
    func setHelperState(id: UUID, state: YouziRecordState, at date: Date) throws
        -> YouziDomainDocument
    {
        try store.update { document in
            guard let index = document.helpers.firstIndex(where: { $0.id == id }) else {
                throw YouziCapabilityRepositoryError.helperNotFound(id)
            }
            document.helpers[index].state = state
            document.helpers[index].updatedAt = date
        }
    }

    @discardableResult
    func setHelperFavorite(id: UUID, favorite: Bool, at date: Date) throws
        -> YouziDomainDocument
    {
        try store.update { document in
            guard let index = document.helpers.firstIndex(where: { $0.id == id }) else {
                throw YouziCapabilityRepositoryError.helperNotFound(id)
            }
            document.helpers[index].isFavorite = favorite
            document.helpers[index].updatedAt = date
        }
    }

    @discardableResult
    func installSkill(
        _ skill: YouziSkill,
        package: YouziSkillPackageRecord,
        at date: Date
    ) throws -> YouziDomainDocument {
        guard package.id == skill.id,
              package.packageVersion == skill.packageVersion,
              package.contentSHA256.count == 64 else {
            throw YouziCapabilityRepositoryError.invalidPackage(skill.id)
        }
        return try store.update { document in
            var skill = skill
            skill.state = .active
            skill.updatedAt = date
            var package = package
            package.updatedAt = date
            document.upsert(skill)
            document.upsert(package)
        }
    }

    @discardableResult
    func setSkillState(id: UUID, state: YouziRecordState, at date: Date) throws
        -> YouziDomainDocument
    {
        try store.update { document in
            guard let index = document.skills.firstIndex(where: { $0.id == id }) else {
                throw YouziCapabilityRepositoryError.skillNotFound(id)
            }
            document.skills[index].state = state
            document.skills[index].updatedAt = date
        }
    }

    @discardableResult
    func uninstallSkill(id: UUID, at date: Date) throws -> YouziDomainDocument {
        try store.update { document in
            guard let index = document.skills.firstIndex(where: { $0.id == id }) else {
                throw YouziCapabilityRepositoryError.skillNotFound(id)
            }
            document.skills[index].state = .archived
            document.skills[index].updatedAt = date
            document.skillPackages.removeAll { $0.id == id }
        }
    }

    @discardableResult
    func upsertConnector(_ connector: YouziConnector, at date: Date) throws
        -> YouziDomainDocument
    {
        try store.update { document in
            var connector = connector
            connector.updatedAt = date
            document.upsert(connector)
        }
    }

    /// Creates the product definition, account, and exact runtime projection
    /// in one commit. The runtime value is a stable adapter identity only; raw
    /// MCP config, command lines, arguments, environment, and secrets never
    /// cross this boundary.
    @discardableResult
    func createConnectorAccount(
        connector: YouziConnector,
        account: YouziConnectionAccount,
        runtime: YouziConnectorRuntimeBinding,
        at date: Date
    ) throws -> YouziDomainDocument {
        guard account.connectorID == connector.id else {
            throw YouziCapabilityRepositoryError.accountConnectorMismatch(
                accountID: account.id, connectorID: connector.id
            )
        }
        return try store.update { document in
            guard !document.connectionAccounts.contains(where: { $0.id == account.id }) else {
                throw YouziCapabilityRepositoryError.accountAlreadyExists(account.id)
            }
            guard !document.connectorBindings.contains(where: { $0.id == account.id }) else {
                throw YouziCapabilityRepositoryError.bindingAlreadyExists(account.id)
            }

            if let existing = document.connectors.first(where: { $0.id == connector.id }) {
                document.upsert(
                    YouziConnector(
                        id: connector.id,
                        name: connector.name,
                        summary: connector.summary,
                        adapter: connector.adapter,
                        authentication: connector.authentication,
                        declaredScopes: connector.declaredScopes,
                        toolNames: connector.toolNames,
                        source: connector.source,
                        state: existing.state,
                        createdAt: existing.createdAt,
                        updatedAt: date
                    )
                )
            } else {
                var connector = connector
                connector.updatedAt = date
                document.upsert(connector)
            }
            var account = account
            account.updatedAt = date
            account.lastErrorSummary = nil
            document.upsert(account)
            document.upsert(
                YouziConnectorBinding(
                    id: account.id,
                    runtime: runtime,
                    configurationRevision: 1,
                    createdAt: date,
                    updatedAt: date
                )
            )
        }
    }

    @discardableResult
    func setConnectorState(id: UUID, state: YouziRecordState, at date: Date) throws
        -> YouziDomainDocument
    {
        try store.update { document in
            guard let index = document.connectors.firstIndex(where: { $0.id == id }) else {
                throw YouziCapabilityRepositoryError.connectorNotFound(id)
            }
            document.connectors[index].state = state
            document.connectors[index].updatedAt = date
        }
    }

    @discardableResult
    func upsertAccount(_ account: YouziConnectionAccount, at date: Date) throws
        -> YouziDomainDocument
    {
        try store.update { document in
            guard document.connectors.contains(where: { $0.id == account.connectorID }) else {
                throw YouziCapabilityRepositoryError.connectorNotFound(account.connectorID)
            }
            if let existing = document.connectionAccounts.first(where: { $0.id == account.id }),
               existing.recoveryCode == .credentialCleanupPending,
               (account.recoveryCode != .credentialCleanupPending
                    || account.credentialReference != existing.credentialReference) {
                throw YouziCapabilityRepositoryError.credentialCleanupPending(account.id)
            }
            var account = account
            account.updatedAt = date
            document.upsert(account)
        }
    }

    /// Applies sanitized runtime health only. Raw adapter errors remain in the
    /// runtime/logging layer; persistence receives a stable recovery code.
    @discardableResult
    func reconcileAccountHealth(
        id: UUID,
        state: YouziConnectionState,
        recoveryCode: YouziRecoveryCode?,
        at date: Date
    ) throws -> YouziDomainDocument {
        try store.update { document in
            guard let index = document.connectionAccounts.firstIndex(where: { $0.id == id }) else {
                throw YouziCapabilityRepositoryError.accountNotFound(id)
            }
            if document.connectionAccounts[index].recoveryCode == .credentialCleanupPending {
                throw YouziCapabilityRepositoryError.credentialCleanupPending(id)
            }
            document.connectionAccounts[index].state = state
            document.connectionAccounts[index].recoveryCode = recoveryCode
            document.connectionAccounts[index].lastErrorSummary = nil
            document.connectionAccounts[index].lastCheckedAt = date
            document.connectionAccounts[index].updatedAt = date
            if state == .disabled || state == .needsAttention {
                Self.revokeConnectorAuthority(accountID: id, in: &document, at: date)
            }
        }
    }

    @discardableResult
    func reconcileBindingRecovery(
        accountID: UUID,
        recoveryCode: YouziRecoveryCode?,
        at date: Date
    ) throws -> YouziDomainDocument {
        try store.update { document in
            guard document.connectionAccounts.contains(where: { $0.id == accountID }) else {
                throw YouziCapabilityRepositoryError.accountNotFound(accountID)
            }
            guard let index = document.connectorBindings.firstIndex(where: { $0.id == accountID })
            else { throw YouziCapabilityRepositoryError.bindingNotFound(accountID) }
            guard case .mcp = document.connectorBindings[index].runtime else {
                throw YouziCapabilityRepositoryError.invalidRuntimeBinding(accountID)
            }
            document.connectorBindings[index].recoveryCode = recoveryCode
            document.connectorBindings[index].updatedAt = date
        }
    }

    @discardableResult
    func reconcileBinding(
        accountID: UUID,
        runtime: YouziConnectorRuntimeBinding,
        expectedRevision: Int?,
        at date: Date
    ) throws -> YouziDomainDocument {
        try store.update { document in
            guard document.connectionAccounts.contains(where: { $0.id == accountID }) else {
                throw YouziCapabilityRepositoryError.accountNotFound(accountID)
            }
            let existingIndex = document.connectorBindings.firstIndex { $0.id == accountID }
            let actual = existingIndex.map { document.connectorBindings[$0].configurationRevision }
            guard actual == expectedRevision else {
                throw YouziCapabilityRepositoryError.bindingRevisionConflict(
                    expected: expectedRevision, actual: actual
                )
            }
            if let existingIndex, document.connectorBindings[existingIndex].runtime == runtime {
                if document.connectorBindings[existingIndex].recoveryCode != nil {
                    document.connectorBindings[existingIndex].recoveryCode = nil
                    document.connectorBindings[existingIndex].updatedAt = date
                }
                return
            }

            let newRevision = (actual ?? 0) + 1
            document.upsert(
                YouziConnectorBinding(
                    id: accountID,
                    runtime: runtime,
                    configurationRevision: newRevision,
                    createdAt: existingIndex.map { document.connectorBindings[$0].createdAt } ?? date,
                    updatedAt: date
                )
            )

            let target = accountID.uuidString.lowercased()
            let affected = Set(document.permissionGrants.compactMap { grant -> UUID? in
                guard grant.targetIdentifier == target,
                      grant.targetRevision != nil,
                      grant.targetRevision != newRevision,
                      grant.revokedAt == nil else { return nil }
                return grant.id
            })
            Self.invalidateAutomations(using: affected, in: &document, at: date)
            for index in document.permissionGrants.indices
            where affected.contains(document.permissionGrants[index].id) {
                document.permissionGrants[index].revokedAt = date
            }
        }
    }

    /// Same exact server key, different low-level executable identity. The
    /// caller detects the change in the MCP config store; this transaction
    /// increments the non-secret revision without persisting a fingerprint.
    @discardableResult
    func invalidateBindingExecutionIdentity(
        accountID: UUID,
        expectedRevision: Int,
        at date: Date
    ) throws -> YouziDomainDocument {
        try store.update { document in
            guard document.connectionAccounts.contains(where: { $0.id == accountID }) else {
                throw YouziCapabilityRepositoryError.accountNotFound(accountID)
            }
            guard let index = document.connectorBindings.firstIndex(where: { $0.id == accountID })
            else { throw YouziCapabilityRepositoryError.bindingNotFound(accountID) }
            guard case .mcp = document.connectorBindings[index].runtime else {
                throw YouziCapabilityRepositoryError.invalidRuntimeBinding(accountID)
            }
            let actual = document.connectorBindings[index].configurationRevision
            guard actual == expectedRevision else {
                throw YouziCapabilityRepositoryError.bindingRevisionConflict(
                    expected: expectedRevision, actual: actual
                )
            }
            document.connectorBindings[index].configurationRevision = actual + 1
            document.connectorBindings[index].recoveryCode = nil
            document.connectorBindings[index].updatedAt = date
            let target = accountID.uuidString.lowercased()
            let affected = Set(document.permissionGrants.compactMap { grant -> UUID? in
                guard grant.targetIdentifier == target,
                      grant.targetRevision == actual,
                      grant.revokedAt == nil else { return nil }
                return grant.id
            })
            Self.invalidateAutomations(using: affected, in: &document, at: date)
            for grantIndex in document.permissionGrants.indices
            where affected.contains(document.permissionGrants[grantIndex].id) {
                document.permissionGrants[grantIndex].revokedAt = date
            }
        }
    }

    /// One refresh commit for advertised tools plus sanitized account/binding
    /// health. This avoids a partially refreshed durable projection.
    @discardableResult
    func reconcileMCPAccount(
        id: UUID,
        toolNames: [String],
        state: YouziConnectionState,
        accountRecoveryCode: YouziRecoveryCode?,
        bindingRecoveryCode: YouziRecoveryCode?,
        at date: Date
    ) throws -> YouziDomainDocument {
        try store.update { document in
            guard let accountIndex = document.connectionAccounts.firstIndex(where: { $0.id == id })
            else { throw YouziCapabilityRepositoryError.accountNotFound(id) }
            let account = document.connectionAccounts[accountIndex]
            guard account.recoveryCode != .credentialCleanupPending else {
                throw YouziCapabilityRepositoryError.credentialCleanupPending(id)
            }
            guard let connectorIndex = document.connectors.firstIndex(
                where: { $0.id == account.connectorID }
            ) else { throw YouziCapabilityRepositoryError.connectorNotFound(account.connectorID) }
            guard let bindingIndex = document.connectorBindings.firstIndex(where: { $0.id == id })
            else { throw YouziCapabilityRepositoryError.bindingNotFound(id) }
            guard document.connectors[connectorIndex].adapter == .mcp,
                  case .mcp = document.connectorBindings[bindingIndex].runtime else {
                throw YouziCapabilityRepositoryError.invalidRuntimeBinding(id)
            }

            document.connectors[connectorIndex].toolNames = Self.sortedUnique(toolNames)
            document.connectors[connectorIndex].updatedAt = date
            document.connectionAccounts[accountIndex].state = state
            document.connectionAccounts[accountIndex].recoveryCode = accountRecoveryCode
            document.connectionAccounts[accountIndex].lastErrorSummary = nil
            document.connectionAccounts[accountIndex].lastCheckedAt = date
            document.connectionAccounts[accountIndex].updatedAt = date
            document.connectorBindings[bindingIndex].recoveryCode = bindingRecoveryCode
            document.connectorBindings[bindingIndex].updatedAt = date
            if state == .disabled || state == .needsAttention {
                Self.revokeConnectorAuthority(accountID: id, in: &document, at: date)
            }
        }
    }

    @discardableResult
    func setAccountEnabled(id: UUID, enabled: Bool, at date: Date) throws
        -> YouziDomainDocument
    {
        try store.update { document in
            guard let index = document.connectionAccounts.firstIndex(where: { $0.id == id }) else {
                throw YouziCapabilityRepositoryError.accountNotFound(id)
            }
            if enabled,
               document.connectionAccounts[index].recoveryCode == .credentialCleanupPending {
                throw YouziCapabilityRepositoryError.credentialCleanupPending(id)
            }
            document.connectionAccounts[index].state = enabled ? .notConnected : .disabled
            document.connectionAccounts[index].recoveryCode = nil
            document.connectionAccounts[index].lastErrorSummary = nil
            document.connectionAccounts[index].updatedAt = date
            if !enabled {
                Self.revokeConnectorAuthority(accountID: id, in: &document, at: date)
            }
        }
    }

    /// Stops execution while retaining the exact account and binding so the
    /// user can reconnect without display-name inference.
    @discardableResult
    func disconnectAccount(id: UUID, at date: Date) throws -> YouziDomainDocument {
        try store.update { document in
            guard let index = document.connectionAccounts.firstIndex(where: { $0.id == id }) else {
                throw YouziCapabilityRepositoryError.accountNotFound(id)
            }
            if document.connectionAccounts[index].recoveryCode == .credentialCleanupPending {
                throw YouziCapabilityRepositoryError.credentialCleanupPending(id)
            }
            document.connectionAccounts[index].state = .notConnected
            document.connectionAccounts[index].recoveryCode = nil
            document.connectionAccounts[index].lastErrorSummary = nil
            document.connectionAccounts[index].updatedAt = date
            Self.revokeConnectorAuthority(accountID: id, in: &document, at: date)
        }
    }

    /// First phase of fail-closed Keychain deletion. Runtime must refuse this
    /// account while the opaque reference remains available for retry.
    @discardableResult
    func beginCredentialCleanup(id: UUID, at date: Date) throws -> YouziDomainDocument {
        try store.update { document in
            guard let index = document.connectionAccounts.firstIndex(where: { $0.id == id }) else {
                throw YouziCapabilityRepositoryError.accountNotFound(id)
            }
            document.connectionAccounts[index].state = .needsAttention
            document.connectionAccounts[index].recoveryCode = .credentialCleanupPending
            document.connectionAccounts[index].lastErrorSummary = nil
            document.connectionAccounts[index].updatedAt = date
            Self.revokeConnectorAuthority(accountID: id, in: &document, at: date)
        }
    }

    /// Called only after the credential vault confirms deletion.
    @discardableResult
    func finishCredentialCleanup(id: UUID, at date: Date) throws -> YouziDomainDocument {
        try store.update { document in
            guard let index = document.connectionAccounts.firstIndex(where: { $0.id == id }) else {
                throw YouziCapabilityRepositoryError.accountNotFound(id)
            }
            guard document.connectionAccounts[index].recoveryCode == .credentialCleanupPending else {
                throw YouziCapabilityRepositoryError.credentialCleanupNotPending(id)
            }
            document.connectionAccounts[index].credentialReference = nil
            document.connectionAccounts[index].state = .notConnected
            document.connectionAccounts[index].recoveryCode = nil
            document.connectionAccounts[index].lastErrorSummary = nil
            document.connectionAccounts[index].updatedAt = date
        }
    }

    /// Final destructive phase after credential cleanup. Immutable permission,
    /// grant, and audit history is never purged or rewritten by account forget.
    /// An account referenced by that history remains as a disconnected durable
    /// identity and forget fails closed with `accountStillReferenced`.
    @discardableResult
    func forgetAccount(id: UUID, at date: Date) throws -> YouziDomainDocument {
        try store.update { document in
            guard let account = document.connectionAccounts.first(where: { $0.id == id }) else {
                throw YouziCapabilityRepositoryError.accountNotFound(id)
            }
            guard account.credentialReference == nil,
                  account.recoveryCode != .credentialCleanupPending else {
                throw YouziCapabilityRepositoryError.credentialCleanupPending(id)
            }
            let target = id.uuidString.lowercased()
            let referenced = document.tasks.contains { $0.connectionAccountIDs.contains(id) }
                || document.projects.contains { $0.defaultConnectionAccountIDs.contains(id) }
                || document.automations.contains { $0.action.connectionAccountIDs.contains(id) }
                || document.permissions.contains {
                    $0.targetIdentifier == target
                        && ($0.kind == .connectorRead || $0.kind == .connectorWrite
                            || $0.kind == .externalPublish)
                }
                || document.permissionGrants.contains { $0.targetIdentifier == target }
                || document.executionAuditEvents.contains { $0.connectionAccountID == id }
            guard !referenced else {
                throw YouziCapabilityRepositoryError.accountStillReferenced(id)
            }
            document.connectorBindings.removeAll { $0.id == id }
            document.connectionAccounts.removeAll { $0.id == id }
            _ = date // The destructive transaction has no surviving timestamp target.
        }
    }

    private static func invalidateAutomations(
        using affectedGrantIDs: Set<UUID>,
        in document: inout YouziDomainDocument,
        at date: Date
    ) {
        guard !affectedGrantIDs.isEmpty else { return }
        for index in document.automations.indices
        where !affectedGrantIDs.isDisjoint(with: document.automations[index].permissionGrantIDs) {
            let allGrantIDs = Set(document.automations[index].permissionGrantIDs)
            for grantIndex in document.permissionGrants.indices
            where allGrantIDs.contains(document.permissionGrants[grantIndex].id)
                    && document.permissionGrants[grantIndex].revokedAt == nil {
                document.permissionGrants[grantIndex].revokedAt = date
            }
            document.automations[index].revision += 1
            document.automations[index].permissionGrantIDs = []
            document.automations[index].confirmedAt = nil
            document.automations[index].state = .needsAttention
            document.automations[index].updatedAt = date
        }
    }

    private static func revokeConnectorAuthority(
        accountID: UUID,
        in document: inout YouziDomainDocument,
        at date: Date
    ) {
        let target = accountID.uuidString.lowercased()
        let affected = Set(document.permissionGrants.compactMap { grant -> UUID? in
            guard grant.targetIdentifier == target, grant.revokedAt == nil else { return nil }
            return grant.id
        })
        invalidateAutomations(using: affected, in: &document, at: date)
        for index in document.permissionGrants.indices
        where affected.contains(document.permissionGrants[index].id) {
            document.permissionGrants[index].revokedAt = date
        }
    }

    private static func preservedCatalogState(
        _ existing: YouziRecordState?, fallback: YouziRecordState
    ) -> YouziRecordState {
        switch existing {
        case .disabled?: return .disabled
        case .archived?: return .archived
        case .active?, .unavailable?, nil: return fallback
        }
    }

    private static func sortedUnique(_ values: [String]) -> [String] {
        Array(Set(values)).sorted()
    }
}
