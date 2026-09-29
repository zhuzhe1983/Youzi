import AppKit
import Foundation

/// The canonical local-assistant turn engine shared by foreground chat and
/// headless task execution. Every start owns an independent task and transcript
/// snapshot; cancelling one handle never cancels another turn.
@MainActor
final class AssistantTurnRunner {
    struct Handle: Hashable, Sendable {
        fileprivate let id: UUID
    }

    struct StartedTurn {
        let handle: Handle
        let initialMessages: [ChatMessage]
        let events: AsyncStream<Event>
    }

    struct Sampling: Equatable, Sendable {
        let toolsEnabled: ResolvedSampling
        let toolsDisabled: ResolvedSampling

        static let standard = Sampling(
            toolsEnabled: ResolvedSampling(
                temperature: 0.7,
                topP: 0.95,
                maxTokens: 4_096,
                repetitionPenalty: 1.1,
                enableThinking: false
            ),
            toolsDisabled: ResolvedSampling(
                temperature: 0.7,
                topP: 0.95,
                maxTokens: 4_096,
                repetitionPenalty: 1.1,
                enableThinking: false
            )
        )

        func resolved(toolsEnabled: Bool) -> ResolvedSampling {
            toolsEnabled ? self.toolsEnabled : toolsDisabled
        }
    }

    struct Request {
        let conversationID: UUID
        let alias: String
        /// Canonical path ending at the user turn. The runner owns every
        /// assistant/tool row appended after this immutable snapshot.
        let messages: [ChatMessage]
        let supportsImageInput: Bool
        let imageMessageID: UUID?
        let startupHFPath: String?
        let definitions: [ToolDefinition]
        let sampling: Sampling
        let contextWindow: Int?
        let globalInstruction: String
        let conversationInstruction: String
        let memoryContext: String?
        let executionContext: YouziScopedChatTurnContext?
        let dispatchAuthorizer: (any YouziToolDispatchAuthorizing)?
        /// Foreground chat opts in. Headless automation leaves this false so
        /// a background run never speaks over the user.
        let announcesForVoiceOver: Bool

        init(
            conversationID: UUID,
            alias: String,
            messages: [ChatMessage],
            supportsImageInput: Bool,
            imageMessageID: UUID? = nil,
            startupHFPath: String? = nil,
            definitions: [ToolDefinition],
            sampling: Sampling = .standard,
            contextWindow: Int? = nil,
            globalInstruction: String = "",
            conversationInstruction: String = "",
            memoryContext: String? = nil,
            executionContext: YouziScopedChatTurnContext? = nil,
            dispatchAuthorizer: (any YouziToolDispatchAuthorizing)? = nil,
            announcesForVoiceOver: Bool = false
        ) {
            self.conversationID = conversationID
            self.alias = alias
            self.messages = messages
            self.supportsImageInput = supportsImageInput
            self.imageMessageID = imageMessageID
            self.startupHFPath = startupHFPath
            self.definitions = definitions
            self.sampling = sampling
            self.contextWindow = contextWindow
            self.globalInstruction = globalInstruction
            self.conversationInstruction = conversationInstruction
            self.memoryContext = memoryContext
            self.executionContext = executionContext
            self.dispatchAuthorizer = dispatchAuthorizer
            self.announcesForVoiceOver = announcesForVoiceOver
        }
    }

    enum Phase: Equatable, Sendable {
        case started
        case startingModel
        case streaming(round: Int)
        case executingTool(name: String, callID: String)
        case synthesizing
        case completed
        case cancelled
        case failed(FailureDiagnosis.Kind)
    }

    struct Event {
        let handle: Handle
        let conversationID: UUID
        let phase: Phase
        /// Full canonical path snapshot. Consumers replace their projection;
        /// they never reconstruct tool-round ordering from string callbacks.
        let messages: [ChatMessage]
    }

    enum CompletionStatus: Equatable, Sendable {
        case completed
        case cancelled
        case failed
        case modelUnavailable
    }

