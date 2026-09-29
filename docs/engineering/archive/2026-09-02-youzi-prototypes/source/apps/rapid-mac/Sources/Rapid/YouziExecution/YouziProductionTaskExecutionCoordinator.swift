import Foundation

/// Production composition of the canonical Youzi task graph and the shared
/// assistant turn runner. Scheduled work never constructs another
/// `ChatViewModel`, talks to MCP directly, or reads/writes the conversation
/// JSON beside its owner.
@MainActor
final class YouziProductionTaskExecutionCoordinator: YouziTaskExecutionCoordinating {
    typealias RuntimeSnapshotProvider = @MainActor () -> YouziMCPRuntimeSnapshot
    typealias AliasProvider = @MainActor () -> String?

    private struct ActiveExecution {
        let origin: YouziTaskExecutionOrigin
        let handle: AssistantTurnRunner.Handle
    }

    private let store: YouziDomainStore
    private let productModel: YouziProductModel
    private let chat: ChatViewModel
    private let preparation: YouziCanonicalTaskPreparationService
    private let planner: YouziTaskExecutionCoordinator
    private let artifactSink: any YouziTaskArtifactPersisting
    private let runtimeSnapshot: RuntimeSnapshotProvider
    private let aliasProvider: AliasProvider
    private let now: @Sendable () -> Date
    private var activeExecutions: [UUID: ActiveExecution] = [:]

    init(
        store: YouziDomainStore,
        productModel: YouziProductModel,
        chat: ChatViewModel,
        preparation: YouziCanonicalTaskPreparationService? = nil,
        planner: YouziTaskExecutionCoordinator = .init(),
        artifactSink: (any YouziTaskArtifactPersisting)? = nil,
        runtimeSnapshot: @escaping RuntimeSnapshotProvider,
        aliasProvider: @escaping AliasProvider,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.productModel = productModel
        self.chat = chat
        self.preparation = preparation ?? YouziCanonicalTaskPreparationService(
            store: store,
            productModel: productModel,
            now: now
        )
        self.planner = planner
        self.artifactSink = artifactSink ?? YouziTaskArtifactSink(store: store)
        self.runtimeSnapshot = runtimeSnapshot
        self.aliasProvider = aliasProvider
        self.now = now
    }

    func prepare(_ request: YouziTaskExecutionRequest) async
        -> YouziTaskExecutionPreparation
    {
        let result = preparation.prepare(request)
        guard case .ready(let taskID) = result else { return result }
        guard let plan = executionPlan(taskID: taskID, request: request) else {
            return .unavailable(recoveryCode: .runtimeUnavailable)
        }
        guard plan.issues.isEmpty else {
            return .unavailable(recoveryCode: recoveryCode(for: plan.issues))
        }
        let document: YouziDomainDocument
        do {
            document = try store.load()
        } catch {
            return .unavailable(recoveryCode: .runtimeUnavailable)
        }
        guard plan.permissionNeeds(in: document, now: now()).isEmpty else {
            markTask(
                taskID,
                status: .awaitingConfirmation,
                failureSummary: nil,
                completedAt: nil
            )
            return .awaitingConfirmation(recoveryCode: .permissionRequired)
        }
        return .ready(taskID: taskID)
    }

