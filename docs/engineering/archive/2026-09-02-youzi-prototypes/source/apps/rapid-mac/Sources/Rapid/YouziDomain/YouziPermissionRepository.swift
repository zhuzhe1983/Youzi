import Foundation

enum YouziPermissionRepositoryError: Error, Equatable, Sendable {
    case requestAlreadyExists(UUID)
    case requestNotFound(UUID)
    case taskNotFound(UUID)
    case requestTaskMismatch(UUID)
    case duplicateTaskRequest(UUID)
    case requestNotLinkedToTask(UUID)
    case invalidTaskRequestDuration(UUID)
    case automationNotFound(UUID)
    case automationRevisionConflict(expected: Int, actual: Int)
    case requestNotLinkedToAutomation(UUID)
    case invalidAutomationRequestDuration(UUID)
    case duplicateAutomationRequest(UUID)
    case requestAutomationMismatch(UUID)
    case authorityRevisionRequired(UUID)
    case grantNotFound(UUID)
    case grantIDConflict(UUID)
    case requestAlreadyDecided(UUID)
    case invalidDecision
    case invalidGrantSubject(UUID)
    case grantNotConsumable(UUID)
}

final class YouziPermissionRepository: @unchecked Sendable {
    private let store: YouziDomainStore
    private let idGenerator: @Sendable () -> UUID

    init(
        store: YouziDomainStore = YouziDomainStore(),
        idGenerator: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.store = store
        self.idGenerator = idGenerator
    }

    @discardableResult
    func request(_ request: YouziPermissionRecord) throws -> YouziDomainDocument {
        guard request.decision == .pending, request.decidedAt == nil else {
            throw YouziPermissionRepositoryError.invalidDecision
        }
        return try store.update { document in
            guard !document.permissions.contains(where: { $0.id == request.id }) else {
                throw YouziPermissionRepositoryError.requestAlreadyExists(request.id)
            }
            if let taskID = request.taskID {
                guard request.automationID == nil, request.automationRevision == nil,
                      let taskIndex = document.tasks.firstIndex(where: { $0.id == taskID }) else {
                    if document.tasks.contains(where: { $0.id == taskID }) {
                        throw YouziPermissionRepositoryError.requestTaskMismatch(request.id)
                    }
                    throw YouziPermissionRepositoryError.taskNotFound(taskID)
                }
                document.tasks[taskIndex].permissionRecordIDs.append(request.id)
                document.tasks[taskIndex].permissionRecordIDs = Self.sortedUnique(
                    document.tasks[taskIndex].permissionRecordIDs
                )
            }
            document.upsert(request)
        }
    }

    /// Atomically creates every permission request needed before a task send
    /// and links the resolved request IDs back to that task. An exact pending
    /// request (same kind, target, purpose, and duration) is reused. A decided
    /// request is immutable history, so the caller's fresh ID creates a new
    /// request. Reusing a decided ID or colliding with a different pending
    /// request fails the whole batch without changing the file.
    @discardableResult
    func requestForTask(
        taskID: UUID,
        requests: [YouziPermissionRecord]
    ) throws -> (permissionRecordIDs: [UUID], document: YouziDomainDocument) {
        if requests.isEmpty {
            let document = try store.load()
            guard document.tasks.contains(where: { $0.id == taskID }) else {
                throw YouziPermissionRepositoryError.taskNotFound(taskID)
            }
            return ([], document)
        }

        var resolvedIDs: [UUID] = []
        let document = try store.update { document in
            guard let taskIndex = document.tasks.firstIndex(where: { $0.id == taskID }) else {
                throw YouziPermissionRepositoryError.taskNotFound(taskID)
            }

            var batchKeys: [TaskRequestKey: UUID] = [:]
            for request in requests {
                guard request.taskID == taskID,
                      request.automationID == nil,
                      request.automationRevision == nil else {
                    throw YouziPermissionRepositoryError.requestTaskMismatch(request.id)
                }
                guard request.decision == .pending, request.decidedAt == nil else {
                    throw YouziPermissionRepositoryError.invalidDecision
                }

                let key = TaskRequestKey(request)
                if let existingID = batchKeys[key], existingID != request.id {
                    throw YouziPermissionRepositoryError.duplicateTaskRequest(existingID)
                }
                batchKeys[key] = request.id

                if let existing = document.permissions.first(where: { $0.id == request.id }) {
                    if existing.decision != .pending {
                        throw YouziPermissionRepositoryError.requestAlreadyDecided(request.id)
                    }
                    guard TaskRequestKey(existing) == key, existing.taskID == taskID else {
                        throw YouziPermissionRepositoryError.requestAlreadyExists(request.id)
                    }
                    resolvedIDs.append(existing.id)
                    continue
                }

                if let pending = document.permissions.first(where: {
                    $0.taskID == taskID && $0.decision == .pending && TaskRequestKey($0) == key
                }) {
                    resolvedIDs.append(pending.id)
                    continue
                }

                document.permissions.append(request)
                resolvedIDs.append(request.id)
            }

            document.tasks[taskIndex].permissionRecordIDs.append(contentsOf: resolvedIDs)
            document.tasks[taskIndex].permissionRecordIDs = Self.sortedUnique(
                document.tasks[taskIndex].permissionRecordIDs
            )
        }
        return (resolvedIDs, document)
    }

