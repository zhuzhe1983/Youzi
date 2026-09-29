import Foundation

enum YouziTaskExecutionPlanningIssue: Equatable, Sendable {
    case capability(YouziTaskCapabilityIssue)
    case ambiguousConnectedApplicationTool(name: String)
    case missingAuthorizationMetadata(name: String)
}

struct YouziTaskToolAuthorizationSnapshot: Equatable, Sendable {
    let requirement: YouziExecutionPermissionRequirement
    let runtime: YouziExecutionPermissionRuntimeGate
}

struct YouziTaskPermissionNeed: Identifiable, Equatable, Sendable {
    let requirement: YouziExecutionPermissionRequirement
    let title: String
    let detail: String

    var id: String {
        "\(requirement.kind.rawValue)|\(requirement.targetIdentifier)|\(requirement.targetRevision ?? 0)"
    }
}

/// Immutable execution material prepared before a Simple Mode turn starts.
/// It contains stable IDs and sanitized availability only—never tool arguments,
/// connector configuration, credentials, paths, or package locations.
struct YouziTaskExecutionPlan: Equatable, Sendable {
    let taskID: UUID
    let resolvedCapabilities: YouziResolvedTaskCapabilityContext
    let scopedTurn: YouziScopedChatTurnContext
    /// Nil for an interactive task, whose exact task-bound grants are selected
    /// by the evaluator. Automation always carries a non-nil run snapshot;
    /// an empty set therefore means no durable authority, never "all grants".
    let allowedPermissionGrantIDs: Set<UUID>?
    let authorizationsByToolName: [String: YouziTaskToolAuthorizationSnapshot]
    let supplementalAuthorizations: [YouziTaskToolAuthorizationSnapshot]
    let issues: [YouziTaskExecutionPlanningIssue]

    var advertisedToolNames: [String] {
        scopedTurn.advertisedToolNames.sorted()
    }

    func permissionNeeds(
        in document: YouziDomainDocument,
        now: Date = Date(),
        evaluator: YouziExecutionPermissionEvaluator = .init()
    ) -> [YouziTaskPermissionNeed] {
        var needsByID: [String: YouziTaskPermissionNeed] = [:]
        let snapshots = advertisedToolNames.compactMap { authorizationsByToolName[$0] }
            + supplementalAuthorizations
        for snapshot in snapshots {
            guard
                  snapshot.runtime.globallyEnabled,
                  snapshot.runtime.toolEnabled,
                  snapshot.runtime.runtimeAvailable else { continue }
            let grants = allowedPermissionGrantIDs.map { allowedIDs in
                document.permissionGrants.filter { allowedIDs.contains($0.id) }
            } ?? document.permissionGrants
            let evaluation = evaluator.evaluate(
                subject: scopedTurn.subject,
                requirement: snapshot.requirement,
                permissionRecords: document.permissions,
                grants: grants,
                connectionAccounts: document.connectionAccounts,
                connectorBindings: document.connectorBindings,
                runtime: snapshot.runtime,
                now: now
            )
            switch evaluation.outcome {
            case .domainPermissionRequired, .denied:
                let need = permissionNeed(for: snapshot.requirement)
                needsByID[need.id] = need
            case .authorized, .awaitingLowLevelConfirmation, .disabled,
                 .notAdvertised, .accountUnavailable, .bindingUnavailable,
                 .runtimeUnavailable, .malformedRequirement:
                break
            }
        }
        return needsByID.values.sorted { $0.id < $1.id }
    }

    private func permissionNeed(
        for requirement: YouziExecutionPermissionRequirement
    ) -> YouziTaskPermissionNeed {
        switch requirement.kind {
        case .networkAccess:
            return .init(
                requirement: requirement,
                title: "使用网络查询资料",
                detail: "仅在这次任务需要联网查询时使用。"
            )
        case .connectorRead:
            return .init(
                requirement: requirement,
                title: "读取已连接应用",
                detail: "读取你为本任务选择的应用内容。"
            )
        case .connectorWrite:
            return .init(
                requirement: requirement,
                title: "修改已连接应用",
                detail: "仅在任务明确要求时创建或修改内容。"
            )
        case .externalPublish:
            return .init(
                requirement: requirement,
                title: "向外发送或发布",
                detail: "真正发送前，连接器仍会显示操作级确认。"
            )
        case .workspaceRead:
            return .init(
                requirement: requirement,
                title: "读取工作空间",
                detail: "读取本任务工作空间内的资料。"
            )
        case .workspaceWrite:
            return .init(
                requirement: requirement,
                title: "写入工作空间",
                detail: "把任务成果保存到当前工作空间。"
            )
        case .destructiveLocalAction:
            return .init(
                requirement: requirement,
                title: "执行不可撤销的本地操作",
                detail: "执行前仍需单独确认具体操作。"
            )
        case .microphone:
            return .init(
                requirement: requirement,
                title: "使用麦克风",
                detail: "用于本次语音交互。"
            )
        case .saveAudio:
            return .init(
                requirement: requirement,
                title: "保存语音内容",
                detail: "把语音记录保存到本机。"
            )
        }
    }
}