    func execute(
        taskID: UUID,
        request: YouziTaskExecutionRequest
    ) async -> YouziTaskExecutionOutcome {
        guard activeExecutions[taskID] == nil else {
            return .retryableFailure(recoveryCode: .runtimeUnavailable)
        }
        guard let alias = normalizedAlias(aliasProvider()) else {
            markTask(
                taskID,
                status: .failed,
                failureSummary: "本地模型暂不可用，请稍后重试。",
                completedAt: nil
            )
            return .retryableFailure(recoveryCode: .runtimeUnavailable)
        }
        // Acquire ownership before canonical preparation creates a managed
        // workspace or any runner/tool side effect occurs. A user who already
        // opened this conversation wins; the scheduled attempt retries later
        // without duplicating filesystem or external effects.
        guard let conversationReservation = chat.reserveBackgroundConversation(id: taskID) else {
            markTask(
                taskID,
                status: .failed,
                failureSummary: "任务记录正在使用，请稍后重试。",
                completedAt: nil
            )
            return .retryableFailure(recoveryCode: .runtimeUnavailable)
        }
        defer { chat.releaseBackgroundConversation(conversationReservation) }
        switch preparation.prepare(request) {
        case .ready(let preparedTaskID) where preparedTaskID == taskID:
            break
        case .awaitingConfirmation(let recoveryCode):
            return .awaitingConfirmation(recoveryCode: recoveryCode)
        case .ready, .unavailable:
            return .failed(recoveryCode: .automationRevisionChanged)
        }

        guard let plan = executionPlan(taskID: taskID, request: request) else {
            return .failed(recoveryCode: .runtimeUnavailable)
        }
        guard plan.issues.isEmpty else {
            return .failed(recoveryCode: recoveryCode(for: plan.issues))
        }
        let document: YouziDomainDocument
        do {
            document = try store.load()
        } catch {
            return .retryableFailure(recoveryCode: .runtimeUnavailable)
        }
        guard plan.permissionNeeds(in: document, now: now()).isEmpty else {
            markTask(
                taskID,
                status: .awaitingConfirmation,
                failureSummary: nil,
                completedAt: nil
            )
            return .awaitingConfirmation(recoveryCode: .permissionRequired)
        }
        guard let task = document.tasks.first(where: { $0.id == taskID }),
              task.conversationID == taskID else {
            markTask(
                taskID,
                status: .failed,
                failureSummary: "任务记录不可用，请稍后重试。",
                completedAt: nil
            )
            return .retryableFailure(recoveryCode: .runtimeUnavailable)
        }

        let conversation = canonicalConversation(for: task)
        let definitions = chat.enabledDefinitions.filter {
            plan.scopedTurn.advertisedToolNames.contains($0.function.name)
        }
        let sampling: AssistantTurnRunner.Sampling
        if let configured = chat.sampling {
            sampling = .init(
                toolsEnabled: configured.resolved(toolsEnabled: true),
                toolsDisabled: configured.resolved(toolsEnabled: false)
            )
        } else {
            sampling = .standard
        }
        let authorizer = YouziTaskDispatchAuthorizer(
            productModel: productModel,
            plan: plan,
            now: now
        )
        markTask(taskID, status: .inProgress, failureSummary: nil, completedAt: nil)

        let started = chat.assistantTurnRunner.start(.init(
            conversationID: taskID,
            alias: alias,
            messages: conversation.messages,
            supportsImageInput: ModelBrandStyle.supportsImageInput(forAlias: alias),
            startupHFPath: chat.startupHFPath,
            definitions: definitions,
            sampling: sampling,
            contextWindow: ModelInfoCatalog.info(
                for: alias,
                hfRepo: nil,
                serverContextWindow: chat.sampling?.activeContextWindow
            ).contextWindow,
            globalInstruction: chat.customInstructions.global,
            conversationInstruction: conversation.customInstructions ?? "",
            memoryContext: chat.memoryStore?.formattedForPrompt(),
            executionContext: plan.scopedTurn,
            dispatchAuthorizer: authorizer,
            announcesForVoiceOver: false
        ))
        activeExecutions[taskID] = ActiveExecution(
            origin: request.origin,
            handle: started.handle
        )
        guard let outcome = await chat.assistantTurnRunner.awaitOutcome(started.handle) else {
            clearActiveExecution(taskID: taskID, handle: started.handle)
            markTask(
                taskID,
                status: .failed,
                failureSummary: "任务执行中断，请稍后重试。",
                completedAt: nil
            )
            return .retryableFailure(recoveryCode: .runtimeUnavailable)
        }
        clearActiveExecution(taskID: taskID, handle: started.handle)

        // Persist explicit deliverables before publishing the completed
        // transcript. If artifact ownership or bytes changed, fail closed and
        // leave the prior conversation untouched; retrying cannot duplicate a
        // synthetic message because the sink never writes chat rows.
        if outcome.status == .completed {
            guard let workspaceID = task.workspaceID else {
                markTask(
                    taskID,
                    status: .failed,
                    failureSummary: "任务结果无法关联到工作空间，请稍后重试。",
                    completedAt: nil
                )
                return .retryableFailure(recoveryCode: .runtimeUnavailable)
            }
            do {
                _ = try artifactSink.persist(.init(
                    taskID: taskID,
                    conversationID: outcome.conversationID,
                    workspaceID: workspaceID,
                    projectID: task.projectID,
                    artifacts: outcome.artifacts
                ))
                productModel.refresh()
            } catch {
                markTask(
                    taskID,
                    status: .failed,
                    failureSummary: "任务结果保存失败，请稍后重试。",
                    completedAt: nil
                )
                return .retryableFailure(recoveryCode: .runtimeUnavailable)
            }
        }

        let persisted = ChatConversation(
            id: conversation.id,
            title: conversation.title,
            messages: outcome.messages,
            branches: conversation.branches,
            activeLeafID: outcome.messages.last?.id,
            branchChoices: conversation.branchChoices,
            createdAt: conversation.createdAt,
            updatedAt: now(),
            isPinned: conversation.isPinned,
            isArchived: conversation.isArchived,
            hasCustomTitle: conversation.hasCustomTitle,
            hasGeneratedTitle: conversation.hasGeneratedTitle,
            customInstructions: conversation.customInstructions,
            folderID: conversation.folderID
        )
        guard chat.upsertBackgroundConversation(persisted) != nil else {
            markTask(
                taskID,
                status: .failed,
                failureSummary: "任务记录正在使用，请稍后重试。",
                completedAt: nil
            )
            return .retryableFailure(recoveryCode: .runtimeUnavailable)
        }

        switch outcome.status {
        case .completed:
            markTask(
                taskID,
                status: .completed,
                failureSummary: nil,
                completedAt: now()
            )
            return .completed(summary: outcome.summary.flatMap(YouziTaskExecutionSummary.init))
        case .cancelled:
            markTask(
                taskID,
                status: .failed,
                failureSummary: "任务已取消。",
                completedAt: nil
            )
            return .cancelled
        case .failed, .modelUnavailable:
            markTask(
                taskID,
                status: .failed,
                failureSummary: "本次任务未完成，可以稍后重试。",
                completedAt: nil
            )
            return .retryableFailure(recoveryCode: .runtimeUnavailable)
        }
    }