    typealias Artifact = AssistantTurnArtifact

    struct Outcome {
        let handle: Handle
        let conversationID: UUID
        let status: CompletionStatus
        let messages: [ChatMessage]
        let summary: String?
        let artifacts: [Artifact]
        let failureKind: FailureDiagnosis.Kind?
        let usedImageInput: Bool
        let executedToolCount: Int
    }

    @MainActor
    private final class RunState {
        var messages: [ChatMessage]
        var currentPlaceholder: Int
        var usedImageInput = false
        var executedToolCount = 0
        var groundingSources: [ChatViewModel.GroundingSource] = []
        var artifacts: [Artifact] = []
        var completionStatus: CompletionStatus = .completed
        var failureKind: FailureDiagnosis.Kind?

        init(messages: [ChatMessage]) {
            var linked = messages
            var placeholder = ChatMessage(role: .assistant, status: .streaming)
            placeholder.parentID = linked.last?.id
            linked.append(placeholder)
            self.messages = linked
            self.currentPlaceholder = linked.count - 1
        }

        func append(_ message: ChatMessage) -> Int {
            var linked = message
            if linked.parentID == nil { linked.parentID = messages.last?.id }
            messages.append(linked)
            return messages.count - 1
        }

        func current() -> ChatMessage? {
            guard messages.indices.contains(currentPlaceholder) else { return nil }
            return messages[currentPlaceholder]
        }

        func updateCurrent(_ message: ChatMessage) {
            guard messages.indices.contains(currentPlaceholder) else { return }
            messages[currentPlaceholder] = message
        }

        func applyImageDelivery(_ event: ChatViewModel.ImageDeliveryEvent, id: UUID?) {
            ChatViewModel.applyImageDeliveryEvent(in: &messages, messageID: id, event: event)
        }
    }

    private final class Session {
        let continuation: AsyncStream<Event>.Continuation
        let events: AsyncStream<Event>
        var task: Task<Outcome, Never>!