/// Pure composition of the task graph, validated skill instructions, and one
/// sanitized MCP snapshot. It does not mutate grants or execute tools.
struct YouziTaskExecutionCoordinator: Sendable {
    private let resolver = YouziTaskCapabilityResolver()
    private let connectorFacade = YouziConnectorCapabilityFacade()

    func prepare(
        taskID: UUID,
        document: YouziDomainDocument,
        builtInToolNames: [String],
        runtime: YouziMCPRuntimeSnapshot,
        skillInstructionComponents: [UUID: String],
        subject: YouziExecutionPermissionSubject? = nil,
        allowedPermissionGrantIDs: Set<UUID>? = nil
    ) -> YouziTaskExecutionPlan {
        let projection = connectorFacade.project(document: document, runtime: runtime)
        let builtIns = Set(normalizedToolNames(builtInToolNames))

        var liveByConnectorID: [UUID: Set<String>] = [:]
        for application in projection.applications {
            liveByConnectorID[application.connectorID, default: []]
                .formUnion(application.candidateToolNames)
        }
        let resolved = resolver.resolve(
            taskID: taskID,
            in: document,
            input: .init(
                builtInToolNames: builtIns.sorted(),
                liveConnectorToolNames: liveByConnectorID.mapValues { $0.sorted() },
                skillInstructionComponents: skillInstructionComponents
            )
        )

        var issues = resolved.issues.map(YouziTaskExecutionPlanningIssue.capability)
        var snapshots: [String: YouziTaskToolAuthorizationSnapshot] = [:]
        var supplementalAuthorizations: [YouziTaskToolAuthorizationSnapshot] = []

        for name in builtIns where resolved.candidateToolNames.contains(name) {
            let capabilityIdentifier = "builtin.network"
            snapshots[name] = YouziTaskToolAuthorizationSnapshot(
                requirement: .init(
                    kind: .networkAccess,
                    targetIdentifier: capabilityIdentifier,
                    capabilityIdentifier: capabilityIdentifier,
                    toolName: name
                ),
                runtime: .init(
                    toolName: name,
                    capabilityIdentifier: capabilityIdentifier,
                    advertisedForTurn: true,
                    globallyEnabled: true,
                    toolEnabled: true,
                    runtimeAvailable: true,
                    lowLevelApproval: .notRequired
                )
            )
        }

        let resolvedAccountIDs = Set(resolved.connectionAccountIDs)
        let eligibleApplications = projection.applications.filter { application in
            guard let accountID = application.connectionAccountID else { return false }
            return resolvedAccountIDs.contains(accountID)
        }
        var ownersByToolName: [String: [YouziConnectedApplicationCapability]] = [:]
        for application in eligibleApplications {
            for name in application.candidateToolNames where !builtIns.contains(name) {
                ownersByToolName[name, default: []].append(application)
            }
        }

        for name in resolved.candidateToolNames where !builtIns.contains(name) {
            let owners = ownersByToolName[name] ?? []
            guard owners.count == 1 else {
                if owners.count > 1 {
                    issues.append(.ambiguousConnectedApplicationTool(name: name))
                } else {
                    issues.append(.missingAuthorizationMetadata(name: name))
                }
                continue
            }
            let owner = owners[0]
            guard let accountID = owner.connectionAccountID,
                  let revision = owner.bindingRevision,
                  revision > 0 else {
                issues.append(.missingAuthorizationMetadata(name: name))
                continue
            }
            let tool = runtime.tools.first { $0.name == name }
            snapshots[name] = YouziTaskToolAuthorizationSnapshot(
                requirement: .init(
                    kind: connectorPermissionKind(for: name),
                    targetIdentifier: accountID.uuidString.lowercased(),
                    targetRevision: revision,
                    connectionAccountID: accountID,
                    toolName: name
                ),
                runtime: .init(
                    toolName: name,
                    connectionAccountID: accountID,
                    bindingRevision: revision,
                    advertisedForTurn: true,
                    globallyEnabled: runtime.connectorsEnabled,
                    toolEnabled: tool?.isEnabled == true,
                    runtimeAvailable: owner.status == .live,
                    // MCPToolRegistry retains its argument-level confirmation
                    // after this domain gate. This evaluator owns no duplicate
                    // prompt and therefore has no lower-level state to await.
                    lowLevelApproval: .notRequired
                )
            )
        }

        let advertised = Set(resolved.candidateToolNames).intersection(snapshots.keys)
        if let task = document.tasks.first(where: { $0.id == taskID }),
           let workspaceID = task.workspaceID {
            for kind in resolved.requestedPermissionKinds
            where kind == .workspaceRead || kind == .workspaceWrite {
                supplementalAuthorizations.append(
                    YouziTaskToolAuthorizationSnapshot(
                        requirement: .init(
                            kind: kind,
                            targetIdentifier: workspaceID.uuidString.lowercased()
                        ),
                        runtime: .init(
                            advertisedForTurn: true,
                            globallyEnabled: true,
                            toolEnabled: true,
                            runtimeAvailable: true,
                            lowLevelApproval: .notRequired
                        )
                    )
                )
            }
        }
        let scopedSubject = subject ?? .interactiveTask(taskID)
        let runGrantScope: Set<UUID>?
        switch scopedSubject {
        case .interactiveTask:
            runGrantScope = allowedPermissionGrantIDs
        case .automation:
            // Automation may never widen an omitted snapshot to every grant
            // belonging to the same automation revision.
            runGrantScope = allowedPermissionGrantIDs ?? []
        }
        let scopedTurn = YouziScopedChatTurnContext(
            subject: scopedSubject,
            instructionComponent: resolved.promptComponent,
            advertisedToolNames: advertised
        )
        return YouziTaskExecutionPlan(
            taskID: taskID,
            resolvedCapabilities: resolved,
            scopedTurn: scopedTurn,
            allowedPermissionGrantIDs: runGrantScope,
            authorizationsByToolName: snapshots.filter { advertised.contains($0.key) },
            supplementalAuthorizations: supplementalAuthorizations,
            issues: stableIssues(issues)
        )
    }

