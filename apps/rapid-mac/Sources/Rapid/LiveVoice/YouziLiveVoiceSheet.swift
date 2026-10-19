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

private struct YouziVoiceControllerKey: EnvironmentKey {
    static let defaultValue: YouziLiveVoiceController? = nil
}
extension EnvironmentValues {
    var youziVoiceController: YouziLiveVoiceController? {
        get { self[YouziVoiceControllerKey.self] }
        set { self[YouziVoiceControllerKey.self] = newValue }
    }
}

/// The controller belongs to the stable chat surface. Inline controls may move
/// from the welcome composer into the transcript without ending the call.
struct YouziLiveVoicePresentation: ViewModifier {
    let chat: ChatViewModel
    let server: ServerManager
    let alias: String
    var prepareTurn: ((String) -> [ChatFileAttachment]?)? = nil
    @Binding var isPresented: Bool
    @State private var controller: YouziLiveVoiceController?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(BrowseApprovalStore.self) private var browseApproval: BrowseApprovalStore?
    @Environment(MCPToolApprovalStore.self) private var mcpApproval: MCPToolApprovalStore?
    @Environment(DictationController.self) private var dictation: DictationController?
    private var approvalPending: Bool {
        browseApproval?.pendingRequest != nil || mcpApproval?.pendingRequest != nil
            || (chat.tools as? CompositeToolRegistry)?.builtin.localModels?.approval.pending != nil
    }
    private var dictationBusy: Bool {
        guard let phase = dictation?.phase else { return false }
        return phase == .starting || phase == .recording || phase == .transcribing
    }
    func body(content: Content) -> some View {
        content
            .environment(\.youziVoiceController, controller)
            .onChange(of: isPresented, initial: true) { _, presented in
                chat.memoryStore?.ingestion.voiceIsOpen = presented
                if presented, controller == nil {
                    controller = YouziLiveVoiceController(audio: YouziLiveAudioEngine(), transport: AudioClient(),
                        chat: LiveVoiceChatAdapter(chat: chat, prepareTurn: prepareTurn),
                        readiness: LiveVoiceResidentModels(server: server, chatAlias: alias))
                } else if !presented { controller?.stop(); controller = nil }
            }
            .onChange(of: chat.activeConversationID) { _, _ in close() }
            .onChange(of: alias) { _, _ in close() }
            .onChange(of: approvalPending) { _, pending in
                if pending {
                    controller?.handoffToChat(); controller = nil; isPresented = false
                }
            }
            .onChange(of: dictationBusy) { _, busy in if busy { controller?.stop() } }
            .onChange(of: scenePhase) { _, phase in if phase == .background { close() } }
            .onDisappear { close() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in close() }
    }
    private func close() { controller?.stop(); controller = nil; isPresented = false; chat.memoryStore?.ingestion.voiceIsOpen = false }
}

struct YouziLiveVoiceInlineControls: View {
    @Environment(\.youziVoiceController) private var session
    @Environment(YouziI18nConfig.self) private var i18n
    @Environment(ChatViewModel.self) private var chat
    @Environment(DictationController.self) private var dictation: DictationController?
    @Binding var isPresented: Bool
    @State private var halfDuplex = false
    @State private var showsDetails = false
    private var dictationBusy: Bool {
        guard let phase = dictation?.phase else { return false }
        return phase == .starting || phase == .recording || phase == .transcribing
    }