    /// Adds an automation revision's permission history without changing that
    /// revision. Exact pending requests are reused; decided records remain
    /// immutable and require fresh IDs. The complete batch and backlink update
    /// share one domain transaction.
    @discardableResult
    func preparePermissionRequests(
        automationID: UUID,
        expectedRevision: Int,
        requests: [YouziPermissionRecord]
    ) throws -> (permissionRecordIDs: [UUID], document: YouziDomainDocument) {
        if requests.isEmpty {
            let document = try store.load()
            guard let automation = document.automations.first(
                where: { $0.id == automationID }
            ) else {
                throw YouziPermissionRepositoryError.automationNotFound(automationID)
            }
            guard automation.revision == expectedRevision else {
                throw YouziPermissionRepositoryError.automationRevisionConflict(
                    expected: expectedRevision,
                    actual: automation.revision
                )
            }
            return ([], document)
        }

        var resolvedIDs: [UUID] = []
        let document = try store.update { document in
            guard let automationIndex = document.automations.firstIndex(
                where: { $0.id == automationID }
            ) else {
                throw YouziPermissionRepositoryError.automationNotFound(automationID)
            }
            guard document.automations[automationIndex].revision == expectedRevision else {
                throw YouziPermissionRepositoryError.automationRevisionConflict(
                    expected: expectedRevision,
                    actual: document.automations[automationIndex].revision
                )
            }
            if Self.hasConfirmedAuthority(document.automations[automationIndex]) {
                throw YouziPermissionRepositoryError.authorityRevisionRequired(automationID)
            }

            var batchKeys: [AutomationRequestKey: UUID] = [:]
            for request in requests {
                guard request.taskID == nil,
                      request.automationID == automationID,
                      request.automationRevision == expectedRevision else {
                    throw YouziPermissionRepositoryError.requestAutomationMismatch(request.id)
                }
                guard request.duration == .persistent else {
                    throw YouziPermissionRepositoryError.invalidAutomationRequestDuration(
                        request.id
                    )
                }
                guard request.decision == .pending, request.decidedAt == nil else {
                    throw YouziPermissionRepositoryError.invalidDecision
                }

                let key = AutomationRequestKey(request)
                if let existingID = batchKeys[key], existingID != request.id {
                    throw YouziPermissionRepositoryError.duplicateAutomationRequest(existingID)
                }
                batchKeys[key] = request.id

                if let existing = document.permissions.first(where: { $0.id == request.id }) {
                    if existing.decision != .pending {
                        throw YouziPermissionRepositoryError.requestAlreadyDecided(request.id)
                    }
                    guard AutomationRequestKey(existing) == key else {
                        throw YouziPermissionRepositoryError.requestAlreadyExists(request.id)
                    }
                    resolvedIDs.append(existing.id)
                    continue
                }

                if let pending = document.permissions.first(where: {
                    $0.decision == .pending && AutomationRequestKey($0) == key
                }) {
                    resolvedIDs.append(pending.id)
                    continue
                }

                document.permissions.append(request)
                resolvedIDs.append(request.id)
            }

            document.automations[automationIndex].permissionRecordIDs.append(
                contentsOf: resolvedIDs
            )
            document.automations[automationIndex].permissionRecordIDs = Self.sortedUnique(
                document.automations[automationIndex].permissionRecordIDs
            )
        }
        return (resolvedIDs, document)
    }

