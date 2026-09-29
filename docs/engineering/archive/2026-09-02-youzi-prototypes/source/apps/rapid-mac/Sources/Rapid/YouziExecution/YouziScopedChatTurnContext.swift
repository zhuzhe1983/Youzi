import Foundation

/// Immutable, verified execution inputs for one Youzi-authored chat turn.
///
/// `advertisedToolNames` is an exact candidate set, not permission authority.
/// The canonical chat loop still intersects it with the registry/global
/// switches and requires a per-dispatch authorizer before execution.
struct YouziScopedChatTurnContext: Equatable, Sendable {
    let subject: YouziExecutionPermissionSubject
    let instructionComponent: String
    let advertisedToolNames: Set<String>

    init(
        subject: YouziExecutionPermissionSubject,
        instructionComponent: String,
        advertisedToolNames: Set<String>
    ) {
        self.subject = subject
        self.instructionComponent = instructionComponent
        self.advertisedToolNames = advertisedToolNames
    }
}

/// Minimal, non-sensitive identity passed to the authorization layer for each
/// dispatch. Tool arguments are deliberately absent.
struct YouziToolDispatchAuthorizationRequest: Equatable, Sendable {
    let subject: YouziExecutionPermissionSubject
    let toolName: String
}

/// Stable reasons a scoped dispatch cannot proceed. These map directly to the
/// WS14 evaluator/recovery states without carrying raw runtime errors.
enum YouziToolDispatchDenial: Equatable, Sendable {
    case authorizerUnavailable
    case domainPermissionRequired
    case awaitingLowLevelConfirmation
    case denied
    case disabled
    case notAdvertised
    case accountUnavailable
    case bindingUnavailable
    case runtimeUnavailable
    case malformedRequirement

    fileprivate var modelFacingMessage: String {
        switch self {
        case .authorizerUnavailable:
            return "Scoped tool authorization is unavailable. Continue without using the tool."
        case .domainPermissionRequired:
            return "Permission is required before this task can use the tool."
        case .awaitingLowLevelConfirmation:
            return "The tool is waiting for user confirmation."
        case .denied:
            return "Permission to use the tool was denied."
        case .disabled:
            return "The tool is disabled for this task."
        case .notAdvertised:
            return "The tool is not available for this task turn."
        case .accountUnavailable:
            return "The selected connected-app account is unavailable."
        case .bindingUnavailable:
            return "The connected-app configuration changed and must be reviewed."
        case .runtimeUnavailable:
            return "The tool runtime is unavailable."
        case .malformedRequirement:
            return "The task's tool permission could not be verified."
        }
    }
}

enum YouziToolDispatchAuthorizationDecision: Equatable, Sendable {
    case authorized
    case denied(YouziToolDispatchDenial)

    func toolResult(toolCallID: String) -> ToolCallResult? {
        guard case let .denied(reason) = self else { return nil }
        return ToolCallResult(
            toolCallID: toolCallID,
            content: reason.modelFacingMessage,
            isError: true,
            failureKind: .toolFailed
        )
    }
}

/// Adapter seam for the WS14 evaluator plus the repository transaction that
/// consumes a once grant. Implementations must return `.authorized` only after
/// every required domain/runtime gate (and any atomic consumption) succeeds.
@MainActor
protocol YouziToolDispatchAuthorizing: AnyObject, Sendable {
    func authorize(
        _ request: YouziToolDispatchAuthorizationRequest
    ) async -> YouziToolDispatchAuthorizationDecision
}

/// One default: scoped execution without its authorizer is denied. Legacy
/// Professional turns do not create this gate and retain the pre-existing
/// registry/browse/MCP approval behavior.
@MainActor
enum YouziToolDispatchAuthorizationGate {
    static func authorize(
        _ request: YouziToolDispatchAuthorizationRequest,
        using authorizer: (any YouziToolDispatchAuthorizing)?
    ) async -> YouziToolDispatchAuthorizationDecision {
        guard let authorizer else { return .denied(.authorizerUnavailable) }
        return await authorizer.authorize(request)
    }
}