    private func connectorPermissionKind(for toolName: String) -> YouziPermissionKind {
        let tokens = Set(
            toolName.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        )
        if !tokens.isDisjoint(with: ["publish", "post", "send", "share", "submit"]) {
            return .externalPublish
        }
        if !tokens.isDisjoint(with: [
            "read", "get", "list", "search", "find", "query", "fetch", "view", "lookup",
        ]) {
            return .connectorRead
        }
        // Unknown connector operations default to the stronger write grant.
        return .connectorWrite
    }

    private func normalizedToolNames(_ values: [String]) -> [String] {
        Array(Set(values.filter { !$0.isEmpty })).sorted()
    }

    private func stableIssues(
        _ values: [YouziTaskExecutionPlanningIssue]
    ) -> [YouziTaskExecutionPlanningIssue] {
        var seen = Set<String>()
        return values.sorted { issueKey($0) < issueKey($1) }.filter {
            seen.insert(issueKey($0)).inserted
        }
    }

    private func issueKey(_ issue: YouziTaskExecutionPlanningIssue) -> String {
        switch issue {
        case .capability(let value):
            return "01|\(String(reflecting: value))"
        case .ambiguousConnectedApplicationTool(let name):
            return "02|\(name)"
        case .missingAuthorizationMetadata(let name):
            return "03|\(name)"
        }
    }
}

@MainActor
final class YouziTaskDispatchAuthorizer: YouziToolDispatchAuthorizing, @unchecked Sendable {
    private weak var productModel: YouziProductModel?
    private let plan: YouziTaskExecutionPlan
    private let evaluator: YouziExecutionPermissionEvaluator
    private let now: @Sendable () -> Date

    init(
        productModel: YouziProductModel,
        plan: YouziTaskExecutionPlan,
        evaluator: YouziExecutionPermissionEvaluator = .init(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.productModel = productModel
        self.plan = plan
        self.evaluator = evaluator
        self.now = now
    }

    func authorize(
        _ request: YouziToolDispatchAuthorizationRequest
    ) async -> YouziToolDispatchAuthorizationDecision {
        guard request.subject == plan.scopedTurn.subject,
              plan.scopedTurn.advertisedToolNames.contains(request.toolName),
              let snapshot = plan.authorizationsByToolName[request.toolName]
        else { return .denied(.notAdvertised) }
        guard let productModel else { return .denied(.authorizerUnavailable) }

        // The plan freezes candidate tools and the allowed grant IDs, not the
        // authority records themselves. Re-read durable state immediately
        // before every dispatch so a revocation, expiry, or binding revision
        // change that races the model stream fails closed.
        productModel.refresh()
        guard productModel.lastPersistenceError == nil else {
            return .denied(.runtimeUnavailable)
        }

        let grants = plan.allowedPermissionGrantIDs.map { allowedIDs in
            productModel.permissionGrants.filter { allowedIDs.contains($0.id) }
        } ?? productModel.permissionGrants
        let evaluation = evaluator.evaluate(
            subject: request.subject,
            requirement: snapshot.requirement,
            permissionRecords: productModel.permissionRecords,
            grants: grants,
            connectionAccounts: productModel.connectionAccounts,
            connectorBindings: productModel.connectorBindings,
            runtime: snapshot.runtime,
            now: now()
        )
        switch evaluation.outcome {
        case .authorized(let authorization):
            if case .consumeOnce(let grantID) = authorization.consumptionIntent,
               !productModel.consumePermissionGrant(id: grantID) {
                return .denied(.denied)
            }
            return .authorized
        case .domainPermissionRequired:
            return .denied(.domainPermissionRequired)
        case .awaitingLowLevelConfirmation:
            return .denied(.awaitingLowLevelConfirmation)
        case .denied:
            return .denied(.denied)
        case .disabled:
            return .denied(.disabled)
        case .notAdvertised:
            return .denied(.notAdvertised)
        case .accountUnavailable:
            return .denied(.accountUnavailable)
        case .bindingUnavailable:
            return .denied(.bindingUnavailable)
        case .runtimeUnavailable:
            return .denied(.runtimeUnavailable)
        case .malformedRequirement:
            return .denied(.malformedRequirement)
        }
    }
}
