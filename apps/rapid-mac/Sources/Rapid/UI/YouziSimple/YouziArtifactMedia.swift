import AppKit
import AVFoundation
import ImageIO
import Observation
import SwiftUI

// Square preview sizes are shared by every artifact kind (including documents).
enum YouziArtifactCardSize: String, CaseIterable, Identifiable {
    case small, medium, large
    var id: String { rawValue }
    var edge: CGFloat {
        switch self { case .small: 144; case .medium: 208; case .large: 288 }
    }
    func title(isChinese: Bool) -> String {
        switch self {
        case .small: isChinese ? "小" : "Small"
        case .medium: isChinese ? "中" : "Medium"
        case .large: isChinese ? "大" : "Large"
        }
    }
}

struct YouziDecodedImage: @unchecked Sendable {
    let image: CGImage
    let pixels: CGSize
}

enum YouziMediaDecoder {
    /// ImageIO downsampling avoids loading an unbounded full-resolution bitmap.
    /// Keep original dimensions separately for true pixel-scale navigation.
    static func image(lease: YouziMediaFileLease, maxPixels: Int) throws -> YouziDecodedImage {
        try withExtendedLifetime(lease) {
            guard let source = CGImageSourceCreateWithURL(lease.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                  width.doubleValue > 0, height.doubleValue > 0
            else { throw CocoaError(.fileReadCorruptFile) }
            // At most 16 megapixels for an overlay; thumbnail calls stay at 640.
            let ratio = max(width.doubleValue, height.doubleValue) / min(width.doubleValue, height.doubleValue)
            let boundedEdge = min(max(1, maxPixels), Int(sqrt(16_777_216 * min(ratio, 1_000_000))))
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: boundedEdge,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary)
            else { throw CocoaError(.fileReadCorruptFile) }
            let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            let swapped = (5...8).contains(orientation)
            return YouziDecodedImage(image: image, pixels: CGSize(
                width: swapped ? height.doubleValue : width.doubleValue,
                height: swapped ? width.doubleValue : height.doubleValue
            ))
        }
    }

    static func thumbnail(lease: YouziMediaFileLease, kind: YouziArtifactKind) async throws -> CGImage {
        try Task.checkCancellation()
        if kind == .video {
            let job = YouziVideoThumbnailJob(url: lease.url)
            // The lease also outlives asynchronous failure/cancellation paths.
            defer { withExtendedLifetime(lease) {} }
            let image = try await withTaskCancellationHandler {
                try await job.image()
            } onCancel: { job.cancel() }
            try Task.checkCancellation()
            return image
        }
        return try image(lease: lease, maxPixels: 640).image
    }
}

/// AVFoundation's Objective-C generator has no Sendable annotation. Its
/// documented cancel API is the sole cross-task operation; all configuration
/// is completed before publishing this one-request wrapper.
private final class YouziVideoThumbnailJob: @unchecked Sendable {
    private let generator: AVAssetImageGenerator
    init(url: URL) {
        generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
    }
    func image() async throws -> CGImage { try await generator.image(at: .zero).image }
    func cancel() { generator.cancelAllCGImageGeneration() }
}

@MainActor
private final class YouziThumbnailCache {
    static let shared = YouziThumbnailCache()
    let images = NSCache<NSString, NSImage>()
    init() { images.totalCostLimit = 48 * 1024 * 1024; images.countLimit = 160 }
}

struct YouziArtifactThumbnail: View {
    @Environment(YouziI18nConfig.self) private var i18n
    let artifact: YouziArtifact
    let revision: Date
    let playing: Bool
    let available: Bool
    let mediaLease: () async throws -> YouziMediaFileLease
    @State private var thumbnail: NSImage?
    @State private var failed = false
    @State private var loading = false