    /// Replaces the semantic permission scope for one automation under CAS.
    /// Proposal records are scoped to the expected current revision. When a
    /// confirmed/active authority set changes, this method revokes attached
    /// grants, increments once, clears confirmation, and persists copies of
    /// the proposals bound to the new revision in the same transaction.
    /// Unchanged scope returns byte-equivalent authority without a bump.
    @discardableResult
    func revisePermissionScope(
        automationID: UUID,
        expectedRevision: Int,
        requests: [YouziPermissionRecord],
        at date: Date
    ) throws -> (
        revision: Int,
        permissionRecordIDs: [UUID],
        didChange: Bool,
        document: YouziDomainDocument
    ) {
        var resultingRevision = expectedRevision
        var resolvedIDs: [UUID] = []
        var didChange = false
        let document = try store.update { document in
            guard let automationIndex = document.automations.firstIndex(
                where: { $0.id == automationID }
            ) else {
                throw YouziPermissionRepositoryError.automationNotFound(automationID)
            }
            let automation = document.automations[automationIndex]
            guard automation.revision == expectedRevision else {
                throw YouziPermissionRepositoryError.automationRevisionConflict(
                    expected: expectedRevision,
                    actual: automation.revision
                )
            }

            var proposalsByKey: [AutomationScopeKey: YouziPermissionRecord] = [:]
            var proposalIDs = Set<UUID>()
            for request in requests.sorted(by: { Self.ordersUUIDs($0.id, $1.id) }) {
                guard proposalIDs.insert(request.id).inserted else {
                    throw YouziPermissionRepositoryError.duplicateAutomationRequest(request.id)
                }
                guard request.taskID == nil,
                      request.automationID == automationID,
                      request.automationRevision == expectedRevision else {
                    throw YouziPermissionRepositoryError.requestAutomationMismatch(request.id)
                }
                guard request.duration == .persistent else {
                    throw YouziPermissionRepositoryError.invalidAutomationRequestDuration(
                        request.id
                    )
                }
                guard request.decision == .pending, request.decidedAt == nil else {
                    throw YouziPermissionRepositoryError.invalidDecision
                }
                let key = AutomationScopeKey(request)
                if let existing = proposalsByKey[key], existing.id != request.id {
                    throw YouziPermissionRepositoryError.duplicateAutomationRequest(existing.id)
                }
                proposalsByKey[key] = request
            }

            let liveRevisionGrants = document.permissionGrants.filter {
                $0.automationID == automationID
                    && $0.automationRevision == expectedRevision
                    && $0.revokedAt == nil
            }
            let authoritativeRequestIDs = Set(liveRevisionGrants.map(\.permissionRecordID))
            let hasIssuedAuthority = Self.hasConfirmedAuthority(automation)
                || !liveRevisionGrants.isEmpty
            let currentRequests = automation.permissionRecordIDs.compactMap { id in
                document.permissions.first(where: {
                    $0.id == id
                        && $0.automationID == automationID
                        && $0.automationRevision == expectedRevision
                        && (hasIssuedAuthority
                            ? authoritativeRequestIDs.contains($0.id)
                            : $0.decision == .pending)
                })
            }
            let currentKeys = Set(currentRequests.map(AutomationScopeKey.init))
            let desiredKeys = Set(proposalsByKey.keys)
            guard currentKeys != desiredKeys else {
                var seen = Set<AutomationScopeKey>()
                resolvedIDs = currentRequests.sorted { Self.ordersUUIDs($0.id, $1.id) }
                    .compactMap { seen.insert(AutomationScopeKey($0)).inserted ? $0.id : nil }
                resultingRevision = expectedRevision
                return
            }

            didChange = true
            let mustInvalidate = hasIssuedAuthority
            resultingRevision = mustInvalidate ? expectedRevision + 1 : expectedRevision
            if mustInvalidate {
                for index in document.permissionGrants.indices
                where document.permissionGrants[index].automationID == automationID
                        && document.permissionGrants[index].automationRevision == expectedRevision
                        && document.permissionGrants[index].revokedAt == nil {
                    document.permissionGrants[index].revokedAt = date
                }
                document.automations[automationIndex].revision = resultingRevision
                document.automations[automationIndex].permissionGrantIDs = []
                document.automations[automationIndex].confirmedAt = nil
                document.automations[automationIndex].state = .needsAttention
                document.automations[automationIndex].updatedAt = date
            } else {
                let supersededIDs = Set(currentRequests.map(\.id))
                for index in document.permissions.indices
                where supersededIDs.contains(document.permissions[index].id)
                        && document.permissions[index].decision == .pending {
                    document.permissions[index].decision = .revoked
                    document.permissions[index].decidedAt = date
                }
            }

            for proposal in proposalsByKey.values.sorted(
                by: { Self.ordersUUIDs($0.id, $1.id) }
            ) {
                var request = proposal
                request.automationRevision = resultingRevision
                let key = AutomationRequestKey(request)
                if let existing = document.permissions.first(where: { $0.id == request.id }) {
                    if existing.decision != .pending {
                        throw YouziPermissionRepositoryError.requestAlreadyDecided(request.id)
                    }
                    guard AutomationRequestKey(existing) == key else {
                        throw YouziPermissionRepositoryError.requestAlreadyExists(request.id)
                    }
                    resolvedIDs.append(existing.id)
                    continue
                }
                if let pending = document.permissions.first(where: {
                    $0.decision == .pending && AutomationRequestKey($0) == key
                }) {
                    resolvedIDs.append(pending.id)
                    continue
                }
                document.permissions.append(request)
                resolvedIDs.append(request.id)
            }
            document.automations[automationIndex].permissionRecordIDs.append(
                contentsOf: resolvedIDs
            )
            document.automations[automationIndex].permissionRecordIDs = Self.sortedUnique(
                document.automations[automationIndex].permissionRecordIDs
            )
        }
        return (resultingRevision, resolvedIDs, didChange, document)
    }

