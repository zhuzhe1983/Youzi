import AppKit
import AVKit
import SwiftUI

struct YouziArtifactMediaOverlay: View {
    @Environment(YouziI18nConfig.self) private var i18n
    let preview: YouziMediaPreview
    let onClose: () -> Void
    @State private var image: YouziDecodedImage?
    @State private var failed = false
    @State private var zoom = 1.0
    @State private var command = YouziImageZoomCommand(action: .fit)
    @FocusState private var focused: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Button(action: onClose) {
                    Color.black.opacity(0.86).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityHidden(true)
                    .accessibilityIdentifier("YouziArtifactMediaOverlay.Button.9849166eb8")
                VStack(spacing: 12) {
                    HStack(spacing: 14) {
                        Text(preview.title).font(RapidFont.bodyEmphasis).lineLimit(1)
                        Spacer(minLength: 0)
                        if preview.kind == .image, image != nil {
                            Button { command = .init(action: .fit) } label: {
                                Text(i18n.text(zh: "适应窗口", en: "Fit"))
                            }
                                .accessibilityIdentifier("YouziArtifactMediaOverlay.Button.fc14c0e6d5")
                            Button("1:1") { command = .init(action: .actual) }
                                .help(i18n.text(zh: "一个图片像素对应一个屏幕像素", en: "One image pixel per display pixel"))
                                .accessibilityIdentifier("YouziArtifactMediaOverlay.Button.a94f9e82bb")
                            Button { command = .init(action: .out) } label: { Image(systemName: "minus.magnifyingglass") }
                                .help(i18n.text(zh: "缩小", en: "Zoom out"))
                                .accessibilityIdentifier("YouziArtifactMediaOverlay.Button.9168911898")
                            Text("\(Int(zoom * 100))%")
                                .monospacedDigit().font(RapidFont.caption).frame(minWidth: 42)
                            Button { command = .init(action: .in) } label: { Image(systemName: "plus.magnifyingglass") }
                                .help(i18n.text(zh: "放大", en: "Zoom in"))
                                .accessibilityIdentifier("YouziArtifactMediaOverlay.Button.e0fd2cb53f")
                        }
                        Button(action: onClose) { Image(systemName: "xmark").frame(width: 28, height: 28) }
                            .keyboardShortcut(.escape, modifiers: [])
                            .help(i18n.text(zh: "关闭预览 (Esc)", en: "Close preview (Esc)"))
                            .accessibilityIdentifier("YouziSimple.Media.Close")
                    }
                    .buttonStyle(.plain).padding(.horizontal, 12).padding(.top, 8)
                    ZStack {
                        Color.black.opacity(0.3)
                        if let player = preview.player {
                            YouziNativeVideoPlayer(player: player)
                                .accessibilityLabel(i18n.text(zh: "视频播放器", en: "Video player"))
                        } else if let image {
                            YouziZoomableImage(image: image, command: command, zoom: $zoom, accessibilityTitle: i18n.text(zh: "图片预览", en: "Image preview"))
                        } else if failed {
                            VStack(spacing: 12) {
                                Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                                Text(i18n.text(zh: "图片无法读取，请检查文件或尝试导出后打开。", en: "Unable to read the image. Check the file or export it to open elsewhere."))
                            }
                        } else { ProgressView().tint(.white) }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    if preview.kind == .image {
                        Text(i18n.text(zh: "滚轮 / 双指缩放 · 拖拽移动 · Esc 关闭", en: "Scroll / pinch to zoom · Drag to pan · Esc to close"))
                            .font(RapidFont.caption).foregroundStyle(.white.opacity(0.65))
                    }
                }
                .foregroundStyle(.white)
                .padding(16)
                .frame(width: max(0, geometry.size.width - 64), height: max(0, geometry.size.height - 48))
                .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
                .contentShape(Rectangle())
                .onTapGesture {} // Clicking controls/content must not dismiss the backdrop.
            }
        }
        .focusable().focusEffectDisabled().focused($focused)
        .onAppear { focused = true }
        .onExitCommand(perform: onClose)
        .task(id: preview.id) {
            guard preview.kind == .image else { return }
            do {
                let lease = preview.lease
                let worker = Task.detached(priority: .userInitiated) {
                    try Task.checkCancellation()
                    return try YouziMediaDecoder.image(lease: lease, maxPixels: 8192)
                }
                let decoded = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                image = decoded
            } catch is CancellationError { }
            catch { if !Task.isCancelled { failed = true } }
        }
        .accessibilityIdentifier("YouziSimple.Media.Overlay")
    }
}

/// Explicit AVPlayerView also links AVKit directly. The SwiftUI VideoPlayer
/// wrapper can fail superclass resolution in the SwiftPM test host on macOS.
private struct YouziNativeVideoPlayer: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = true
        view.showsFrameSteppingButtons = true
        view.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}

struct YouziImageZoomCommand: Equatable {
    enum Action { case fit, actual, `in`, out }
    let id = UUID()
    let action: Action
}

