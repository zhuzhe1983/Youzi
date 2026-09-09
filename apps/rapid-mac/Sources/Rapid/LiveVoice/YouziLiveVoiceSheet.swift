import AppKit
import SwiftUI

struct YouziLiveVoiceButton: View {
    @Environment(YouziI18nConfig.self) private var i18n
    @Binding var isPresented: Bool
    var compact = false
    var body: some View {
        Group {
            if compact {
                YouziComposerIconButton(symbol: "waveform", label: i18n.text(zh: "语音对话", en: "Live Voice")) {
                    isPresented = true
                }
            } else {
                Button { isPresented = true } label: {
                    Label(i18n.text(zh: "语音对话", en: "Live Voice"), systemImage: "waveform")
                }.buttonStyle(.borderless)
            }
        }
        .help(i18n.text(zh: "打开语音对话；开始前不会使用麦克风", en: "Open voice conversation; the microphone stays off until Start"))
        .accessibilityIdentifier("LiveVoice.Open")
    }
}

/// Mounted on the stable chat surface, NOT its empty/transcript composer branch.
/// Sending the first utterance must not destroy the sheet and its microphone.
struct YouziLiveVoicePresentation: ViewModifier {
    let chat: ChatViewModel
    let server: ServerManager
    let alias: String
    var prepareTurn: ((String) -> [ChatFileAttachment]?)? = nil
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $isPresented) {
                YouziLiveVoiceSheet(chat: chat, server: server, alias: alias, prepareTurn: prepareTurn)
            }
            .onChange(of: chat.activeConversationID) { _, _ in isPresented = false }
            .onChange(of: alias) { _, _ in isPresented = false }
            .onDisappear { isPresented = false }
    }
}

struct YouziLiveVoiceSheet: View {
    @Environment(YouziI18nConfig.self) private var i18n
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(BrowseApprovalStore.self) private var browseApproval: BrowseApprovalStore?
    @Environment(MCPToolApprovalStore.self) private var mcpApproval: MCPToolApprovalStore?
    @Environment(DictationController.self) private var dictation: DictationController?
    @State private var controller: YouziLiveVoiceController
    @State private var halfDuplex = false
    @State private var startTask: Task<Void, Never>?
    private let chat: ChatViewModel

    init(chat: ChatViewModel, server: ServerManager, alias: String,
         prepareTurn: ((String) -> [ChatFileAttachment]?)? = nil) {
        self.chat = chat
        _controller = State(initialValue: YouziLiveVoiceController(
            audio: YouziLiveAudioEngine(), transport: AudioClient(),
            chat: LiveVoiceChatAdapter(chat: chat, prepareTurn: prepareTurn),
            readiness: LiveVoiceResidentModels(server: server, chatAlias: alias)
        ))
    }

