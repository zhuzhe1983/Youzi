import AppKit
import SwiftUI
import Testing
@testable import Rapid

@Suite("Tray resource card")
struct YouziTrayResourceTests {
    @Test func translatingStateDoesNotRewriteModelNames() {
        #expect(MenuBarStatus.statusLine(state: .ready(alias: "Ready-Idle-LLM"), isChinese: true)
            == "Ready-Idle-LLM · 就绪")
        #expect(MenuBarStatus.statusLine(state: .starting(alias: ""), isChinese: true) == "启动中…")
    }

    @Test func unknownAndOutOfRangeMetrics() {
        #expect(YouziTraySnapshot.boundedPercent(.infinity) == nil)
        #expect(YouziTraySnapshot.boundedPercent(-50) == 0)
        #expect(YouziTraySnapshot.boundedPercent(250) == 100)
        #expect(YouziTraySnapshot.percent(24.6) == "25%")
        #expect(YouziTraySnapshot.percent(nil) == "—")
    }

    @Test func busyModelsStayInDetailsButLoadingAndFailedDoNot() {
        let snapshot = Self.snapshot()
        let lines = YouziTraySnapshot.modelLines(residency: snapshot, isChinese: false)
        #expect(lines.count == 5) // LLM, image, video, ASR, TTS (deduplicated).
        #expect(lines.contains { $0.contains("tts") })
        #expect(!lines.contains { $0.contains("not-ready") })
        let occupancy = YouziModelOccupancy.resolve(residency: snapshot, host: nil, voiceLaneResident: false)
        #expect(occupancy.voiceMemoryUnknown)
        #expect(occupancy.voiceBytes == 0)
    }

    @Test func unavailableBackendUsesHostFreeMemoryNotTotalMemory() {
        let result = YouziModelOccupancy.resolve(residency: .empty,
            host: .init(totalBytes: 128 << 30, usedBytes: 69 << 30), voiceLaneResident: false)
        #expect(result.remainingBytes == 59 << 30)
    }

    @Test func pendingAndFailedAllocationsDoNotAppearAsLoadedMemory() {
        let model = ResidentModelStatus(id: "pending", modelPath: "pending", aliases: [], modality: "text",
            state: "loading", pinned: true, primary: false, activeRequests: 0,
            estimatedBytes: 20 << 30, measuredBytes: nil, idleSeconds: 0)
        let snapshot = ModelResidencySnapshot(memoryLimitBytes: 100 << 30, memoryUsedBytes: 0,
            memoryAvailableBytes: 80 << 30, idleTTLSeconds: 0, loadsTotal: 0, evictionsTotal: 0, models: [model])
        let result = YouziModelOccupancy.resolve(residency: snapshot, host: nil, voiceLaneResident: false)
        #expect(result.chatBytes == 0)
        #expect(!snapshot.containsTextOrMLLM)
    }

    @Test func oneCardOneDisclosureAndAllActionsPreserved() {
        for chinese in [false, true] {
            let items = MenuBarStatus.menuItems(state: .ready(alias: "model"), hasUpdate: false,
                updateVersion: "", checking: false, baseURL: "http://localhost:8000/v1",
                hasAPIKey: false, isChinese: chinese)
            #expect(items.filter { if case .resources = $0 { true } else { false } }.count == 1)
            #expect(items.filter { if case .models = $0 { true } else { false } }.count == 1)
            #expect(items.contains(.resources(chinese ? "model · 就绪" : "model · Ready")))
            #expect(items.contains(.button(.copyAPIKey, title: chinese ? "复制 API Key" : "Copy API Key",
                                           enabled: false, shortcut: nil)))
            for action in [MenuBarStatus.MenuBarAction.open, .newChat, .copyEndpoint, .settings, .quit] {
                #expect(items.contains { if case .button(let value, _, true, _) = $0 { value == action } else { false } })
            }
        }
    }

    static func snapshot() -> ModelResidencySnapshot {
        let gb: UInt64 = 1 << 30
        let models = [("chat", "text", "busy", 22), ("image", "image-gen", "resident", 7),
                      ("video", "video-gen", "resident", 50), ("tts", "audio", "busy", 0),
                      ("not-ready", "audio", "loading", 0)].map { name, modality, state, bytes in
            ResidentModelStatus(id: name, modelPath: "example/\(name)", aliases: [name], modality: modality,
                state: state, pinned: true, primary: name == "chat", activeRequests: 0,
                estimatedBytes: UInt64(bytes) * gb, measuredBytes: nil, idleSeconds: 0)
        }
        return .init(memoryLimitBytes: 106 * gb, memoryUsedBytes: 79 * gb, memoryAvailableBytes: 22 * gb,
            idleTTLSeconds: 0, loadsTotal: 0, evictionsTotal: 0, models: models,
            audioLanes: [.init(lane: "tts", model: "example/tts", state: "busy"),
                         .init(lane: "asr", model: "example/whisper", state: "resident")])
    }
}

@MainActor
@Suite("Tray resource visual QA", .serialized)
struct YouziTrayResourceVisualTests {
    @Test("Render Chinese/English light/dark cards, including no telemetry", .enabled(if: ProcessInfo.processInfo.environment["YOUZI_TRAY_VISUAL_QA"] == "1"))
    func render() async throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("youzi-tray-qa")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for chinese in [true, false] {
            for dark in [true, false] {
                for ready in [true, false] {
                    let state: ServerState = ready ? .ready(alias: "qwen3.8-27b-4bit-long-model-name") : .idle
                    let view = YouziTrayResourceCard(
                        status: MenuBarStatus.statusLine(state: state, isChinese: chinese), state: state,
                        residency: ready ? YouziTrayResourceTests.snapshot() : .empty,
                        cpu: ready ? 24 : nil, gpu: ready ? 19 : nil,
                        memory: ready ? .init(totalBytes: 128 << 30, usedBytes: 69 << 30) : nil,
                        isChinese: chinese)
                        .background(Color(nsColor: .windowBackgroundColor))
                    let host = NSHostingView(rootView: view)
                    host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0,
                        width: YouziTrayResourceCard.width, height: YouziTrayResourceCard.height),
                        styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.contentView = host
                    defer { window.close() }
                    try await Task.sleep(for: .milliseconds(150))
                    host.layoutSubtreeIfNeeded()
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let name = "\(chinese ? "zh" : "en")-\(dark ? "dark" : "light")-\(ready ? "ready" : "empty").png"
                    try #require(bitmap.representation(using: .png, properties: [:]))
                        .write(to: output.appendingPathComponent(name))
                    #expect(host.bounds.size == NSSize(width: 400, height: 152))
                }
            }
        }
    }
}
