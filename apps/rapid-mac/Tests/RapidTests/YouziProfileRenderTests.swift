import AppKit
import SwiftUI
import Testing
@testable import Rapid

@Suite("Youzi personalized profile rendering", .serialized)
@MainActor
struct YouziProfileRenderTests {
    @Test("Profile updates without replacing its hosting view and stays compact",
          .enabled(if: ProcessInfo.processInfo.environment["YOUZI_PROFILE_VISUAL_QA"] == "1"))
    func profileRendering() async throws {
        let suite = "youzi-profile-render-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let config = CustomInstructionsConfig(defaults: defaults)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("youzi-profile-visual-qa")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for chinese in [true, false] {
            for size in YouziFontSize.allCases {
                for mode in YouziExperienceMode.allCases {
                    let frame = CGRect(x: 0, y: 0, width: 256, height: 60)
                    let host = NSHostingView(rootView: ProfileFixture(mode: mode, chinese: chinese, scale: size.scale)
                        .environment(config)
                        .environment(\.colorScheme, .dark))
                    host.sizingOptions = []
                    host.frame = frame
                    let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.appearance = NSAppearance(named: .darkAqua)
                    window.backgroundColor = .windowBackgroundColor
                    window.contentView = host
                    window.orderBack(nil)
                    defer { window.orderOut(nil); window.contentView = nil; window.close() }
                    var images: [Data] = []
                    // Same root and same config: SwiftUI must observe each edit.
                    for (name, address) in [("empty", ""), ("name", chinese ? "测试用户" : "Alex"),
                                             ("long", String(repeating: chinese ? "长称呼" : "LongName", count: 12)),
                                             ("cleared", "  \n\t ")] {
                        config.userAddress = address
                        try await Task.sleep(for: .milliseconds(65))
                        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                        #expect(host.fittingSize.width <= frame.width + 1)
                        #expect(host.fittingSize.height <= frame.height + 1)
                        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                        host.cacheDisplay(in: host.bounds, to: bitmap)
                        let data = try #require(bitmap.representation(using: .png, properties: [:]))
                        images.append(data)
                        try data.write(to: output.appendingPathComponent("\(chinese ? "zh" : "en")-\(size.rawValue)-\(mode.rawValue)-\(name).png"))
                    }
                    #expect(images[0] != images[1])
                    #expect(images[1] != images[2])
                    #expect(images[0] == images[3])
                }
            }
        }
    }
}

@MainActor
private struct ProfileFixture: View {
    @Environment(CustomInstructionsConfig.self) private var personalization
    let mode: YouziExperienceMode
    let chinese: Bool
    let scale: CGFloat

    var body: some View {
        YouziAccountMenuTrigger(mode: mode, isChinese: chinese, scale: scale,
            userAddress: personalization.userAddress)
            .frame(width: 256, height: 60)
            .background(RapidTheme.surfaceCanvas)
    }
}