    @discardableResult
    func decide(
        id: UUID,
        decision: YouziPermissionDecision,
        at date: Date
    ) throws -> (YouziPermissionGrant?, YouziDomainDocument) {
        guard decision == .allowed || decision == .denied else {
            throw YouziPermissionRepositoryError.invalidDecision
        }
        var issued: YouziPermissionGrant?
        let document = try store.update { document in
            guard let index = document.permissions.firstIndex(where: { $0.id == id }) else {
                throw YouziPermissionRepositoryError.requestNotFound(id)
            }
            guard document.permissions[index].decision == .pending else {
                throw YouziPermissionRepositoryError.requestAlreadyDecided(id)
            }
            document.permissions[index].decision = decision
            document.permissions[index].decidedAt = date

            guard decision == .allowed else { return }
            let request = document.permissions[index]
            if request.taskID != nil && request.automationID != nil
                || ((request.automationID == nil) != (request.automationRevision == nil))
                || (request.automationID != nil && request.duration != .persistent) {
                throw YouziPermissionRepositoryError.invalidGrantSubject(id)
            }
            var targetRevision: Int?
            if request.kind == .connectorRead || request.kind == .connectorWrite
                || request.kind == .externalPublish {
                guard let accountID = UUID(uuidString: request.targetIdentifier),
                      let binding = document.connectorBindings.first(where: { $0.id == accountID })
                else { throw YouziPermissionRepositoryError.invalidGrantSubject(id) }
                targetRevision = binding.configurationRevision
            }
            let grantID = idGenerator()
            guard !document.permissionGrants.contains(where: { $0.id == grantID }) else {
                throw YouziPermissionRepositoryError.grantIDConflict(grantID)
            }
            let grant = YouziPermissionGrant(
                id: grantID,
                permissionRecordID: request.id,
                taskID: request.taskID,
                automationID: request.automationID,
                automationRevision: request.automationRevision,
                kind: request.kind,
                targetIdentifier: request.targetIdentifier,
                targetRevision: targetRevision,
                duration: request.duration,
                grantedAt: date
            )
            document.upsert(grant)
            issued = grant
        }
        return (issued, document)
    }

