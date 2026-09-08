import AppKit
import AVFoundation
import AVKit
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import Rapid

@Suite("Youzi artifact gallery — media lifetime and interaction", .serialized)
struct YouziArtifactMediaTests {
    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("youzi-gallery-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writePNG(to url: URL, width: Int = 1200, height: Int = 600) throws {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.12, green: 0.55, blue: 0.42, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.95, green: 0.75, blue: 0.22, alpha: 1))
        context.fillEllipse(in: CGRect(x: width / 3, y: height / 4, width: height / 2, height: height / 2))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    @Test("All three square sizes and bounded pixel-scale fit")
    func sizesAndZoom() {
        #expect(YouziArtifactCardSize.allCases.map(\.edge) == [144, 208, 288])
        #expect(YouziImageZoom.fit(pixels: CGSize(width: 4000, height: 2000),
                                  viewport: CGSize(width: 1000, height: 600), backingScale: 2) == 0.5)
        #expect(YouziImageZoom.fit(pixels: CGSize(width: 100, height: 100),
                                  viewport: CGSize(width: 1000, height: 600), backingScale: 2) == 1)
        #expect(YouziImageZoom.clamped(0) == 0.01)
        #expect(YouziImageZoom.clamped(100) == 16)
        #expect(YouziImageZoom.clamped(.nan) == 1)
    }

    @Test("Decode real PNG to a bounded thumbnail, retaining original dimensions")
    func decodeImage() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("landscape.png")
        try writePNG(to: url)
        let lease = YouziMediaFileLease(url: url)
        let image = try YouziMediaDecoder.image(lease: lease, maxPixels: 200)
        #expect(image.image.width == 200)
        #expect(image.image.height == 100)
        #expect(image.pixels == CGSize(width: 1200, height: 600))
        let thumbnail = try await YouziMediaDecoder.thumbnail(lease: lease, kind: .image)
        #expect(thumbnail.width == 640)
        let corrupt = root.appendingPathComponent("corrupt.png")
        try Data("not an image".utf8).write(to: corrupt)
        #expect(throws: (any Error).self) {
            try YouziMediaDecoder.image(lease: YouziMediaFileLease(url: corrupt), maxPixels: 200)
        }
    }

    @Test("File and workspace grants stay alive after synchronous access and refresh stale bookmarks", arguments: [false, true])
    func leaseLifetime(workspace: Bool) throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("image.png")
        try writePNG(to: url)
        var starts: [URL] = []
        var stops: [URL] = []
        let grant = workspace ? root : url
        let bookmarks = YouziSecurityScopedBookmarkAccess(
            create: { _ in Data("fresh".utf8) },
            resolve: { data in YouziResolvedBookmark(url: grant, isStale: data == Data("stale".utf8)) },
            start: { starts.append($0); return true }, stop: { stops.append($0) }
        )
        let access = YouziWorkspaceAccessCoordinator(managedRoot: root, bookmarks: bookmarks)
        let files = YouziManagedFileStore(root: root, workspaceAccess: access, bookmarks: bookmarks)
        let store = YouziDomainStore(fileURL: root.appendingPathComponent("domain.json"))
        let workspaceRecord = YouziWorkspace(name: "Fixture", location: .securityScopedBookmark(data: Data("stale".utf8), displayPath: root.path))
        let file = YouziFile(displayName: "image.png", role: .artifact, location: workspace
            ? .workspace(workspaceID: workspaceRecord.id, relativePath: "image.png")
            : .securityScopedBookmark(data: Data("stale".utf8), displayPath: url.path))
        try store.save(YouziDomainDocument(workspaces: workspace ? [workspaceRecord] : [], files: [file]))
        let repository = YouziLifecycleRepository(store: store, workspaceAccess: access, fileStore: files)
        var lease: YouziMediaFileLease? = try repository.mediaLease(toFile: file.id)
        #expect(starts == [grant, grant])
        #expect(stops == [grant])
        #expect(try Data(contentsOf: #require(lease).url).count > 0)
        if workspace {
            #expect(try store.load().workspaces[0].location == .securityScopedBookmark(data: Data("fresh".utf8), displayPath: root.path))
        } else {
            #expect(try store.load().files[0].location == .securityScopedBookmark(data: Data("fresh".utf8), displayPath: url.path))
        }
        lease = nil
        #expect(stops == [grant, grant])
    }

    @Test("Unsuccessful security-scope start is never stopped")
    func unsuccessfulGrant() {
        var stopCount = 0
        let bookmarks = YouziSecurityScopedBookmarkAccess(create: { _ in Data() }, resolve: { _ in
            YouziResolvedBookmark(url: URL(fileURLWithPath: "/"), isStale: false)
        }, start: { _ in false }, stop: { _ in stopCount += 1 })
        var lease: YouziMediaFileLease? = YouziMediaFileLease(url: URL(fileURLWithPath: "/"), scope: .init(url: URL(fileURLWithPath: "/"), bookmarks: bookmarks))
        #expect(lease != nil)
        lease = nil
        #expect(stopCount == 0)
    }

    @Test("Missing files and traversal cannot escape through media leases")
    func missingAndTraversal() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = YouziDomainStore(fileURL: root.appendingPathComponent("domain.json"))
        let file = YouziFile(displayName: "missing", role: .artifact, location: .appManaged(relativePath: "missing.png"))
        try store.save(YouziDomainDocument(files: [file]))
        let access = YouziWorkspaceAccessCoordinator(managedRoot: root)
        let repository = YouziLifecycleRepository(store: store, workspaceAccess: access, fileStore: YouziManagedFileStore(root: root, workspaceAccess: access))
        #expect(throws: (any Error).self) { try repository.mediaLease(toFile: file.id) }
        var escaped = file
        escaped.location = .appManaged(relativePath: "../outside.png")
        try store.save(YouziDomainDocument(files: [escaped]))
        #expect(throws: (any Error).self) { try repository.mediaLease(toFile: file.id) }
        let existing = root.appendingPathComponent("present.png")
        try writePNG(to: existing)
        escaped.location = .appManaged(relativePath: "present.png")
        escaped.availability = .revoked
        try store.save(YouziDomainDocument(files: [escaped]))
        #expect(throws: CocoaError(.fileReadNoPermission)) { try repository.mediaLease(toFile: file.id) }
    }

    @Test("Native image canvas fits, zooms to literal 1:1 and centers small images")
    @MainActor func nativeCanvas() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("image.png")
        try writePNG(to: url, width: 4000, height: 2000)
        let decoded = try YouziMediaDecoder.image(lease: YouziMediaFileLease(url: url), maxPixels: 1000)
        let canvas = YouziImageScrollView()
        canvas.frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        canvas.setImage(decoded)
        canvas.layoutSubtreeIfNeeded()
        canvas.apply(.fit)
        #expect(abs(canvas.magnification - 0.4) < 0.02)
        canvas.apply(.actual)
        #expect(canvas.magnification == 1)
        canvas.apply(.in)
        #expect(canvas.magnification == 1.25)
        canvas.apply(.out)
        #expect(canvas.magnification == 1)
        let clip = YouziCenteredImageClipView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        clip.documentView = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        let constrained = clip.constrainBoundsRect(CGRect(x: 0, y: 0, width: 800, height: 600))
        #expect(constrained.origin == CGPoint(x: -300, y: -250))
    }

    @Test("Audio click toggles playback; opening a different media and leaving releases ownership")
    @MainActor func playbackLifecycle() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("tone.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2400))
        buffer.frameLength = 2400
        buffer.floatChannelData?[0].initialize(repeating: 0, count: 2400)
        let audio = try AVAudioFile(forWriting: url, settings: format.settings)
        try audio.write(from: buffer)
        let artifact = YouziArtifact(taskID: UUID(), title: "Narration", kind: .audio, fileID: UUID())
        let controller = YouziArtifactPlayback()
        weak var retained: YouziMediaFileLease?
        await controller.open(artifact) {
            let lease = YouziMediaFileLease(url: url); retained = lease; return lease
        }
        #expect(controller.audioID == artifact.id)
        #expect(controller.isPlaying)
        #expect(retained != nil)
        await controller.open(artifact) { throw CocoaError(.fileNoSuchFile) }
        #expect(!controller.isPlaying)
        #expect(!controller.failed) // A repeated click does not re-open or re-resolve.
        var image = artifact; image.kind = .image
        await controller.open(image) { YouziMediaFileLease(url: url) }
        #expect(controller.audioID == nil)
        #expect(controller.preview?.kind == .image)
        #expect(retained == nil)
        controller.stop()
        #expect(controller.preview == nil)
        await controller.open(artifact) { throw CocoaError(.fileNoSuchFile) }
        #expect(controller.failed)
        #expect(controller.audioID == nil)
    }
    @Test("A late media resolution cannot reopen a closed overlay or replace a newer selection")
    @MainActor func lateResolution() async throws {
        let controller = YouziArtifactPlayback()
        let first = YouziArtifact(taskID: UUID(), title: "First", kind: .image, fileID: UUID())
        let second = YouziArtifact(taskID: UUID(), title: "Second", kind: .image, fileID: UUID())
        var resume: CheckedContinuation<YouziMediaFileLease, Never>?
        let pending = Task { @MainActor in
            await controller.open(first) { await withCheckedContinuation { resume = $0 } }
        }
        while resume == nil { await Task.yield() }
        controller.stop()
        await controller.open(second) { YouziMediaFileLease(url: URL(fileURLWithPath: "/second")) }
        resume?.resume(returning: YouziMediaFileLease(url: URL(fileURLWithPath: "/first")))
        await pending.value
        #expect(controller.preview?.id == second.id)
        #expect(!controller.failed)
        controller.stop()
    }

    private func writeVideo(to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180
        ])
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var pixelBuffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, 320, 180, kCVPixelFormatType_32ARGB,
            [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary,
            &pixelBuffer) == kCVReturnSuccess)
        let buffer = try #require(pixelBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        let context = try #require(CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 320, height: 180,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue))
        context.setFillColor(CGColor(red: 0.15, green: 0.28, blue: 0.65, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
        context.setFillColor(CGColor(red: 1, green: 0.7, blue: 0.4, alpha: 1))
        context.fillEllipse(in: CGRect(x: 100, y: 30, width: 120, height: 120))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        for frame in 0..<2 {
            var attempts = 0
            while !input.isReadyForMoreMediaData && attempts < 200 {
                try await Task.sleep(for: .milliseconds(10)); attempts += 1
            }
            #expect(adapter.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 1)))
        }
        writer.endSession(atSourceTime: CMTime(seconds: 2, preferredTimescale: 600))
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }

    @Test("Real video produces an aspect-correct thumbnail; cancellation does not publish an image")
    func videoThumbnail() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("preview.mov")
        try await writeVideo(to: url)
        let lease = YouziMediaFileLease(url: url)
        let image = try await YouziMediaDecoder.thumbnail(lease: lease, kind: .video)
        #expect(image.width == 320)
        #expect(image.height == 180)
        let cancelled = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await YouziMediaDecoder.thumbnail(lease: lease, kind: .video)
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; Issue.record("Expected cancellation") }
        catch is CancellationError { }
    }

    /// An isolated, opt-in native window with synthetic files only. Never starts
    /// the application runtime, model servers, or reads real task history.
    @Test("Isolated gallery visual QA", .enabled(if: ProcessInfo.processInfo.environment["YOUZI_GALLERY_VISUAL_QA"] == "1"))
    @MainActor func visualGallery() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("landscape.png")
        let video = root.appendingPathComponent("preview.mov")
        let wav = root.appendingPathComponent("silence.wav")
        try writePNG(to: image)
        try await writeVideo(to: video)
        do {
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24000))
            buffer.frameLength = 24000
            buffer.floatChannelData?[0].initialize(repeating: 0, count: 24000)
            let audio = try AVAudioFile(forWriting: wav, settings: format.settings)
            try audio.write(from: buffer)
        }
        let suite = "youzi-gallery-qa-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let i18n = YouziI18nConfig(defaults: defaults)
        i18n.language = .zhHans
        let titles = ["静夜思 · 月下的故乡", "旁白配音 · 第一章", "月光里的故事 · 视频", "静夜思互动话本.html", "项目素材清单.xlsx", "网页源代码.html", "全部成果打包.zip", "这是一份名字比较长的本地成果文件，用于检查两行标题布局"]
        let kinds: [YouziArtifactKind] = [.image, .audio, .video, .document, .spreadsheet, .code, .archive, .other]
        let artifacts = zip(titles, kinds).enumerated().map { index, entry in
            YouziArtifact(taskID: UUID(), title: entry.0, kind: entry.1,
                previewText: [.document, .code].contains(entry.1) ? "床前明月光，疑是地上霜。举头望明月，低头思故乡。" : nil,
                fileID: UUID(), updatedAt: Date(timeIntervalSince1970: Double(100 - index)))
        }
        let view = YouziSimpleResultsPage(artifacts: artifacts,
            fileForArtifact: { artifact in
                YouziFile(id: artifact.fileID, displayName: artifact.title, byteCount: 524288,
                    role: .artifact, location: .appManaged(relativePath: "fixture"), updatedAt: artifact.updatedAt)
            }, onPreview: { _ in }, onRevealInFinder: { _ in }, onExport: { _ in },
            mediaLease: { artifact in
                YouziMediaFileLease(url: artifact.kind == .audio ? wav : artifact.kind == .video ? video : image)
            })
            .environment(i18n).defaultAppStorage(defaults)
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 1040, height: 760),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Youzi Gallery QA — synthetic fixtures"
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("youzi-gallery-visual-qa")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for size in YouziArtifactCardSize.allCases {
            defaults.set(size.rawValue, forKey: "youzi.results.cardSize")
            try await Task.sleep(for: .milliseconds(600))
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("gallery-\(size.rawValue).png"))
        }
        i18n.language = .en
        window.setContentSize(CGSize(width: 720, height: 640))
        try await Task.sleep(for: .milliseconds(600))
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("gallery-narrow-en.png"))
        i18n.language = .zhHans
        defaults.set("medium", forKey: "youzi.results.cardSize")
        window.setContentSize(CGSize(width: 1040, height: 760))
        try await Task.sleep(for: .milliseconds(300))
        func click(x: CGFloat, fromTop y: CGFloat) throws {
            let point = CGPoint(x: x, y: host.bounds.height - y)
            for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
                window.sendEvent(event)
            }
        }
        func capture(_ name: String) throws {
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
        }
        try click(x: 140, fromTop: 240)
        try await Task.sleep(for: .milliseconds(500))
        try capture("image-overlay")
        func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
            if let match = view as? T { return match }
            for child in view.subviews {
                if let match = descendant(type, in: child) { return match }
            }
            return nil
        }
        let canvas = try #require(descendant(YouziImageScrollView.self, in: host))
        canvas.apply(.actual)
        #expect(canvas.magnification == 1)
        let wheel = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                        wheel1: 3, wheel2: 0, wheel3: 0))
        canvas.scrollWheel(with: try #require(NSEvent(cgEvent: wheel)))
        #expect(canvas.magnification > 1)
        for _ in 0..<4 { canvas.apply(.in) }
        let document = try #require(canvas.documentView)
        let beforeDrag = canvas.contentView.bounds.origin
        for (type, point): (NSEvent.EventType, CGPoint) in [
            (.leftMouseDown, CGPoint(x: 400, y: 300)),
            (.leftMouseDragged, CGPoint(x: 430, y: 320)),
            (.leftMouseUp, CGPoint(x: 430, y: 320))
        ] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            switch type {
            case .leftMouseDown: document.mouseDown(with: event)
            case .leftMouseDragged: document.mouseDragged(with: event)
            default: document.mouseUp(with: event)
            }
        }
        #expect(canvas.contentView.bounds.origin != beforeDrag)
        canvas.apply(.fit)
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53))
        window.sendEvent(escape)
        try await Task.sleep(for: .milliseconds(200))
        #expect(descendant(YouziImageScrollView.self, in: host) == nil)
        try click(x: 625, fromTop: 240)
        try await Task.sleep(for: .milliseconds(500))
        let playerView = try #require(descendant(AVPlayerView.self, in: host))
        for _ in 0..<50 {
            if playerView.isReadyForDisplay { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(playerView.isReadyForDisplay)
        #expect(playerView.controlsStyle == .floating)
        #expect(playerView.player?.currentItem?.status == .readyToPlay)
        try capture("video-overlay")
        if ProcessInfo.processInfo.environment["YOUZI_GALLERY_INTERACTIVE_QA"] == "1" {
            try await Task.sleep(for: .seconds(60))
        }
        // A backdrop click closes the player and detaches its AVPlayer item.
        try click(x: 20, fromTop: 200)
        try await Task.sleep(for: .milliseconds(200))
        #expect(descendant(AVPlayerView.self, in: host) == nil)
        #expect(playerView.player == nil)
    }

    @Test("Isolated chat artifact visual QA", .enabled(if: ProcessInfo.processInfo.environment["YOUZI_CHAT_ARTIFACT_VISUAL_QA"] == "1"))
    @MainActor func visualChatArtifacts() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("image.png")
        let video = root.appendingPathComponent("video.mov")
        let audio = root.appendingPathComponent("narration.wav")
        let html = root.appendingPathComponent("storybook.html")
        try writePNG(to: image)
        try await writeVideo(to: video)
        do {
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24000))
            buffer.frameLength = 24000
            buffer.floatChannelData?[0].initialize(repeating: 0, count: 24000)
            try AVAudioFile(forWriting: audio, settings: format.settings).write(from: buffer)
        }
        try Data("<!doctype html><html lang=\"en\"><title>Fixture</title><p>Synthetic storybook</p></html>".utf8).write(to: html)
        let store = YouziDomainStore(fileURL: root.appendingPathComponent("domain.json"))
        let access = YouziWorkspaceAccessCoordinator(managedRoot: root.appendingPathComponent("workspaces"))
        let files = YouziManagedFileStore(root: root.appendingPathComponent("files"), workspaceAccess: access)
        let product = YouziProductModel(store: store, workspaceAccess: access, fileStore: files)
        let draft = try #require(product.createTaskDraft(title: "Synthetic chat QA", request: "Create local media"))
        let conversationID = UUID()
        _ = try #require(product.beginTaskExecution(taskID: draft.id, conversationID: conversationID))
        let suite = "youzi-chat-visual-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let i18n = YouziI18nConfig(defaults: defaults)
        i18n.language = .zhHans
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        let window = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 620, height: 740),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Youzi Chat QA — synthetic fixtures"
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("youzi-chat-artifact-visual-qa")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let fixtures: [(String, YouziArtifactKind, URL)] = [
            ("youzi_generate_image", .image, image), ("youzi_synthesize_speech", .audio, audio),
            ("youzi_generate_video", .video, video), ("youzi_create_storybook", .document, html)
        ]
        for (tool, kind, url) in fixtures {
            let artifact = try #require(product.createArtifact(data: Data(contentsOf: url), named: url.lastPathComponent,
                kind: kind, taskID: draft.id))
            let call = ToolCall(id: "image-call", name: tool, arguments: "{}")
            // Persist/restore the receipt just like reopening a historical chat.
            let result = try JSONDecoder().decode(ChatMessage.self, from:
                JSONEncoder().encode(YouziChatArtifactTests().receipt(artifact)))
            #expect(YouziChatArtifactReceipt.resolve(call: call, result: result, taskID: draft.id,
                artifact: product.artifact(id:))?.id == artifact.id)
            for pending in [true, false] {
                host.rootView = AnyView(
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(i18n.text(zh: "请帮我生成多媒体内容", en: "Please create local media")).font(.title3)
                            ToolCallChip(call: call, result: pending ? nil : result)
                            YouziChatArtifactCard(call: call, result: pending ? nil : result, conversationID: conversationID)
                            Text(i18n.text(zh: "正在处理…", en: "Working…")).foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(RapidTheme.surfaceCanvas)
                    .modifier(YouziChatMediaPresentation(conversationID: conversationID))
                    .environment(product).environment(i18n).defaultAppStorage(defaults)
                )
                try await Task.sleep(for: .milliseconds(700))
                host.layoutSubtreeIfNeeded()
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                    output.appendingPathComponent("chat-\(kind.rawValue)-\(pending ? "pending" : "complete").png"))
            }
            i18n.language = .en
            window.setContentSize(CGSize(width: 320, height: 740))
            try await Task.sleep(for: .milliseconds(400))
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to:
                output.appendingPathComponent("chat-\(kind.rawValue)-narrow-en.png"))
            i18n.language = .zhHans
            window.setContentSize(CGSize(width: 620, height: 740))
        }
    }

}