    private var approvalPending: Bool {
        browseApproval?.pendingRequest != nil || mcpApproval?.pendingRequest != nil
            || (chat.tools as? CompositeToolRegistry)?.builtin.localModels?.approval.pending != nil
    }
    private var dictationBusy: Bool {
        guard let phase = dictation?.phase else { return false }
        return phase == .starting || phase == .recording || phase == .transcribing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(i18n.text(zh: "语音对话", en: "Live Voice"), systemImage: "waveform")
                    .font(.title2.bold())
                Spacer()
                Button { close() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .accessibilityLabel(i18n.text(zh: "关闭语音对话并关闭麦克风", en: "Close voice conversation and turn off microphone"))
                    .accessibilityIdentifier("LiveVoice.Close")
            }
            Label(status, systemImage: controller.isMicrophoneOn ? "mic.fill" : "mic.slash")
                .font(.headline)
                .foregroundStyle(controller.isMicrophoneOn ? Color.accentColor : Color.secondary)
                .accessibilityIdentifier("LiveVoice.Status")

            Text(i18n.text(
                zh: "说完后停顿，柚子会按句朗读正在生成的回复。识别只在停顿或点“说完了”后提交；超过 15 秒会停止并请你重说，不会提交半条指令。这不是原生流式语音识别。",
                en: "Pause after speaking. Youzi reads sentences as the reply arrives. Recognition is submitted only after a pause or Send Utterance. At 15 seconds, capture stops without submitting a partial command. This is not native streaming ASR."
            ))
            .font(.callout).foregroundStyle(.secondary)

            if controller.isMicrophoneOn {
                Text(controller.isHalfDuplex
                    ? i18n.text(zh: "半双工：识别和回复期间忽略麦克风输入。点“打断并继续说”后再开口。", en: "Half duplex: microphone input is ignored during recognition and replies. Press Interrupt & Speak before talking again.")
                    : i18n.text(zh: "系统语音处理已启用：可尝试开口打断。实际扬声器回声消除效果尚需现场验证。", en: "System voice processing is enabled: try speaking to interrupt. Acoustic echo cancellation still needs an attended speaker/mic check."))
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Toggle(i18n.text(zh: "使用半双工（不使用系统回声消除）", en: "Use half duplex (without system echo cancellation)"), isOn: $halfDuplex)
                    .disabled(controller.isStarting)
                    .accessibilityIdentifier("LiveVoice.HalfDuplex")
            }

            if let problem = controller.problem {
                Label(problemText(problem), systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
                    .accessibilityIdentifier("LiveVoice.Problem")
            }
            if dictationBusy {
                Text(i18n.text(zh: "请先结束全局听写，再开始语音对话。", en: "Finish global dictation before starting voice conversation."))
                    .font(.callout).foregroundStyle(.orange)
            }
            if let models = controller.selectedModels {
                VStack(alignment: .leading, spacing: 3) {
                    Text(i18n.text(zh: "对话：\(models.chatAlias)", en: "Chat: \(models.chatAlias)"))
                    Text(i18n.text(zh: "识别：\(models.recognition.model)", en: "Recognition: \(models.recognition.model)"))
                    Text(i18n.text(zh: "朗读：\(models.speech.model)", en: "Speech: \(models.speech.model)"))
                }
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if !controller.recognizedText.isEmpty || !controller.assistantPreview.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if !controller.recognizedText.isEmpty {
                            Text(i18n.text(zh: "你说", en: "You said")).font(.caption.bold())
                            Text(controller.recognizedText).textSelection(.enabled)
                        }
                        if !controller.assistantPreview.isEmpty {
                            Text(i18n.text(zh: "柚子的回复", en: "Youzi’s reply")).font(.caption.bold())
                            Text(controller.assistantPreview).textSelection(.enabled)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 180)
            }
            Divider()
            HStack {
                if controller.isActive {
                    Button(i18n.text(zh: "结束 · 关闭麦克风", en: "End · Mic Off"), role: .destructive) {
                        startTask?.cancel(); controller.stop()
                    }
                    .accessibilityIdentifier("LiveVoice.Stop")
                    Spacer()
                    if controller.canFinishUtterance {
                        Button(i18n.text(zh: "说完了", en: "Send Utterance")) { controller.finishUtterance() }
                            .accessibilityIdentifier("LiveVoice.FinishUtterance")
                    }
                    if controller.phase == .responding || controller.phase == .transcribing {
                        Button(i18n.text(zh: "打断并继续说", en: "Interrupt & Speak")) { controller.interrupt() }
                            .accessibilityIdentifier("LiveVoice.Interrupt")
                    }
                } else {
                    Spacer()
                    Button(i18n.text(zh: "开始 · 打开麦克风", en: "Start · Mic On")) {
                        startTask = Task { await controller.start(halfDuplex: halfDuplex) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(controller.isStarting || chat.isStreaming || dictationBusy || approvalPending)
                    .accessibilityIdentifier("LiveVoice.Start")
                }
            }
            Text(i18n.text(
                zh: "只使用已加载的对话、识别和朗读模型，不会自动下载或加载。工具仍走原有确认流程；需要确认时会关闭麦克风并返回聊天。语音文本保存在当前聊天中，原始录音不保存。",
                en: "Uses already-loaded chat, recognition, and speech models only; no automatic downloads or loads. Tools keep their original confirmation flow; approvals turn off the mic and return to chat. Transcribed text stays in this conversation; raw recordings are not saved."
            ))
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 520)
        .accessibilityIdentifier("LiveVoice.Sheet")
        .onDisappear { startTask?.cancel(); controller.stop() }
        .onChange(of: approvalPending) { _, pending in
            if pending { controller.handoffToChat(); dismiss() }
        }
        .onChange(of: dictationBusy) { _, busy in if busy { controller.stop() } }
        .onChange(of: scenePhase) { _, phase in if phase == .background { close() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            controller.stop()
        }
    }

    private func close() { startTask?.cancel(); controller.stop(); dismiss() }
    private var status: String {
        switch controller.phase {
        case .stopped: return i18n.text(zh: "麦克风已关闭", en: "Microphone off")
        case .preparing: return i18n.text(zh: "检查已加载模型和麦克风权限…", en: "Checking loaded models and microphone permission…")
        case .listening:
            return controller.isUserSpeaking ? i18n.text(zh: "正在听 · 说完后停顿", en: "Listening · Pause when finished")
                : i18n.text(zh: "正在听 · 可以开始说话", en: "Listening · Speak when ready")
        case .transcribing: return i18n.text(zh: "识别本次语音窗口…", en: "Transcribing this utterance window…")
        case .responding:
            switch controller.replyStage {
            case .waitingForText:
                return i18n.text(zh: "等待模型输出 · 尚未开始朗读", en: "Waiting for model text · Audio has not started")
            case .waitingForSentence:
                return i18n.text(zh: "正在接收回复 · 等待完整语句", en: "Receiving reply · Waiting for a speakable sentence")
            case .synthesizing:
                return i18n.text(zh: "生成本句语音 · 等待音频", en: "Synthesizing this sentence · Waiting for audio")
            case .speaking:
                return i18n.text(zh: "正在朗读 · 可打断", en: "Speaking · You can interrupt")
            }
        }
    }
    private func problemText(_ problem: YouziLiveVoiceController.Problem) -> String {
        switch problem {
        case .unsupportedSpeechModel: return i18n.text(zh: "当前朗读模型不支持此语音会话。请手动加载 Qwen3-TTS CustomVoice，再重新开始。Kokoro、Base 和 VoiceDesign 不受支持。", en: "The loaded speech model does not support this voice session. Manually load Qwen3-TTS CustomVoice, then restart. Kokoro, Base, and VoiceDesign are not supported.")
        case .utteranceTooLong: return i18n.text(zh: "本次说话超过 15 秒，已关闭麦克风，没有提交任何指令。请重新开始，说短一点，或及时点“说完了”。", en: "This utterance reached 15 seconds. The microphone is off and no command was submitted. Start again with a shorter request, or press Send Utterance sooner.")
        case .modelsMissing: return i18n.text(zh: "请先在模型管理中加载所选对话模型及识别、朗读模型。服务变化后请重新开始。", en: "First load the selected chat model plus recognition and speech models in Model Management. Restart this session after service changes.")
        case .chatBusy: return i18n.text(zh: "当前聊天还有其他回复，请等它完成后再开始。未取消其他任务。", en: "Another reply is active in this chat. Wait for it to finish; other tasks were not cancelled.")
        case .microphone: return i18n.text(zh: "无法启动麦克风。请检查系统麦克风权限及输入设备。", en: "Could not start the microphone. Check system microphone permission and the input device.")
        case .voiceProcessing: return i18n.text(zh: "无法启动系统语音处理。请检查麦克风权限和设备，或手动选择半双工后重试。", en: "System voice processing could not start. Check microphone permission and devices, or explicitly select half duplex and retry.")
        case .recognition: return i18n.text(zh: "本次语音窗口识别失败，麦克风已关闭。请检查识别服务后重试。", en: "Utterance recognition failed; the microphone is off. Check the recognition service and retry.")
        case .speech: return i18n.text(zh: "朗读服务不可用或音频中断，麦克风已关闭。文字回复仍可在聊天中查看。", en: "Speech is unavailable or playback failed; the microphone is off. Text replies remain available in chat.")
        case .deviceChanged: return i18n.text(zh: "音频设备发生变化或停止，已关闭麦克风。请重新开始。", en: "The audio device changed or stopped. The microphone is off; start again.")
        case .replyChanged: return i18n.text(zh: "回复被修订，已停止朗读以避免旧内容。请在聊天中查看最新回复。", en: "The reply was revised. Speech stopped to avoid stale content; read the updated reply in chat.")
        case .replyTooLong: return i18n.text(zh: "待朗读内容达到上限，已关闭语音。完整回复仍在聊天中生成。", en: "Pending speech reached its limit. Voice is off; the full reply continues in chat.")
        case .preparation: return i18n.text(zh: "无法准备当前任务或模型已不可用。请返回聊天处理后重试。", en: "The task could not be prepared or its model is unavailable. Return to chat to resolve this and retry.")
        case .chatFailed: return i18n.text(zh: "聊天回复失败，麦克风已关闭。请在聊天中查看错误详情。", en: "The chat reply failed; the microphone is off. Check the error details in chat.")
        }
    }
}