    /// Decides one task execution plan as a unit. Request IDs are processed in
    /// stable UUID order, so injected grant IDs are assigned deterministically
    /// regardless of UI ordering. Validation and grant-ID reservation complete
    /// before any decision is mutated; one stale request, bad backlink, missing
    /// connector binding, or ID collision rolls back the complete transaction.
    @discardableResult
    func decideForTask(
        taskID: UUID,
        requestIDs: [UUID],
        decision: YouziPermissionDecision,
        at date: Date
    ) throws -> (grants: [YouziPermissionGrant], document: YouziDomainDocument) {
        guard decision == .allowed || decision == .denied else {
            throw YouziPermissionRepositoryError.invalidDecision
        }

        var issued: [YouziPermissionGrant] = []
        let document = try store.update { document in
            guard let task = document.tasks.first(where: { $0.id == taskID }) else {
                throw YouziPermissionRepositoryError.taskNotFound(taskID)
            }
            let orderedIDs = requestIDs.sorted(by: Self.ordersUUIDs)
            guard Set(orderedIDs).count == orderedIDs.count else {
                let duplicate = Self.firstDuplicate(in: orderedIDs) ?? taskID
                throw YouziPermissionRepositoryError.duplicateTaskRequest(duplicate)
            }

            var requests: [YouziPermissionRecord] = []
            var targetRevisions: [UUID: Int] = [:]
            for id in orderedIDs {
                guard let request = document.permissions.first(where: { $0.id == id }) else {
                    throw YouziPermissionRepositoryError.requestNotFound(id)
                }
                guard request.decision == .pending else {
                    throw YouziPermissionRepositoryError.requestAlreadyDecided(id)
                }
                guard request.taskID == taskID,
                      request.automationID == nil,
                      request.automationRevision == nil else {
                    throw YouziPermissionRepositoryError.requestTaskMismatch(id)
                }
                guard request.duration == .once || request.duration == .task else {
                    throw YouziPermissionRepositoryError.invalidTaskRequestDuration(id)
                }
                guard task.permissionRecordIDs.contains(id) else {
                    throw YouziPermissionRepositoryError.requestNotLinkedToTask(id)
                }
                if request.kind == .connectorRead || request.kind == .connectorWrite
                    || request.kind == .externalPublish {
                    guard let accountID = UUID(uuidString: request.targetIdentifier),
                          let binding = document.connectorBindings.first(
                              where: { $0.id == accountID }
                          ) else {
                        throw YouziPermissionRepositoryError.invalidGrantSubject(id)
                    }
                    targetRevisions[id] = binding.configurationRevision
                }
                requests.append(request)
            }

            if decision == .allowed {
                var reservedIDs = Set(document.permissionGrants.map(\.id))
                for request in requests {
                    let grantID = idGenerator()
                    guard reservedIDs.insert(grantID).inserted else {
                        throw YouziPermissionRepositoryError.grantIDConflict(grantID)
                    }
                    issued.append(
                        YouziPermissionGrant(
                            id: grantID,
                            permissionRecordID: request.id,
                            taskID: taskID,
                            kind: request.kind,
                            targetIdentifier: request.targetIdentifier,
                            targetRevision: targetRevisions[request.id],
                            duration: request.duration,
                            grantedAt: date
                        )
                    )
                }
            }

            let requestIDSet = Set(orderedIDs)
            for index in document.permissions.indices
            where requestIDSet.contains(document.permissions[index].id) {
                document.permissions[index].decision = decision
                document.permissions[index].decidedAt = date
            }
            document.permissionGrants.append(contentsOf: issued)
        }
        return (issued, document)
    }