enum YouziImageZoom {
    static func clamped(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 1 }
        return min(16, max(0.01, value))
    }
    static func fit(pixels: CGSize, viewport: CGSize, backingScale: CGFloat) -> CGFloat {
        guard pixels.width > 0, pixels.height > 0, backingScale > 0 else { return 1 }
        return clamped(min(1, min(viewport.width * backingScale / pixels.width,
                                  viewport.height * backingScale / pixels.height)))
    }
}

private struct YouziZoomableImage: NSViewRepresentable {
    let image: YouziDecodedImage
    let command: YouziImageZoomCommand
    @Binding var zoom: Double
    let accessibilityTitle: String

    func makeNSView(context: Context) -> YouziImageScrollView {
        let view = YouziImageScrollView()
        view.setImage(image)
        view.setAccessibilityLabel(accessibilityTitle)
        return view
    }
    func updateNSView(_ view: YouziImageScrollView, context: Context) {
        view.onZoom = { value in
            // AppKit layout callbacks may run inside a SwiftUI update.
            DispatchQueue.main.async { zoom = Double(value) }
        }
        if view.lastCommand != command.id {
            view.lastCommand = command.id
            view.apply(command.action)
        }
    }
}

/// Native clip view maintains scroll bounds; wheel zoom is anchored at the cursor.
/// The document size is original pixels / screen backing scale, so 1:1 is literal.
final class YouziImageScrollView: NSScrollView {
    var onZoom: ((CGFloat) -> Void)?
    var lastCommand: UUID?
    private var pixels = CGSize(width: 1, height: 1)
    private var fitting = true
    private var previousSize = CGSize.zero
    private var previousScale: CGFloat = 0
    private let canvas = YouziPannableImageView()

    init() {
        super.init(frame: .zero)
        drawsBackground = false
        hasVerticalScroller = true; hasHorizontalScroller = true
        autohidesScrollers = true
        allowsMagnification = true; minMagnification = 0.01; maxMagnification = 16
        contentView = YouziCenteredImageClipView()
        contentView.drawsBackground = false
        documentView = canvas
        canvas.imageScaling = .scaleAxesIndependently
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setImage(_ image: YouziDecodedImage) {
        pixels = image.pixels
        canvas.image = NSImage(cgImage: image.image, size: image.pixels)
        updateDocumentSize()
    }

    private func updateDocumentSize() {
        let backing = window?.backingScaleFactor ?? 2
        canvas.setFrameSize(NSSize(width: pixels.width / backing, height: pixels.height / backing))
        previousScale = backing
    }

    override func layout() {
        super.layout()
        let backing = window?.backingScaleFactor ?? 2
        let scaleChanged = previousScale != backing
        if scaleChanged { updateDocumentSize() }
        if previousSize != bounds.size || scaleChanged {
            previousSize = bounds.size
            if fitting { apply(.fit) }
        }
    }

    func apply(_ action: YouziImageZoomCommand.Action) {
        let value: CGFloat
        switch action {
        case .fit:
            fitting = true
            value = YouziImageZoom.fit(pixels: pixels, viewport: bounds.size,
                                       backingScale: window?.backingScaleFactor ?? 2)
        case .actual: fitting = false; value = 1
        case .in: fitting = false; value = YouziImageZoom.clamped(magnification * 1.25)
        case .out: fitting = false; value = YouziImageZoom.clamped(magnification / 1.25)
        }
        let center = NSPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
        setMagnification(value, centeredAt: center)
        onZoom?(magnification)
    }

    override func scrollWheel(with event: NSEvent) {
        fitting = false
        let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.012 : 0.08)
        let value = YouziImageZoom.clamped(magnification * exp(delta))
        setMagnification(value, centeredAt: canvas.convert(event.locationInWindow, from: nil))
        onZoom?(magnification)
    }

    override func magnify(with event: NSEvent) {
        fitting = false
        super.magnify(with: event)
        onZoom?(magnification)
    }
}

final class YouziCenteredImageClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var result = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return result }
        if documentView.frame.width < result.width {
            result.origin.x = (documentView.frame.width - result.width) / 2
        }
        if documentView.frame.height < result.height {
            result.origin.y = (documentView.frame.height - result.height) / 2
        }
        return result
    }
}

private final class YouziPannableImageView: NSImageView {
    private var lastPoint = NSPoint.zero
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) {
        lastPoint = event.locationInWindow
        NSCursor.closedHand.set()
    }
    override func mouseDragged(with event: NSEvent) {
        guard let scroll = enclosingScrollView else { return }
        let point = event.locationInWindow
        var rect = scroll.contentView.bounds
        rect.origin.x -= (point.x - lastPoint.x) / scroll.magnification
        rect.origin.y -= (point.y - lastPoint.y) / scroll.magnification
        scroll.contentView.scroll(to: scroll.contentView.constrainBoundsRect(rect).origin)
        scroll.reflectScrolledClipView(scroll.contentView)
        lastPoint = point
    }
    override func mouseUp(with event: NSEvent) { NSCursor.openHand.set() }
}
