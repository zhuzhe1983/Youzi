import AppKit
import CoreGraphics
import SwiftUI
import Testing
@testable import Rapid

@MainActor
@Suite("Youzi compact account menu rendering", .serialized)
struct YouziAccountMenuRenderTests {
    @Test("Native mode segments switch both directions; menus fit every language and font size",
          .enabled(if: ProcessInfo.processInfo.environment["YOUZI_ACCOUNT_MENU_RENDER"] == "1"))
    func renderAndSwitch() async throws {
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["YOUZI_ACCOUNT_MENU_RENDER_DIR"] ?? "/tmp/youzi-account-menu-render")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for isChinese in [true, false] {
            for size in YouziFontSize.allCases {
                for initialMode in YouziExperienceMode.allCases {
                    let suite = "youzi-account-render-" + UUID().uuidString
                    let defaults = try #require(UserDefaults(suiteName: suite))
                    defer { defaults.removePersistentDomain(forName: suite) }
                    let config = YouziExperienceModeConfig(defaults: defaults)
                    config.mode = initialMode
                    var unrelatedActions = 0
                    let mode = Binding(get: { config.mode }, set: { config.mode = $0 })
                    let panel = YouziAccountMenuContent(mode: mode, appearance: .constant(.system),
                        isChinese: isChinese, scale: size.scale,
                        openSettings: { unrelatedActions += 1 }, checkForUpdates: { unrelatedActions += 1 }) {
                            // Synthetic status only — no server, probes or model inference.
                            Text("RAM 55% · CPU 4% · GPU 10% · AIO")
                                .font(.system(size: 11 * size.scale, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    let width = type(of: panel).panelWidth(isChinese: isChinese, scale: size.scale)
                    let scheme: ColorScheme = initialMode == .simple ? .dark : .light
                    let view = VStack(alignment: .leading, spacing: 16) {
                        panel
                        YouziAccountMenuTrigger(mode: config.mode, isChinese: isChinese, scale: size.scale)
                            .frame(width: 224 * max(1, size.scale))
                            .padding(.horizontal, 12)
                    }
                    .environment(\.colorScheme, scheme)
                    .background(RapidTheme.surfaceCanvas)
                    let host = NSHostingView(rootView: view)
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 292 * max(1, size.scale)),
                        styleMask: [.titled], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                    window.contentView = host; window.orderBack(nil)
                    defer { window.orderOut(nil); window.contentView = nil; window.close() }
                    try await Task.sleep(for: .milliseconds(180))
                    host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                    #expect(host.fittingSize.width <= width + 1)
                    #expect(host.fittingSize.height <= 292 * max(1, size.scale))
                    let controls = segments(in: host)
                    let selector = try #require(controls.first { $0.segmentCount == 2 })
                    #expect(controls.filter { $0.segmentCount == 2 }.count == 1)
                    #expect(controls.filter { $0.segmentCount == 3 }.count == 1)
                    #expect(selector.selectedSegment == (initialMode == .simple ? 0 : 1))
                    for index in [1, 0, 1, 0] {
                        selector.selectedSegment = index
                        #expect(selector.sendAction(selector.action, to: selector.target))
                        try await Task.sleep(for: .milliseconds(30))
                        #expect(config.mode == (index == 0 ? .simple : .professional))
                        #expect(YouziExperienceModeConfig(defaults: defaults).mode == config.mode)
                    }
                    selector.selectedSegment = initialMode == .simple ? 0 : 1
                    _ = selector.sendAction(selector.action, to: selector.target)
                    #expect(unrelatedActions == 0)
                    try await Task.sleep(for: .milliseconds(50))
                    let name = "\(isChinese ? "zh" : "en")-\(size.rawValue)-\(initialMode.rawValue)"
                    try capture(window, to: root.appendingPathComponent(name + ".png"))
                }
            }
        }
    }

    private func segments(in view: NSView) -> [NSSegmentedControl] {
        (view as? NSSegmentedControl).map { [$0] } ?? view.subviews.flatMap { segments(in: $0) }
    }

    private func capture(_ window: NSWindow, to url: URL) throws {
        guard ProcessInfo.processInfo.environment["YOUZI_ACCOUNT_MENU_WINDOW_CAPTURE"] == "1",
              CGPreflightScreenCaptureAccess() else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), url.path]
        try process.run(); process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