    /// Atomically decides and, when allowed, issues every persistent grant for
    /// one exact automation revision. Grant IDs are assigned in stable request
    /// UUID order. Attaching the returned grants and activating the automation
    /// remains the separate CAS performed by `YouziAutomationRepository.confirm`.
    @discardableResult
    func decideForAutomation(
        automationID: UUID,
        expectedRevision: Int,
        requestIDs: [UUID],
        decision: YouziPermissionDecision,
        at date: Date
    ) throws -> (grants: [YouziPermissionGrant], document: YouziDomainDocument) {
        guard decision == .allowed || decision == .denied else {
            throw YouziPermissionRepositoryError.invalidDecision
        }

        var issued: [YouziPermissionGrant] = []
        let document = try store.update { document in
            guard let automation = document.automations.first(
                where: { $0.id == automationID }
            ) else {
                throw YouziPermissionRepositoryError.automationNotFound(automationID)
            }
            guard automation.revision == expectedRevision else {
                throw YouziPermissionRepositoryError.automationRevisionConflict(
                    expected: expectedRevision,
                    actual: automation.revision
                )
            }
            let orderedIDs = requestIDs.sorted(by: Self.ordersUUIDs)
            guard Set(orderedIDs).count == orderedIDs.count else {
                let duplicate = Self.firstDuplicate(in: orderedIDs) ?? automationID
                throw YouziPermissionRepositoryError.duplicateAutomationRequest(duplicate)
            }

            var requests: [YouziPermissionRecord] = []
            var targetRevisions: [UUID: Int] = [:]
            for id in orderedIDs {
                guard let request = document.permissions.first(where: { $0.id == id }) else {
                    throw YouziPermissionRepositoryError.requestNotFound(id)
                }
                guard request.decision == .pending else {
                    throw YouziPermissionRepositoryError.requestAlreadyDecided(id)
                }
                guard request.taskID == nil,
                      request.automationID == automationID,
                      request.automationRevision == expectedRevision else {
                    throw YouziPermissionRepositoryError.invalidGrantSubject(id)
                }
                guard request.duration == .persistent else {
                    throw YouziPermissionRepositoryError.invalidAutomationRequestDuration(id)
                }
                guard automation.permissionRecordIDs.contains(id) else {
                    throw YouziPermissionRepositoryError.requestNotLinkedToAutomation(id)
                }
                if request.kind == .connectorRead || request.kind == .connectorWrite
                    || request.kind == .externalPublish {
                    guard let accountID = UUID(uuidString: request.targetIdentifier),
                          let binding = document.connectorBindings.first(
                              where: { $0.id == accountID }
                          ) else {
                        throw YouziPermissionRepositoryError.invalidGrantSubject(id)
                    }
                    targetRevisions[id] = binding.configurationRevision
                }
                requests.append(request)
            }

            if decision == .allowed {
                var reservedIDs = Set(document.permissionGrants.map(\.id))
                for request in requests {
                    let grantID = idGenerator()
                    guard reservedIDs.insert(grantID).inserted else {
                        throw YouziPermissionRepositoryError.grantIDConflict(grantID)
                    }
                    issued.append(
                        YouziPermissionGrant(
                            id: grantID,
                            permissionRecordID: request.id,
                            automationID: automationID,
                            automationRevision: expectedRevision,
                            kind: request.kind,
                            targetIdentifier: request.targetIdentifier,
                            targetRevision: targetRevisions[request.id],
                            duration: .persistent,
                            grantedAt: date
                        )
                    )
                }
            }

            let requestIDSet = Set(orderedIDs)
            for index in document.permissions.indices
            where requestIDSet.contains(document.permissions[index].id) {
                document.permissions[index].decision = decision
                document.permissions[index].decidedAt = date
            }
            document.permissionGrants.append(contentsOf: issued)
        }
        return (issued, document)
    }

