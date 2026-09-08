import AppKit
import CoreGraphics
import SwiftUI
import Testing
@testable import Rapid

@Suite("Youzi model table native rendering", .serialized)
@MainActor
struct YouziModelTableRenderTests {
    @Test("Native table renders Chinese/English, light/dark and large text without replacing the running app",
          .enabled(if: ProcessInfo.processInfo.environment["YOUZI_MODEL_TABLE_RENDER"] == "1"))
    func render() async throws {
        typealias Data = YouziModelTableData
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["YOUZI_MODEL_TABLE_RENDER_DIR"] ?? "/tmp/youzi-model-table-render")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (language, scheme, size, width, name) in [
            (AppLanguage.zhHans, ColorScheme.dark, YouziFontSize.medium, CGFloat(1040), "zh-dark"),
            (.en, .light, .medium, 1040, "en-light"),
            (.zhHans, .light, .extraLarge, 620, "zh-large-narrow"),
            (.en, .dark, .small, 620, "en-small-narrow")
        ] {
            let suite = "youzi-model-table-render-" + UUID().uuidString
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let i18n = YouziI18nConfig(defaults: defaults); i18n.language = language
            let fonts = YouziFontSizeConfig(defaults: defaults); fonts.size = size
            let aliases = ["qwen3.8-27b-4bit", "qwen3.6-35b-4bit", "gemma-4-12b-8bit", "custom-unbenchmarked"]
            let rows: [Data.Row] = (0..<32).map { index in
                let alias = index < 4 ? aliases[index] : "test-model-\(index)b-4bit"
                let cached = index == 0 || index == 2
                let entry = ModelEntry(alias: alias, hfRepo: "test/\(alias)", sizeOnDisk: cached ? "20.0 GiB" : nil, cached: cached)
                return Data.Row(entry: entry, badge: index == 4 ? .downloading(percent: 42) : (cached ? .cached : .notCached), loaded: index == 0,
                                recommendationRank: index < 2 ? index : nil,
                                scores: index < 3 ? BenchScores(generalReasoning: 80, generalReasoningSource: "fixture", mmluPro: nil, gpqaDiamond: nil,
                                    code: 70, tool: 90, ifeval: 88, speedTps: 45, speedSource: "Fixture hardware — not a benchmark claim") : nil)
            }
            var actionCount = 0
            let view = YouziModelTableView(rows: rows, hardwareDescription: "128 GB · Fixture Mac",
                download: { _ in actionCount += 1 }, cancel: { _ in actionCount += 1 }, load: { _ in actionCount += 1 },
                delete: { _ in actionCount += 1 }, favorite: { _ in actionCount += 1 })
                .environment(i18n).environment(fonts).environment(\.colorScheme, scheme)
                .padding(20).frame(width: width).background(RapidTheme.surfaceCanvas)
            let host = NSHostingView(rootView: view)
            let height: CGFloat = size == .extraLarge ? 900 : 660
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentView = host
            window.orderBack(nil)
            defer { window.orderOut(nil); window.contentView = nil; window.close() }
            try await Task.sleep(for: .milliseconds(250))
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            let table = try #require(findTable(host))
            #expect(table.tableColumns.count == 10 && table.numberOfRows == rows.count)
            #expect(table.headerView != nil && table.allowsColumnResizing && table.allowsColumnReordering)
            #expect(table.tableColumns.filter { $0.sortDescriptorPrototype != nil }.count == 9)
            #expect(table.rowHeight >= 52)
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: root.appendingPathComponent(name + ".png"))
            try captureWindow(window, to: root.appendingPathComponent(name + "-window.png"))
            if name == "en-light", let scroll = table.enclosingScrollView {
                // Use the table's public scrolling API, not a raw clip-view
                // origin mutation that bypasses native header synchronization.
                table.scrollColumnToVisible(table.numberOfColumns - 1)
                try await Task.sleep(for: .milliseconds(150))
                let header = try #require(table.headerView)
                #expect(abs(table.convert(.zero, to: scroll).x - header.convert(.zero, to: scroll).x) < 1)
                try captureWindow(window, to: root.appendingPathComponent(name + "-metrics-window.png"))
            }
            // Exercise a real column sort callback, not a separate mock grid.
            table.sortDescriptors = [NSSortDescriptor(key: "size", ascending: false)]
            try await Task.sleep(for: .milliseconds(80))
            #expect(table.numberOfRows == rows.count)
            #expect(actionCount == 0, "Sorting/rendering must never load/download/delete a model")
        }
    }

    @Test("Scenario tabs and settings share one row in both languages at every font size",
          .enabled(if: ProcessInfo.processInfo.environment["YOUZI_MODEL_TABLE_RENDER"] == "1"))
    func scenarioToolbar() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["YOUZI_MODEL_TABLE_RENDER_DIR"] ?? "/tmp/youzi-model-table-render")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for language in [AppLanguage.zhHans, .en] {
            for size in YouziFontSize.allCases {
                let suite = "youzi-scenario-render-" + UUID().uuidString
                let defaults = try #require(UserDefaults(suiteName: suite))
                defer { defaults.removePersistentDomain(forName: suite) }
                let i18n = YouziI18nConfig(defaults: defaults); i18n.language = language
                let fonts = YouziFontSizeConfig(defaults: defaults); fonts.size = size
                var actionCount = 0
                let width = YouziScenarioModelToolbar.panelWidth(scale: size.scale)
                let view = YouziScenarioModelToolbar(selectedKind: .constant(.chat), moreModelSettings: { actionCount += 1 })
                    .environment(i18n).environment(fonts).environment(\.colorScheme, .light)
                    .padding(16).background(RapidTheme.surfaceCanvas)
                let host = NSHostingView(rootView: view)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 90),
                    styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: .aqua)
                window.contentView = host; window.orderBack(nil)
                defer { window.orderOut(nil); window.contentView = nil; window.close() }
                try await Task.sleep(for: .milliseconds(180))
                host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                #expect(host.fittingSize.width <= width + 1, "Toolbar must fit without truncation")
                #expect(host.fittingSize.height <= 70, "Tabs and settings must occupy one row")
                #expect(actionCount == 0)
                try captureWindow(window, to: root.appendingPathComponent("scenario-\(language.rawValue)-\(size.rawValue).png"))
            }
        }
    }

    @Test("Title-free memory header fits both languages without triggering refresh",
          .enabled(if: ProcessInfo.processInfo.environment["YOUZI_MODEL_TABLE_RENDER"] == "1"))
    func memoryHeader() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["YOUZI_MODEL_TABLE_RENDER_DIR"] ?? "/tmp/youzi-model-table-render")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let occupancy = YouziModelOccupancy(chatBytes: 22 << 30, imageBytes: 0, voiceBytes: 0,
            videoBytes: 0, remainingBytes: 80 << 30, totalBytes: 128 << 30, hostUsedRatio: 0.375, mode: .llm)
        for language in [AppLanguage.zhHans, .en] {
            let suite = "youzi-memory-header-render-" + UUID().uuidString
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let i18n = YouziI18nConfig(defaults: defaults); i18n.language = language
            let fonts = YouziFontSizeConfig(defaults: defaults)
            var refreshCount = 0
            let view = VStack(spacing: 12) {
                YouziScenarioModelMemoryHeader(occupancy: occupancy, refreshing: false) { refreshCount += 1 }
                YouziScenarioModelToolbar(selectedKind: .constant(.video), moreModelSettings: {})
            }.environment(i18n).environment(fonts).environment(\.colorScheme, .dark)
                .padding(16).background(RapidTheme.surfaceCanvas)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 110),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host; window.orderBack(nil)
            defer { window.orderOut(nil); window.contentView = nil; window.close() }
            try await Task.sleep(for: .milliseconds(180))
            host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
            #expect(host.fittingSize.width <= 441)
            #expect(host.fittingSize.height <= 110, "No blank title row above memory bar")
            #expect(refreshCount == 0)
            try captureWindow(window, to: root.appendingPathComponent("memory-header-\(language.rawValue).png"))
        }
    }

    /// AppKit's bitmap cache omits some layer-backed menu controls. Optional
    /// compositor captures target only this fixture window; never request access.
    private func captureWindow(_ window: NSWindow, to url: URL) throws {
        guard ProcessInfo.processInfo.environment["YOUZI_MODEL_TABLE_WINDOW_CAPTURE"] == "1",
              CGPreflightScreenCaptureAccess() else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), url.path]
        try process.run(); process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    private func findTable(_ view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for child in view.subviews { if let found = findTable(child) { return found } }
        return nil
    }
}
