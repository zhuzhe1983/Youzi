import Foundation

/// Creates or recovers the canonical task identity for an interactive or
/// scheduled execution. Automation preparation is idempotent by run UUID: the
/// task and the run backlink are committed in the same domain transaction, so
/// a crash between preparation and scheduler settlement cannot create a
/// second task on retry.
@MainActor
final class YouziCanonicalTaskPreparationService {
    private enum ValidationFailure: Error {
        case unavailable(YouziRecoveryCode)
        case awaiting(YouziRecoveryCode)
    }

    private let store: YouziDomainStore
    private let productModel: YouziProductModel
    private let lifecycle: YouziLifecycleRepository
    private let idGenerator: @Sendable () -> UUID
    private let now: @Sendable () -> Date

    init(
        store: YouziDomainStore,
        productModel: YouziProductModel,
        lifecycle: YouziLifecycleRepository? = nil,
        idGenerator: @escaping @Sendable () -> UUID = UUID.init,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.productModel = productModel
        self.lifecycle = lifecycle ?? YouziLifecycleRepository(store: store)
        self.idGenerator = idGenerator
        self.now = now
    }

    func prepare(_ request: YouziTaskExecutionRequest) -> YouziTaskExecutionPreparation {
        do {
            let taskID: UUID
            switch request.input {
            case .existingTask(let existingTaskID):
                let document = try store.load()
                guard document.tasks.contains(where: { $0.id == existingTaskID }) else {
                    throw ValidationFailure.unavailable(.runtimeUnavailable)
                }
                guard case .interactive = request.origin else {
                    throw ValidationFailure.unavailable(.automationRevisionChanged)
                }
                taskID = existingTaskID

            case .automationAction(let action):
                taskID = try ensureAutomationTask(request: request, action: action)
            }

            // Workspace creation is deliberately after the metadata
            // transaction because it has a filesystem side effect. Retrying a
            // partially completed prepare reuses the backlink above and this
            // lifecycle API reuses (or safely creates) the workspace.
            _ = try lifecycle.ensureManagedWorkspace(forTask: taskID, at: now())
            productModel.refresh()
            guard productModel.lastPersistenceError == nil else {
                return .unavailable(recoveryCode: .runtimeUnavailable)
            }
            return .ready(taskID: taskID)
        } catch ValidationFailure.awaiting(let recovery) {
            productModel.refresh()
            return .awaitingConfirmation(recoveryCode: recovery)
        } catch ValidationFailure.unavailable(let recovery) {
            productModel.refresh()
            return .unavailable(recoveryCode: recovery)
        } catch {
            productModel.refresh()
            return .unavailable(recoveryCode: .runtimeUnavailable)
        }
    }

    private func ensureAutomationTask(
        request: YouziTaskExecutionRequest,
        action: YouziAutomationAction
    ) throws -> UUID {
        guard case let .automation(automationID, revision, runID) = request.origin else {
            throw ValidationFailure.unavailable(.automationRevisionChanged)
        }
        let frozenGrantIDs = request.permissionGrantIDs.sorted(by: uuidOrder)
        let date = now()

        let document = try store.update { document in
            guard let automation = document.automations.first(where: {
                $0.id == automationID && $0.revision == revision
            }), automation.action == action else {
                throw ValidationFailure.unavailable(.automationRevisionChanged)
            }
            guard automation.state == .active, automation.confirmedAt != nil else {
                throw ValidationFailure.awaiting(.permissionRequired)
            }
            guard let runIndex = document.automationRuns.firstIndex(where: { $0.id == runID }) else {
                throw ValidationFailure.unavailable(.runtimeUnavailable)
            }
            let run = document.automationRuns[runIndex]
            guard run.automationID == automationID,
                  run.automationRevision == revision,
                  run.permissionGrantIDs.sorted(by: uuidOrder) == frozenGrantIDs,
                  automation.permissionGrantIDs.sorted(by: uuidOrder) == frozenGrantIDs else {
                throw ValidationFailure.unavailable(.automationRevisionChanged)
            }

            if let existingTaskID = run.taskID {
                guard let task = document.tasks.first(where: { $0.id == existingTaskID }),
                      task.conversationID == existingTaskID,
                      task.request == action.request,
                      task.projectID == action.projectID,
                      (action.workspaceID == nil || task.workspaceID == action.workspaceID),
                      task.helperID == action.helperID,
                      task.skillIDs.sorted(by: uuidOrder) == action.skillIDs.sorted(by: uuidOrder),
                      task.connectionAccountIDs.sorted(by: uuidOrder)
                        == action.connectionAccountIDs.sorted(by: uuidOrder) else {
                    throw ValidationFailure.unavailable(.automationRevisionChanged)
                }
                return
            }

            guard let newTaskID = allocateTaskID(in: document) else {
                throw ValidationFailure.unavailable(.runtimeUnavailable)
            }
            let task = YouziTask(
                id: newTaskID,
                title: automation.name,
                request: action.request,
                conversationID: newTaskID,
                workspaceID: action.workspaceID,
                projectID: action.projectID,
                helperID: action.helperID,
                helperSelectionIntent: .explicit,
                skillIDs: action.skillIDs.sorted(by: uuidOrder),
                skillSelectionIntent: .explicit,
                connectionAccountIDs: action.connectionAccountIDs.sorted(by: uuidOrder),
                connectionAccountSelectionIntent: .explicit,
                status: .draft,
                createdAt: date,
                updatedAt: date
            )
            document.upsert(task)
            document.automationRuns[runIndex].taskID = task.id
        }

        guard let run = document.automationRuns.first(where: { $0.id == runID }),
              let persistedTaskID = run.taskID else {
            throw ValidationFailure.unavailable(.runtimeUnavailable)
        }
        return persistedTaskID
    }

    private func uuidOrder(_ lhs: UUID, _ rhs: UUID) -> Bool {
        lhs.uuidString.lowercased() < rhs.uuidString.lowercased()
    }

    private func allocateTaskID(in document: YouziDomainDocument) -> UUID? {
        for _ in 0..<16 {
            let candidate = idGenerator()
            if !document.tasks.contains(where: { $0.id == candidate }) {
                return candidate
            }
        }
        return nil
    }
}