    @discardableResult
    func consume(grantID: UUID, at date: Date) throws -> YouziDomainDocument {
        try store.update { document in
            guard let index = document.permissionGrants.firstIndex(where: { $0.id == grantID }) else {
                throw YouziPermissionRepositoryError.grantNotFound(grantID)
            }
            let grant = document.permissionGrants[index]
            guard grant.duration == .once, grant.consumedAt == nil,
                  grant.revokedAt == nil,
                  grant.expiresAt.map({ $0 > date }) ?? true else {
                throw YouziPermissionRepositoryError.grantNotConsumable(grantID)
            }
            document.permissionGrants[index].consumedAt = date
        }
    }

    @discardableResult
    func revoke(grantID: UUID, at date: Date) throws -> YouziDomainDocument {
        try store.update { document in
            guard let index = document.permissionGrants.firstIndex(where: { $0.id == grantID }) else {
                throw YouziPermissionRepositoryError.grantNotFound(grantID)
            }
            if document.permissionGrants[index].revokedAt != nil { return }
            document.permissionGrants[index].revokedAt = date
            if let requestIndex = document.permissions.firstIndex(
                where: { $0.id == document.permissionGrants[index].permissionRecordID }
            ) {
                document.permissions[requestIndex].decision = .revoked
                document.permissions[requestIndex].decidedAt = date
            }

            guard let automationID = document.permissionGrants[index].automationID,
                  let automationIndex = document.automations.firstIndex(
                    where: { $0.id == automationID }
                  ) else { return }
            let attached = Set(document.automations[automationIndex].permissionGrantIDs)
            guard attached.contains(grantID) else { return }
            for grantIndex in document.permissionGrants.indices
            where attached.contains(document.permissionGrants[grantIndex].id)
                    && document.permissionGrants[grantIndex].revokedAt == nil {
                document.permissionGrants[grantIndex].revokedAt = date
            }
            document.automations[automationIndex].revision += 1
            document.automations[automationIndex].permissionGrantIDs = []
            document.automations[automationIndex].confirmedAt = nil
            document.automations[automationIndex].state = .needsAttention
            document.automations[automationIndex].updatedAt = date
        }
    }

    private static func sortedUnique(_ ids: [UUID]) -> [UUID] {
        Array(Set(ids)).sorted(by: ordersUUIDs)
    }

    private static func ordersUUIDs(_ lhs: UUID, _ rhs: UUID) -> Bool {
        lhs.uuidString.lowercased() < rhs.uuidString.lowercased()
    }

    private static func firstDuplicate(in ids: [UUID]) -> UUID? {
        var seen = Set<UUID>()
        return ids.first(where: { !seen.insert($0).inserted })
    }

    private static func hasConfirmedAuthority(_ automation: YouziAutomation) -> Bool {
        automation.state == .active
            || automation.confirmedAt != nil
            || !automation.permissionGrantIDs.isEmpty
    }

    private struct TaskRequestKey: Hashable {
        var kind: YouziPermissionKind
        var targetIdentifier: String
        var purpose: String
        var duration: YouziPermissionDuration

        init(_ request: YouziPermissionRecord) {
            kind = request.kind
            targetIdentifier = request.targetIdentifier
            purpose = request.purpose
            duration = request.duration
        }
    }

    private struct AutomationRequestKey: Hashable {
        var automationID: UUID?
        var automationRevision: Int?
        var kind: YouziPermissionKind
        var targetIdentifier: String
        var purpose: String
        var duration: YouziPermissionDuration

        init(_ request: YouziPermissionRecord) {
            automationID = request.automationID
            automationRevision = request.automationRevision
            kind = request.kind
            targetIdentifier = request.targetIdentifier
            purpose = request.purpose
            duration = request.duration
        }
    }

    private struct AutomationScopeKey: Hashable {
        var kind: YouziPermissionKind
        var targetIdentifier: String
        var purpose: String
        var duration: YouziPermissionDuration

        init(_ request: YouziPermissionRecord) {
            kind = request.kind
            targetIdentifier = request.targetIdentifier
            purpose = request.purpose
            duration = request.duration
        }
    }
}