    var body: some View {
        Group {
            if let controller = session {
                VStack(spacing: 10) {
                    YouziVoiceCallVisual(status: status(controller), connected: controller.isMicrophoneOn,
                        muted: controller.isMuted, speaking: controller.replyStage == .speaking && controller.phase == .responding,
                        inputLevel: controller.inputLevel, startedAt: controller.startedAt)
                    if let problem = controller.problem {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(problemText(problem), systemImage: "exclamationmark.circle")
                                .font(RapidFont.secondary).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("LiveVoice.Problem")
                            if problem == .voiceProcessing {
                                Button(i18n.text(zh: "兼容模式重试", en: "Retry in compatible mode")) {
                                    halfDuplex = true; controller.begin(halfDuplex: true)
                                }.disabled(controller.isStarting || chat.isStreaming || dictationBusy)
                                    .accessibilityIdentifier("LiveVoice.RetryCompatible")
                            } else if problem == .microphonePermission {
                                Button(i18n.text(zh: "打开麦克风权限设置", en: "Open microphone permissions")) {
                                    NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                                }.accessibilityIdentifier("LiveVoice.OpenMicrophoneSettings")
                            }
                        }.frame(maxWidth: 580, alignment: .leading)
                    }
                    if dictationBusy {
                        Text(i18n.text(zh: "请先结束听写，再开始通话。", en: "Finish dictation before starting a call."))
                            .font(RapidFont.secondary).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 18) {
                        Button { showsDetails.toggle() } label: { Image(systemName:"ellipsis").frame(width:42,height:42) }
                            .buttonStyle(.plain).background(RapidTheme.surfaceRaised,in:Circle())
                            .accessibilityLabel(i18n.text(zh:"通话详情",en:"Call details"))
                            .accessibilityIdentifier("LiveVoice.Details")
                            .popover(isPresented:$showsDetails,arrowEdge:.top) { details(controller) }
                        if controller.isMicrophoneOn {
                            Button { controller.setMuted(!controller.isMuted) } label: {
                                Image(systemName:controller.isMuted ? "mic.slash.fill" : "mic.fill").frame(width:42,height:42)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(controller.isMuted ? Color.orange : RapidTheme.textPrimary)
                            .background(RapidTheme.surfaceRaised,in:Circle())
                            .accessibilityLabel(i18n.text(zh:controller.isMuted ? "取消静音" : "静音",en:controller.isMuted ? "Unmute" : "Mute"))
                            .accessibilityIdentifier("LiveVoice.Mute")
                            Button { controller.stop(); isPresented = false } label: {
                                Image(systemName:"phone.down.fill").frame(width:46,height:46).foregroundStyle(.white)
                            }
                            .buttonStyle(.plain).background(Color.red,in:Circle())
                            .accessibilityLabel(i18n.text(zh:"结束通话",en:"End call"))
                            .accessibilityIdentifier("LiveVoice.Stop")
                        } else {
                            Button { controller.begin(halfDuplex:halfDuplex) } label: {
                                Label(controller.isStarting ? i18n.text(zh:"正在连接…",en:"Connecting…") : i18n.text(zh:"开始通话",en:"Start call"),systemImage:"phone.fill")
                                    .padding(.horizontal,12).padding(.vertical,7)
                            }.buttonStyle(.borderedProminent).clipShape(Capsule())
                                .disabled(controller.isStarting || chat.isStreaming || dictationBusy)
                                .accessibilityIdentifier("LiveVoice.Start")
                            Button { controller.stop(); isPresented = false } label: { Image(systemName:"xmark").frame(width:42,height:42) }
                                .buttonStyle(.plain).background(RapidTheme.surfaceRaised,in:Circle())
                                .accessibilityLabel(i18n.text(zh:"关闭语音",en:"Close voice"))
                                .accessibilityIdentifier("LiveVoice.Close")
                        }
                    }
                    if controller.canFinishUtterance {
                        Button(i18n.text(zh:"说完了",en:"Send utterance")) { controller.finishUtterance() }
                            .buttonStyle(.link).accessibilityIdentifier("LiveVoice.FinishUtterance")
                    } else if controller.phase == .responding || controller.phase == .transcribing {
                        Button(i18n.text(zh:"打断并继续说",en:"Interrupt and speak")) { controller.interrupt() }
                            .buttonStyle(.link).disabled(controller.isMuted).accessibilityIdentifier("LiveVoice.Interrupt")
                    }
                }
                .padding(.vertical,12).padding(.horizontal,16)
                .frame(maxWidth:.infinity)
                .accessibilityIdentifier("LiveVoice.Inline")
            }
        }
    }