    private var cacheKey: String { "\(artifact.id)-\(artifact.fileID)-\(revision.timeIntervalSince1970)-\(artifact.kind.rawValue)-\(available)" }

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                GeometryReader { geometry in
                    ZStack {
                        RoundedRectangle(cornerRadius: 12).fill(RapidTheme.surfaceSidebar)
                        if let thumbnail {
                            Image(nsImage: thumbnail).resizable().scaledToFill()
                                .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                        } else {
                            VStack(spacing: 12) {
                                Image(systemName: failed ? "exclamationmark.triangle" : artifact.kind.systemImage)
                                    .font(.system(size: 34, weight: .light))
                                    .foregroundStyle(RapidTheme.brandPrimary)
                                if !available {
                                    Text(i18n.text(zh: "文件不可用", en: "File unavailable"))
                                        .font(RapidFont.caption).foregroundStyle(RapidTheme.textSecondary)
                                } else if loading { ProgressView().controlSize(.small) }
                                else if failed {
                                    Text(i18n.text(zh: "无法生成缩略图", en: "Preview unavailable"))
                                        .font(RapidFont.caption).foregroundStyle(RapidTheme.textSecondary)
                                } else if let text = artifact.previewText, !text.isEmpty, artifact.kind != .audio {
                                    Text(String(text.prefix(240))).font(RapidFont.caption)
                                        .lineLimit(4).foregroundStyle(RapidTheme.textSecondary).padding(.horizontal, 18)
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        if artifact.kind == .audio || artifact.kind == .video {
                            VStack {
                                Spacer()
                                HStack {
                                    Spacer()
                                    Image(systemName: playing ? "pause.fill" : "play.fill")
                                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                                        .frame(width: 38, height: 38).background(.black.opacity(0.55), in: Circle())
                                }
                            }.padding(12)
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(RapidTheme.hairline, lineWidth: 1))
                }
            }
            .contentShape(Rectangle())
            .task(id: cacheKey) { await loadThumbnail() }
    }

    private func loadThumbnail() async {
        thumbnail = nil; failed = false
        guard available else { return }
        guard artifact.kind == .image || artifact.kind == .video else { return }
        let key = cacheKey
        if let cached = YouziThumbnailCache.shared.images.object(forKey: key as NSString) {
            thumbnail = cached; return
        }
        loading = true
        defer { loading = false }
        do {
            let lease = try await mediaLease()
            let kind = artifact.kind
            let worker = Task.detached(priority: .utility) {
                try await YouziMediaDecoder.thumbnail(lease: lease, kind: kind)
            }
            let decoded = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            let result = NSImage(cgImage: decoded, size: .zero)
            YouziThumbnailCache.shared.images.setObject(result, forKey: key as NSString,
                                                       cost: decoded.bytesPerRow * decoded.height)
            thumbnail = result
        } catch is CancellationError { }
        catch { if !Task.isCancelled { failed = true } }
    }
}

struct YouziMediaPreview: Identifiable {
    let id: UUID
    let title: String
    let kind: YouziArtifactKind
    let lease: YouziMediaFileLease
    let player: AVPlayer?
}

/// One playback owner for the gallery; never overlap narration and video audio.
@MainActor @Observable
final class YouziArtifactPlayback {
    private(set) var preview: YouziMediaPreview?
    private(set) var audioID: UUID?
    private(set) var audioTitle: String?
    private(set) var isPlaying = false
    var failed = false
    @ObservationIgnored private var lease: YouziMediaFileLease?
    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var playingObservation: NSKeyValueObservation?
    @ObservationIgnored private var endObserver: YouziPlaybackEndObservation?
    @ObservationIgnored private var playbackID = UUID()

    func open(_ artifact: YouziArtifact, lease acquire: () async throws -> YouziMediaFileLease) async {
        if artifact.kind == .audio, audioID == artifact.id { toggleAudio(); return }
        stop()
        let requestID = playbackID
        do {
            let acquired = try await acquire()
            try Task.checkCancellation()
            guard playbackID == requestID else { return }
            lease = acquired
            if artifact.kind == .image {
                preview = YouziMediaPreview(id: artifact.id, title: artifact.title, kind: .image, lease: acquired, player: nil)
                return
            }
            let item = AVPlayerItem(url: acquired.url)
            let current = AVPlayer(playerItem: item)
            player = current
            let generation = playbackID
            statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                let failed = item.status == .failed
                Task { @MainActor [weak self] in
                    guard let self, self.playbackID == generation, failed else { return }
                    self.stop(); self.failed = true
                }
            }
            playingObservation = current.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
                let active = player.timeControlStatus != .paused
                Task { @MainActor [weak self] in
                    guard let self, self.playbackID == generation else { return }
                    self.isPlaying = active
                }
            }
            endObserver = YouziPlaybackEndObservation(item: item) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.playbackID == generation else { return }
                    self.isPlaying = false
                    self.player?.seek(to: .zero)
                }
            }
            if artifact.kind == .audio {
                audioID = artifact.id; audioTitle = artifact.title
            } else {
                preview = YouziMediaPreview(id: artifact.id, title: artifact.title, kind: .video, lease: acquired, player: current)
            }
            current.play(); isPlaying = true
        } catch {
            guard playbackID == requestID else { return }
            stop()
            if !(error is CancellationError) { failed = true }
        }
    }

    func toggleAudio() {
        guard audioID != nil, let player else { return }
        if isPlaying { player.pause() } else { player.play() }
        isPlaying.toggle()
    }

    func stop() {
        playbackID = UUID()
        statusObservation = nil; playingObservation = nil
        endObserver = nil
        player?.pause(); player?.replaceCurrentItem(with: nil)
        player = nil; preview = nil; lease = nil
        audioID = nil; audioTitle = nil; isPlaying = false
    }
}

/// NotificationCenter registrations do not automatically disappear with a token.
/// This RAII wrapper also covers destruction without a SwiftUI onDisappear.
private final class YouziPlaybackEndObservation: @unchecked Sendable {
    private let token: NSObjectProtocol
    init(item: AVPlayerItem, handler: @escaping @Sendable (Notification) -> Void) {
        token = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main, using: handler
        )
    }
    deinit { NotificationCenter.default.removeObserver(token) }
}
