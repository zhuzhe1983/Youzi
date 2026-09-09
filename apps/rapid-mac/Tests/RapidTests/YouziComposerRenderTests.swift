import AppKit
import SwiftUI
import Testing
@testable import Rapid

@Suite("Youzi composer rendering", .serialized)
@MainActor
struct YouziComposerRenderTests {
    @Test("Shared controls, equal-sector orbs and mixed rows fit all font sizes and both themes",
          .enabled(if: ProcessInfo.processInfo.environment["YOUZI_COMPOSER_RENDER"] == "1"))
    func render() async throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("youzi-composer-visual-qa")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for language in [AppLanguage.zhHans, .en] {
            for size in YouziFontSize.allCases {
                for dark in [false, true] {
                    let suite = "youzi-composer-render-\(UUID())"
                    let defaults = try #require(UserDefaults(suiteName: suite))
                    defer { defaults.removePersistentDomain(forName: suite) }
                    let i18n = YouziI18nConfig(defaults: defaults); i18n.language = language
                    let fonts = YouziFontSizeConfig(defaults: defaults); fonts.size = size
                    var actions = 0
                    let width = YouziScenarioModelToolbar.panelWidth(scale: size.scale)
                    let view = VStack(spacing: 12) {
                        YouziScenarioModelToolbar(selectedKind: .constant(.chat)) { actions += 1 }
                        VStack(spacing: 4) {
                            YouziScenarioModelRow(title: "Qwen · local-resident-selected", detail: "18.4 GB", resident: true, selected: true)
                            YouziScenarioModelRow(title: "Qwen · local-resident-other", detail: "9.2 GB", resident: true)
                            YouziScenarioModelRow(title: "Qwen · downloaded-not-loaded", detail: "Disk 4.6 GB")
                            YouziScenarioModelRow(title: "Remote model with a very long display name", remoteStatus: .online, selected: true)
                            YouziScenarioModelRow(title: "Remote offline", remoteStatus: .offline)
                            YouziScenarioModelRow(title: "Remote checking", remoteStatus: .checking)
                        }
                        Divider()
                        HStack(spacing: 16) {
                            ForEach(0...4, id: \.self) { count in
                                YouziModelAvailabilityOrb(lanes: Array(YouziModelLane.allCases.prefix(count)))
                            }
                        }
                        HStack(spacing: 4) {
                            Text(i18n.text(zh: "发送 / 停止 / 语音", en: "Send / Stop / Voice")).font(fonts.font(12))
                            Spacer()
                            YouziComposerIconButton(symbol: "arrow.up", label: "Send") { actions += 1 }
                            YouziComposerIconButton(symbol: "stop.fill", label: "Stop") { actions += 1 }
                            YouziLiveVoiceButton(isPresented: .constant(false), compact: true)
                        }
                        HStack(spacing: 4) {
                            Text(i18n.text(zh: "输入为空", en: "Empty draft")).font(fonts.font(12))
                            Spacer()
                            YouziComposerIconButton(symbol: "arrow.up", label: "Send", enabled: false) { actions += 1 }
                            YouziLiveVoiceButton(isPresented: .constant(false), compact: true)
                        }
                    }
                    .padding(16).frame(width: width)
                    .environment(i18n).environment(fonts).environment(\.colorScheme, dark ? .dark : .light)
                    .background(RapidTheme.surfaceCanvas)
                    let host = NSHostingView(rootView: view)
                    let frame = CGRect(x: 0, y: 0, width: width, height: 560)
                    host.sizingOptions = []; host.frame = frame
                    let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    window.contentView = host; window.orderBack(nil)
                    defer { window.orderOut(nil); window.contentView = nil; window.close() }
                    try await Task.sleep(for: .milliseconds(90))
                    host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                    #expect(host.fittingSize.width <= width + 1)
                    #expect(host.fittingSize.height <= 561)
                    #expect(actions == 0)
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let png = try #require(bitmap.representation(using: .png, properties: [:]))
                    try png.write(to: output.appendingPathComponent("\(language.rawValue)-\(size.rawValue)-\(dark ? "dark" : "light").png"))
                }
            }
        }
    }
}