        init() {
            var captured: AsyncStream<Event>.Continuation?
            events = AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
                captured = continuation
            }
            continuation = captured!
        }
    }

    private let clientTemplate: ChatStreamClient
    private let tools: any ToolRegistry
    private weak var server: ServerManager?
    private let maxToolExecutions: Int
    private var sessions: [Handle: Session] = [:]

    init(
        client: ChatStreamClient = ChatStreamClient(),
        tools: any ToolRegistry,
        server: ServerManager? = nil,
        maxToolExecutions: Int = 3
    ) {
        self.clientTemplate = client
        self.tools = tools
        self.server = server
        self.maxToolExecutions = max(1, maxToolExecutions)
    }

    func start(_ request: Request) -> StartedTurn {
        let handle = Handle(id: UUID())
        let state = RunState(messages: request.messages)
        let session = Session()
        sessions[handle] = session
        session.continuation.yield(Event(
            handle: handle,
            conversationID: request.conversationID,
            phase: .started,
            messages: state.messages
        ))
        session.task = Task { [weak self, weak session] in
            guard let self else {
                return Outcome(
                    handle: handle,
                    conversationID: request.conversationID,
                    status: .cancelled,
                    messages: state.messages,
                    summary: nil,
                    artifacts: [],
                    failureKind: nil,
                    usedImageInput: false,
                    executedToolCount: 0
                )
            }
            let outcome = await self.run(
                handle: handle,
                request: request,
                state: state,
                continuation: session?.continuation
            )
            session?.continuation.finish()
            return outcome
        }
        return StartedTurn(
            handle: handle,
            initialMessages: state.messages,
            events: session.events
        )
    }

    func awaitOutcome(_ handle: Handle) async -> Outcome? {
        guard let session = sessions[handle] else { return nil }
        let outcome = await session.task.value
        sessions.removeValue(forKey: handle)
        return outcome
    }

    func cancel(_ handle: Handle) {
        sessions[handle]?.task.cancel()
    }

    func isRunning(_ handle: Handle) -> Bool {
        sessions[handle] != nil && sessions[handle]?.task.isCancelled == false
    }

    private func emit(
        _ phase: Phase,
        handle: Handle,
        request: Request,
        state: RunState,
        continuation: AsyncStream<Event>.Continuation?
    ) {
        continuation?.yield(Event(
            handle: handle,
            conversationID: request.conversationID,
            phase: phase,
            messages: state.messages
        ))
    }

    private func run(
        handle: Handle,
        request: Request,
        state: RunState,
        continuation: AsyncStream<Event>.Continuation?
    ) async -> Outcome {
        emit(.startingModel, handle: handle, request: request, state: state, continuation: continuation)
        if let server {
            let ready = await server.ensureServing(
                alias: request.alias,
                hfPath: request.startupHFPath,
                estimatedMemoryGB: nil,
                replacementGroup: .assistant
            )
            if Task.isCancelled {
                finishCancellation(state, imageMessageID: request.imageMessageID)
                emit(.cancelled, handle: handle, request: request, state: state, continuation: continuation)
                return makeOutcome(handle: handle, request: request, state: state)
            }
            guard ready else {
                finishStartupFailure(state, alias: request.alias, imageMessageID: request.imageMessageID)
                self.emit(
                    .failed(.modelLoadFailed), handle: handle, request: request,
                    state: state, continuation: continuation
                )
                return makeOutcome(handle: handle, request: request, state: state)
            }
        }
        if Task.isCancelled {
            finishCancellation(state, imageMessageID: request.imageMessageID)
            emit(.cancelled, handle: handle, request: request, state: state, continuation: continuation)
            return makeOutcome(handle: handle, request: request, state: state)
        }

        var client = clientTemplate
        if let server, server.activePort != 0 {
            client.baseURL = ChatStreamClient.loopbackURL(port: server.activePort)
        }
        let bearer = server?.activeBearer
        await runToolLoop(
            handle: handle,
            request: request,
            state: state,
            client: client,
            bearer: bearer,
            continuation: continuation
        )
        let finalPhase: Phase
        switch state.completionStatus {
        case .completed: finalPhase = .completed
        case .cancelled: finalPhase = .cancelled
        case .failed, .modelUnavailable:
            finalPhase = .failed(state.failureKind ?? .requestFailed)
        }
        emit(finalPhase, handle: handle, request: request, state: state, continuation: continuation)
        return makeOutcome(handle: handle, request: request, state: state)
    }

    private func makeOutcome(
        handle: Handle,
        request: Request,
        state: RunState
    ) -> Outcome {
        let assistantText = state.messages.reversed().first(where: {
            $0.role == .assistant && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })?.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = assistantText.map { String($0.prefix(1_200)) }
        var seenLocations = Set<String>()
        let sources = state.groundingSources.compactMap { source -> Artifact? in
            guard seenLocations.insert(source.url).inserted else { return nil }
            return Artifact(
                kind: .source,
                stableKey: source.url,
                title: source.title,
                location: source.url
            )
        }
        return Outcome(
            handle: handle,
            conversationID: request.conversationID,
            status: state.completionStatus,
            messages: state.messages,
            summary: summary,
            artifacts: state.artifacts + sources,
            failureKind: state.failureKind,
            usedImageInput: state.usedImageInput,
            executedToolCount: state.executedToolCount
        )
    }

    private enum StreamOutcome {
        case terminal
        case toolCallsPending([ToolCall])
    }

    private func runToolLoop(
        handle: Handle,
        request: Request,
        state: RunState,
        client: ChatStreamClient,
        bearer: String?,
        continuation: AsyncStream<Event>.Continuation?
    ) async {
        var toolExecutionsLeft = maxToolExecutions
        let toolExecutor = NativeToolCallExecutor(registry: tools)
        var isFinalSynthesisRound = false
        var groundingCorrectionUsed = false
        var forceGroundingCorrection = false
        var draftBeforeCorrection: String?
        var round = 0

        while toolExecutionsLeft > 0 || isFinalSynthesisRound {
            round += 1
            if Task.isCancelled {
                finishCancellation(state, imageMessageID: request.imageMessageID)
                return
            }
            var history = Array(state.messages.prefix(state.currentPlaceholder))
            history = ChatViewModel.filterEmptyAssistantsForWire(history)
            history = ChatViewModel.filterUnknownRolesForWire(history)
            let definitions = isFinalSynthesisRound ? [] : ChatViewModel.wireDefinitions(
                forAlias: request.alias,
                enabled: request.definitions
            )
            let ambientPreamble = !definitions.isEmpty
                && ChatViewModel.carriesToolResultForThisTurn(history)
                ? ChatViewModel.toolGuidancePreamble
                : nil
            history = ChatViewModel.addingInstructionLayers(
                to: history,
                ambientPreamble: ambientPreamble,
                dateContext: ChatViewModel.currentDateTimeContext(),
                memoryContext: request.memoryContext,
                global: request.globalInstruction,
                conversation: request.conversationInstruction,
                scopedExecution: request.executionContext?.instructionComponent
            )
            history = ChatViewModel.trimMessagesForContextWindow(
                history,
                contextWindow: request.contextWindow
            )
            if let ambientPreamble,
               !ChatViewModel.carriesToolResultForThisTurn(history) {
                history = ChatViewModel.removingLeadingSystemComponent(
                    ambientPreamble,
                    from: history
                )
            }
            if isFinalSynthesisRound {
                history = ChatViewModel.addingToolBudgetSynthesisPreamble(to: history)
            }
            if forceGroundingCorrection {
                history = ChatViewModel.addingGroundingCorrectionPreamble(to: history)
            }
            let resolved = request.sampling.resolved(toolsEnabled: !definitions.isEmpty)
            let streamRequest = ChatStreamClient.Request(
                alias: request.alias,
                messages: history,
                temperature: resolved.temperature,
                topP: resolved.topP,
                maxTokens: resolved.maxTokens,
                repetitionPenalty: resolved.repetitionPenalty,
                tools: definitions.isEmpty ? nil : definitions,
                enableThinking: resolved.enableThinking,
                supportsImageInput: request.supportsImageInput
            )
            state.usedImageInput = state.usedImageInput || streamRequest.imageMessageID != nil
            emit(
                isFinalSynthesisRound ? .synthesizing : .streaming(round: round),
                handle: handle,
                request: request,
                state: state,
                continuation: continuation
            )
            let outcome = await runOneStream(
                handle: handle,
                request: request,
                state: state,
                streamRequest: streamRequest,
                client: client,
                bearer: bearer,
                continuation: continuation
            )
            switch outcome {
            case .terminal:
                if let original = draftBeforeCorrection {
                    draftBeforeCorrection = nil
                    let corrected = state.current()
                    let correctedText = (corrected?.content ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let correctionUsable = !Task.isCancelled
                        && !correctedText.isEmpty
                        && corrected?.status != .failed
                    if !correctionUsable, var restored = state.current() {
                        restored.content = original
                        restored.status = .complete
                        restored.errorMessage = nil
                        restored.failureKind = nil
                        state.updateCurrent(restored)
                        state.completionStatus = .completed
                        state.failureKind = nil
                    }
                    appendGroundingSources(state)
                    return
                }
                if !groundingCorrectionUsed,
                   !Task.isCancelled,
                   ChatViewModel.carriesSuccessfulToolResultForThisTurn(
                       Array(state.messages.prefix(state.currentPlaceholder))
                   ),
                   let produced = state.current()?.content,
                   ChatViewModel.looksLikeUngroundedRefusal(produced),
                   !ChatViewModel.answerReliesOnEvidence(produced) {
                    groundingCorrectionUsed = true
                    forceGroundingCorrection = true
                    isFinalSynthesisRound = true
                    draftBeforeCorrection = produced
                    if var staged = state.current() {
                        staged.content = ""
                        staged.toolCalls = nil
                        staged.status = .streaming
                        state.updateCurrent(staged)
                    }
                    continue
                }
                appendGroundingSources(state)
                return

            case .toolCallsPending(let calls):
                if Task.isCancelled {
                    finishCancellation(state, imageMessageID: request.imageMessageID)
                    return
                }
                if isFinalSynthesisRound {
                    failWithToolRoundCap(state)
                    return
                }
                var results: [ToolCallResult] = []
                for call in calls {
                    if Task.isCancelled {
                        finishCancellation(state, imageMessageID: request.imageMessageID)
                        return
                    }
                    guard toolExecutionsLeft > 0 else {
                        results.append(ToolCallResult(
                            toolCallID: call.id,
                            content: "Tool budget exhausted. Answer using the results already available.",
                            isError: true,
                            failureKind: .toolFailed
                        ))
                        continue
                    }
                    toolExecutionsLeft -= 1
                    state.executedToolCount += 1
                    emit(
                        .executingTool(name: call.function.name, callID: call.id),
                        handle: handle,
                        request: request,
                        state: state,
                        continuation: continuation
                    )
                    let authorization: (@MainActor () async -> YouziToolDispatchAuthorizationDecision)?
                    if let context = request.executionContext {
                        let dispatchRequest = YouziToolDispatchAuthorizationRequest(
                            subject: context.subject,
                            toolName: call.function.name
                        )
                        authorization = {
                            await YouziToolDispatchAuthorizationGate.authorize(
                                dispatchRequest,
                                using: request.dispatchAuthorizer
                            )
                        }
                    } else {
                        authorization = nil
                    }
                    let result = await toolExecutor.execute(
                        call,
                        advertised: definitions,
                        authorizingWith: authorization
                    )
                    results.append(result)
                    if call.function.name == "web_search" {
                        state.groundingSources.append(
                            contentsOf: ChatViewModel.groundingSources(from: result.content)
                        )
                    }
                    if Task.isCancelled {
                        finishCancellation(state, imageMessageID: request.imageMessageID)
                        return
                    }
                }
                for result in results {
                    let failureKind = result.failureKind ?? FailureDiagnoser.toolFailureKind(
                        toolName: calls.first(where: { $0.id == result.toolCallID })?.function.name ?? "",
                        content: result.content,
                        isError: result.isError
                    )
                    if !result.isError, failureKind == nil {
                        state.artifacts.append(contentsOf: result.artifacts)
                    }
                    _ = state.append(ChatMessage(
                        role: .tool,
                        content: result.content,
                        status: (result.isError || failureKind != nil) ? .failed : .complete,
                        errorMessage: failureKind.map { FailureDiagnoser.diagnosis(for: $0).message },
                        failureKind: failureKind,
                        toolCallID: result.toolCallID
                    ))
                }
                state.currentPlaceholder = state.append(
                    ChatMessage(role: .assistant, status: .streaming)
                )
                emit(
                    .streaming(round: round + 1), handle: handle, request: request,
                    state: state, continuation: continuation
                )
                if toolExecutionsLeft == 0 { isFinalSynthesisRound = true }
            }
        }
    }

    private func runOneStream(
        handle: Handle,
        request: Request,
        state: RunState,
        streamRequest: ChatStreamClient.Request,
        client: ChatStreamClient,
        bearer: String?,
        continuation: AsyncStream<Event>.Continuation?
    ) async -> StreamOutcome {
        var current = state.current() ?? ChatMessage(role: .assistant, status: .streaming)
        var capturedCalls: [ToolCall] = []
        var capturedFinish: String?
        let streamStart = client.now()
        let voiceOverActive = request.announcesForVoiceOver
            && NSWorkspace.shared.isVoiceOverEnabled
        var announcer = AssistantStreamAnnouncer()
        var capturedPromptTokens: Int?
        var capturedCompletionTokens: Int?
        var firstTokenAt: ContinuousClock.Instant?
        do {
            try await client.send(streamRequest, bearerToken: bearer) { event in
                switch event {
                case .firstToken(let at):
                    state.applyImageDelivery(.accepted, id: streamRequest.imageMessageID)
                    if firstTokenAt == nil { firstTokenAt = at }
                case .content(let delta):
                    current.content += delta
                    if voiceOverActive {
                        if let cue = announcer.firstTokenCue(fullContent: current.content) {
                            VoiceOverAnnouncer.announce(cue)
                        }
                        if let chunk = announcer.onDelta(fullContent: current.content, now: Date()) {
                            VoiceOverAnnouncer.announce(chunk)
                        }
                    }
                case .reasoning(let delta):
                    current.reasoning += delta
                case .toolCalls(let calls):
                    capturedCalls = calls
                    current.toolCalls = calls
                case .usage(let prompt, let completion):
                    capturedPromptTokens = prompt
                    capturedCompletionTokens = completion
                case .finished(let reason):
                    state.applyImageDelivery(.accepted, id: streamRequest.imageMessageID)
                    capturedFinish = reason
                    current.status = .complete
                    switch ChatViewModel.classifyTerminal(
                        proseContent: current.content,
                        reasoningContent: current.reasoning,
                        toolCalls: current.toolCalls,
                        finishReason: reason,
                        thinkingEnabled: streamRequest.enableThinking
                    ) {
                    case .realCompletion:
                        current.contentTruncated = ChatMessage.shouldFlagContentTruncated(
                            content: current.content,
                            reasoning: current.reasoning,
                            finishReason: reason
                        )
                        current.toolNotCalledFlagged = ChatMessage.shouldFlagToolNotCalled(
                            userPrompt: ChatViewModel.lastUserPromptBefore(
                                messages: state.messages,
                                placeholderIndex: state.currentPlaceholder
                            ),
                            assistantContent: current.content,
                            toolCalls: current.toolCalls,
                            finishReason: reason,
                            toolsRequested: !(streamRequest.tools?.isEmpty ?? true),
                            toolSucceededThisTurn: ChatViewModel.turnHadSuccessfulTool(
                                messages: state.messages,
                                placeholderIndex: state.currentPlaceholder
                            )
                        )
                        current.toolCallArtifactSuppressed = ChatMessage.shouldSuppressToolCallArtifact(
                            content: current.content,
                            toolCalls: current.toolCalls,
                            finishReason: reason,
                            toolsRequested: !(streamRequest.tools?.isEmpty ?? true)
                        )
                    case .reasoningOnlyTruncated(let hint):
                        current.errorMessage = hint
                        current.reasoningTruncated = true
                    case .emptyTurnFailure(let message):
                        current.errorMessage = message
                        current.status = .failed
                        current.failureKind = .requestFailed
                    }
                    if voiceOverActive, reason != "tool_calls" {
                        let terminal: AssistantStreamAnnouncer.Terminal =
                            current.status == .failed ? .failed : .complete
                        if let cue = announcer.onTerminal(terminal, errorMessage: current.errorMessage) {
                            VoiceOverAnnouncer.announce(cue)
                        }
                    }
                }
                state.updateCurrent(current)
                self.emit(
                    .streaming(round: 0), handle: handle, request: request,
                    state: state, continuation: continuation
                )
            }
        } catch where ChatViewModel.isCancellation(error) {
            state.applyImageDelivery(.abandoned, id: streamRequest.imageMessageID)
            ChatViewModel.finaliseCancellation(message: &current)
            state.updateCurrent(current)
            state.completionStatus = .cancelled
            state.failureKind = nil
            if voiceOverActive, let cue = announcer.onTerminal(.cancelled, errorMessage: nil) {
                VoiceOverAnnouncer.announce(cue)
            }
            return .terminal
        } catch {
            let imageRejection = streamRequest.imageMessageID == nil
                ? nil
                : (error as? ChatStreamError)?.attachmentFailureMessage
            state.applyImageDelivery(
                imageRejection == nil ? .transientFailure : .terminalRejection,
                id: streamRequest.imageMessageID
            )
            current.status = .failed
            let kind = FailureDiagnoser.chatFailureKind(error: error)
            let actionable = imageRejection ?? FailureDiagnoser.diagnosis(
                for: kind,
                modelAlias: streamRequest.alias
            ).message
            current.errorMessage = actionable
            current.failureKind = kind
            state.updateCurrent(current)
            state.completionStatus = .failed
            state.failureKind = kind
            if voiceOverActive, let cue = announcer.onTerminal(.failed, errorMessage: actionable) {
                VoiceOverAnnouncer.announce(cue)
            }
            return .terminal
        }
        if current.status == .complete && !current.content.isEmpty {
            let elapsed = streamStart.duration(to: client.now()).seconds
            current.stats = MessageStats(
                elapsedSeconds: elapsed,
                charCount: current.content.count,
                promptTokens: capturedPromptTokens,
                completionTokens: capturedCompletionTokens,
                timeToFirstTokenSeconds: firstTokenAt.map {
                    streamStart.duration(to: $0).seconds
                },
                reasoningEmitted: !current.reasoning.isEmpty
            )
            state.updateCurrent(current)
        }
        if current.status == .failed {
            state.completionStatus = .failed
            state.failureKind = current.failureKind ?? .requestFailed
        }
        if capturedFinish == "tool_calls" && !capturedCalls.isEmpty {
            return .toolCallsPending(capturedCalls)
        }
        return .terminal
    }

    private func finishStartupFailure(
        _ state: RunState,
        alias: String,
        imageMessageID: UUID?
    ) {
        state.applyImageDelivery(.abandoned, id: imageMessageID)
        let copy = "Couldn't start \(alias). Try again, or pick a different model in the box below."
        if var placeholder = state.current() {
            placeholder.status = .failed
            if placeholder.content.isEmpty { placeholder.content = copy }
            placeholder.errorMessage = copy
            placeholder.failureKind = .modelLoadFailed
            state.updateCurrent(placeholder)
        }
        state.completionStatus = .modelUnavailable
        state.failureKind = .modelLoadFailed
    }

    private func finishCancellation(_ state: RunState, imageMessageID: UUID?) {
        state.applyImageDelivery(.abandoned, id: imageMessageID)
        if var placeholder = state.current() {
            ChatViewModel.finaliseCancellation(message: &placeholder)
            state.updateCurrent(placeholder)
        }
        state.completionStatus = .cancelled
        state.failureKind = nil
    }

    private func failWithToolRoundCap(_ state: RunState) {
        let copy = ChatViewModel.toolRoundCapMessage(cap: maxToolExecutions)
        if var capped = state.current() {
            capped.status = .failed
            capped.failureKind = .toolFailed
            capped.errorMessage = copy
            capped.toolCalls = nil
            state.updateCurrent(capped)
        }
        state.completionStatus = .failed
        state.failureKind = .toolFailed
    }

    private func appendGroundingSources(_ state: RunState) {
        guard !state.groundingSources.isEmpty,
              var message = state.current(),
              message.status == .complete,
              !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        let missing = state.groundingSources.filter { !message.content.contains($0.url) }
        guard !missing.isEmpty else { return }
        let rows = missing.map { source in
            let title = source.title
                .replacingOccurrences(of: "[", with: "\\[")
                .replacingOccurrences(of: "]", with: "\\]")
            return "- [\(title)](\(source.url))"
        }
        message.content += "\n\nSources:\n" + rows.joined(separator: "\n")
        state.updateCurrent(message)
    }
}
