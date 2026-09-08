import AppKit
import SwiftUI

/// Reconstruct previews from persisted tool receipts, not assistant prose or
/// filesystem paths supplied by the model. No new chat persistence schema.
enum YouziChatArtifactReceipt {
    private struct Receipt: Decodable {
        let artifact_id: UUID
        let file_id: UUID
        let saved: Bool
        let error: String?
    }

    static func resolve(
        call: ToolCall, result: ChatMessage?, taskID: UUID?,
        artifact: (UUID) -> YouziArtifact?
    ) -> YouziArtifact? {
        let expectedKind: YouziArtifactKind
        switch call.function.name {
        case "youzi_generate_image": expectedKind = .image
        case "youzi_synthesize_speech": expectedKind = .audio
        case "youzi_generate_video": expectedKind = .video
        case "youzi_create_storybook": expectedKind = .document
        default: return nil
        }
        guard let taskID, let result, result.role == .tool,
              result.toolCallID == call.id, result.status == .complete,
              result.failureKind == nil, result.content.utf8.count <= 128_000,
              let receipt = try? JSONDecoder().decode(Receipt.self, from: Data(result.content.utf8)),
              receipt.saved, receipt.error == nil,
              let saved = artifact(receipt.artifact_id), saved.taskID == taskID,
              saved.fileID == receipt.file_id, saved.kind == expectedKind else { return nil }
        return saved
    }
}

/// Shared by Simple and Professional Mode. One playback owner per transcript
/// prevents overlapping media; changing chats or leaving stops it immediately.
struct YouziChatMediaPresentation: ViewModifier {
    let conversationID: UUID?
    @Environment(YouziI18nConfig.self) private var language: YouziI18nConfig?
    private var i18n: YouziI18nConfig { language ?? .shared }
    @State private var playback = YouziArtifactPlayback()

    func body(content: Content) -> some View {
        ZStack {
            content
                .environment(playback)
                .allowsHitTesting(playback.preview == nil)
                .accessibilityHidden(playback.preview != nil)
            if let preview = playback.preview {
                YouziArtifactMediaOverlay(preview: preview, onClose: { playback.stop() })
                    .environment(i18n)
                    .id(preview.id).zIndex(1)
            }
        }
        .alert(i18n.text(zh: "无法预览文件", en: "Unable to preview file"), isPresented: Binding(
            get: { playback.failed }, set: { playback.failed = $0 }
        )) {
            Button(i18n.text(zh: "好", en: "OK"), role: .cancel) {}
        } message: {
            Text(i18n.text(zh: "文件可能已删除、移动或无法读取。请在「我的文件」中检查。",
                           en: "The file may have been deleted, moved or become unreadable. Check My Files."))
        }
        .onChange(of: conversationID) { _, _ in playback.stop() }
        .onDisappear { playback.stop() }
    }
}

/// Deliberately outside the expandable tool chip: a collapsed debug receipt or
/// an LLM follow-up that is still streaming must never hide a finished output.
struct YouziChatArtifactCard: View {
    let call: ToolCall
    let result: ChatMessage?
    let conversationID: UUID?
    @Environment(YouziProductModel.self) private var product: YouziProductModel?
    @Environment(YouziArtifactPlayback.self) private var playback: YouziArtifactPlayback?
    @Environment(YouziI18nConfig.self) private var language: YouziI18nConfig?
    private var i18n: YouziI18nConfig { language ?? .shared }

    var body: some View {
        if let product, let playback,
           let task = product.tasks.first(where: { $0.conversationID == conversationID && conversationID != nil }),
           let artifact = YouziChatArtifactReceipt.resolve(call: call, result: result, taskID: task.id, artifact: product.artifact(id:)) {
            card(artifact, product: product, playback: playback)
        }
    }

    private func card(_ artifact: YouziArtifact, product: YouziProductModel, playback: YouziArtifactPlayback) -> some View {
        let file = product.file(for: artifact)
        let available = artifact.state == .active && (file?.availability == .available || file?.availability == .staleBookmark)
        let playing = playback.audioID == artifact.id && playback.isPlaying
        return VStack(alignment: .leading, spacing: 10) {
            if artifact.kind == .image || artifact.kind == .video {
                Button { open(artifact, product: product, playback: playback) } label: {
                    YouziArtifactThumbnail(artifact: artifact, revision: file?.updatedAt ?? artifact.updatedAt,
                        playing: false, available: available,
                        mediaLease: { try await product.mediaLease(id: artifact.fileID) })
                }
                .buttonStyle(.plain).disabled(!available)
                .accessibilityLabel(i18n.text(zh: "预览：", en: "Preview: ") + artifact.title)
                .accessibilityIdentifier("YouziChatArtifact.Preview.\(artifact.id)")
            }
            HStack(spacing: 10) {
                if artifact.kind == .audio {
                    Button { open(artifact, product: product, playback: playback) } label: {
                        Image(systemName: playing ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 32)).foregroundStyle(RapidTheme.brandPrimary)
                    }
                    .buttonStyle(.plain).disabled(!available)
                    .accessibilityLabel(i18n.text(zh: playing ? "暂停音频" : "播放音频", en: playing ? "Pause audio" : "Play audio"))
                    .accessibilityIdentifier("YouziChatArtifact.Play.\(artifact.id)")
                } else if artifact.kind != .image && artifact.kind != .video {
                    Image(systemName: artifact.kind.systemImage).font(.title2).foregroundStyle(RapidTheme.brandPrimary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(artifact.title).font(RapidFont.bodyEmphasis).lineLimit(2).help(artifact.title)
                    Text(available ? i18n.text(zh: "已保存到我的文件", en: "Saved to My Files") : i18n.text(zh: "文件不可用", en: "File unavailable"))
                        .font(RapidFont.caption).foregroundStyle(RapidTheme.textSecondary)
                }
                Spacer(minLength: 0)
                if artifact.kind == .audio, playback.audioID == artifact.id {
                    Button { playback.stop() } label: { Image(systemName: "stop.fill") }
                        .buttonStyle(.plain).help(i18n.text(zh: "停止播放", en: "Stop playback"))
                }
            }
            HStack {
                if let bytes = file?.byteCount {
                    Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                        .font(RapidFont.caption).foregroundStyle(RapidTheme.textSecondary)
                }
                Spacer()
                if artifact.kind != .image && artifact.kind != .audio && artifact.kind != .video {
                    Button(i18n.text(zh: "打开文件", en: "Open file")) {
                        open(artifact, product: product, playback: playback)
                    }.disabled(!available)
                }
                Button(i18n.text(zh: "在 Finder 中显示", en: "Show in Finder")) {
                    do {
                        try product.withFileURL(id: artifact.fileID) { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
                    } catch { playback.failed = true }
                }.disabled(!available)
            }
            .font(RapidFont.caption).buttonStyle(.borderless)
        }
        .padding(12)
        .frame(maxWidth: artifact.kind == .image || artifact.kind == .video ? 280 : 440, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(RapidTheme.surfaceSidebar))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(RapidTheme.hairline, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("YouziChatArtifact.Card.\(artifact.id)")
    }

    private func open(_ artifact: YouziArtifact, product: YouziProductModel, playback: YouziArtifactPlayback) {
        if [.image, .audio, .video].contains(artifact.kind) {
            Task { await playback.open(artifact, lease: { try await product.mediaLease(id: artifact.fileID) }) }
        } else {
            do {
                try product.withFileURL(id: artifact.fileID) {
                    guard NSWorkspace.shared.open($0) else { throw CocoaError(.fileReadUnknown) }
                }
            } catch { playback.failed = true }
        }
    }
}