    func cancel(taskID: UUID, origin: YouziTaskExecutionOrigin) async {
        guard let active = activeExecutions[taskID], active.origin == origin else { return }
        chat.assistantTurnRunner.cancel(active.handle)
    }

    private func executionPlan(
        taskID: UUID,
        request: YouziTaskExecutionRequest
    ) -> YouziTaskExecutionPlan? {
        let document: YouziDomainDocument
        do {
            document = try store.load()
        } catch {
            return nil
        }
        let subject: YouziExecutionPermissionSubject
        let allowedGrantIDs: Set<UUID>?
        switch request.origin {
        case .interactive:
            subject = .interactiveTask(taskID)
            allowedGrantIDs = nil
        case let .automation(automationID, revision, _):
            subject = .automation(id: automationID, revision: revision)
            allowedGrantIDs = Set(request.permissionGrantIDs)
        }
        return planner.prepare(
            taskID: taskID,
            document: document,
            builtInToolNames: chat.builtinDefinitions.map(\.function.name),
            runtime: runtimeSnapshot(),
            skillInstructionComponents: productModel.skillInstructionComponents,
            subject: subject,
            allowedPermissionGrantIDs: allowedGrantIDs
        )
    }

    private func canonicalConversation(for task: YouziTask) -> ChatConversation {
        if let existing = chat.conversationSnapshot(id: task.id) {
            return existing
        }
        return ChatConversation(
            id: task.id,
            title: task.title,
            messages: [
                ChatMessage(
                    role: .user,
                    content: task.request,
                    createdAt: task.createdAt
                ),
            ],
            createdAt: task.createdAt,
            updatedAt: task.updatedAt
        )
    }

    private func clearActiveExecution(
        taskID: UUID,
        handle: AssistantTurnRunner.Handle
    ) {
        guard activeExecutions[taskID]?.handle == handle else { return }
        activeExecutions.removeValue(forKey: taskID)
    }

    private func markTask(
        _ taskID: UUID,
        status: YouziTaskStatus,
        failureSummary: String?,
        completedAt: Date?
    ) {
        let date = now()
        do {
            _ = try store.update { document in
                guard let index = document.tasks.firstIndex(where: { $0.id == taskID }) else {
                    return
                }
                document.tasks[index].status = status
                document.tasks[index].failureSummary = failureSummary
                document.tasks[index].updatedAt = date
                document.tasks[index].completedAt = completedAt
            }
            productModel.refresh()
        } catch {
            productModel.refresh()
        }
    }

    private func normalizedAlias(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private func recoveryCode(
        for issues: [YouziTaskExecutionPlanningIssue]
    ) -> YouziRecoveryCode {
        for issue in issues {
            switch issue {
            case .capability(.skillInstructionsUnavailable):
                return .packageInvalid
            case .capability(.connectionAccountNotConnected),
                 .capability(.skillConnectorDependencyUnavailable),
                 .capability(.connectorToolUnavailable),
                 .ambiguousConnectedApplicationTool,
                 .missingAuthorizationMetadata:
                return .connectorUnavailable
            case .capability:
                continue
            }
        }
        return .runtimeUnavailable
    }
}