    private func details(_ controller: YouziLiveVoiceController) -> some View {
        VStack(alignment:.leading,spacing:14) {
            Text(i18n.text(zh:"通话详情",en:"Call details")).font(RapidFont.sectionTitle)
            Toggle(i18n.text(zh:"兼容模式",en:"Compatible mode"),isOn:$halfDuplex)
                .disabled(controller.isActive || controller.isStarting).accessibilityIdentifier("LiveVoice.HalfDuplex")
            Text(i18n.text(zh:"兼容模式下，柚子说话时暂停听取；点“打断并继续说”后再开口。",en:"Compatible mode pauses listening while Youzi speaks. Press Interrupt and speak to talk again."))
                .font(RapidFont.secondary).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            if let code = controller.audioErrorCode { Text(i18n.text(zh:"音频错误码：\(code)",en:"Audio error code: \(code)")).font(RapidFont.caption) }
            if let models = controller.selectedModels {
                Divider()
                Text(i18n.text(zh:"对话：",en:"Chat: ")+models.chatAlias)
                Text(i18n.text(zh:"识别：",en:"Recognition: ")+models.recognition.model)
                Text(i18n.text(zh:"朗读：",en:"Speech: ")+models.speech.model)
            }
            Divider()
            Text(i18n.text(zh:"说完后稍作停顿即可发送，每次尽量在 15 秒内。文字保存在当前聊天，原始录音不保存。",en:"Pause to send each utterance, keeping it under 15 seconds. Text stays in this chat; raw recordings are not saved."))
                .fixedSize(horizontal:false,vertical:true)
        }.font(RapidFont.caption).textSelection(.enabled).padding(20).frame(width:360)
    }
    private func status(_ controller: YouziLiveVoiceController) -> String {
        if controller.isMuted { return i18n.text(zh:"麦克风已静音",en:"Microphone muted") }
        switch controller.phase {
        case .stopped: return controller.problem == nil ? i18n.text(zh:"和柚子聊聊",en:"Talk with Youzi") : i18n.text(zh:"连接未完成",en:"Could not connect")
        case .preparing: return i18n.text(zh:"正在连接…",en:"Connecting…")
        case .listening: return controller.isUserSpeaking ? i18n.text(zh:"我在听",en:"I'm listening") : i18n.text(zh:"可以开始说话",en:"Speak when ready")
        case .transcribing: return i18n.text(zh:"正在听懂你的话…",en:"Understanding…")
        case .responding: return controller.replyStage == .speaking ? i18n.text(zh:"柚子正在说话",en:"Youzi is speaking") : i18n.text(zh:"柚子正在思考…",en:"Youzi is thinking…")
        }
    }
    private func problemText(_ problem: YouziLiveVoiceController.Problem) -> String {
        switch problem {
        case .unsupportedSpeechModel: return i18n.text(zh: "当前朗读模型不支持此语音会话。请手动加载 Qwen3-TTS CustomVoice，再重新开始。Kokoro、Base 和 VoiceDesign 不受支持。", en: "The loaded speech model does not support this voice session. Manually load Qwen3-TTS CustomVoice, then restart. Kokoro, Base, and VoiceDesign are not supported.")
        case .utteranceTooLong: return i18n.text(zh: "本次说话超过 15 秒，已关闭麦克风，没有提交任何指令。请重新开始，说短一点，或及时点“说完了”。", en: "This utterance reached 15 seconds. The microphone is off and no command was submitted. Start again with a shorter request, or press Send Utterance sooner.")
        case .modelsMissing: return i18n.text(zh: "请先在模型管理中加载所选对话模型及识别、朗读模型。服务变化后请重新开始。", en: "First load the selected chat model plus recognition and speech models in Model Management. Restart this session after service changes.")
        case .chatBusy: return i18n.text(zh: "当前聊天还有其他回复，请等它完成后再开始。未取消其他任务。", en: "Another reply is active in this chat. Wait for it to finish; other tasks were not cancelled.")
        case .microphonePermission: return i18n.text(zh: "麦克风权限未开启。请在系统设置中允许 Youzi 使用麦克风后重试。", en: "Microphone permission is off. Allow Youzi in System Settings, then retry.")
        case .audioDevice: return i18n.text(zh: "没有可用的输入或输出设备。请检查麦克风和扬声器后重试。", en: "No usable audio input or output. Check your microphone and speakers, then retry.")
        case .microphone: return i18n.text(zh: "无法启动麦克风。请检查系统麦克风权限及输入设备。", en: "Could not start the microphone. Check system microphone permission and the input device.")
        case .voiceProcessing: return i18n.text(zh: "当前音频设备无法启动系统回声消除。可使用兼容模式重试，柚子说话时会暂停听取。", en: "System echo cancellation could not start on these audio devices. Retry in compatible mode; listening pauses while Youzi speaks.")
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

/// Compact call identity above the existing composer, with input-level feedback.
struct YouziVoiceCallVisual: View {
    @Environment(YouziI18nConfig.self) private var i18n
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let status: String
    let connected: Bool
    let muted: Bool
    let speaking: Bool
    let inputLevel: Double
    let startedAt: Date?
    var body: some View {
        VStack(spacing:8) {
            ZStack {
                Circle().fill(RapidTheme.brandPrimary.opacity(0.12)).frame(width:100,height:100)
                    .scaleEffect(reduceMotion ? 1 : 1 + min(1,max(0,inputLevel)) * 0.14)
                Circle().fill(LinearGradient(colors:[Color.orange.opacity(0.9),RapidTheme.brandPrimary,Color.yellow.opacity(0.8)],startPoint:.topLeading,endPoint:.bottomTrailing))
                    .frame(width:80,height:80)
                    .overlay(alignment:.topLeading) { Ellipse().fill(.white.opacity(0.35)).frame(width:40,height:18).rotationEffect(.degrees(-30)).offset(x:12,y:10).blur(radius:5) }
                Image(systemName:muted ? "mic.slash.fill" : speaking ? "waveform" : "leaf.fill")
                    .font(.system(size:28,weight:.medium)).foregroundStyle(.white)
            }.accessibilityHidden(true).animation(reduceMotion ? nil : .easeOut(duration:0.15),value:inputLevel)
            Text(status).font(RapidFont.bodyEmphasis).multilineTextAlignment(.center)
                .fixedSize(horizontal:false,vertical:true).accessibilityIdentifier("LiveVoice.Status")
            if let startedAt, connected {
                TimelineView(.periodic(from:startedAt,by:1)) { timeline in
                    let seconds = max(0,Int(timeline.date.timeIntervalSince(startedAt)))
                    Text(String(format:"%02d:%02d",seconds/60,seconds%60)).monospacedDigit().font(RapidFont.caption).foregroundStyle(.secondary)
                }
            } else {
                Text(i18n.text(zh:"开始后才会打开麦克风",en:"Microphone stays off until you start"))
                    .font(RapidFont.caption).foregroundStyle(.secondary)
            }
        }
    }
}
