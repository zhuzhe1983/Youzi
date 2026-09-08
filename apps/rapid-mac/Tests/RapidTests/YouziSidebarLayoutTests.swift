import AppKit
import SwiftUI
import Testing
@testable import Rapid

@Suite("Youzi sidebar viewport and collection navigation")
struct YouziSidebarLayoutTests {
    @Test("Collapsed viewports fit whole rows and never exceed five", arguments: [CGFloat(400), 600, 900, 1200, 1800])
    @MainActor func budgets(height: CGFloat) {
        for scale: CGFloat in [0.88, 1, 1.12, 1.25] {
            let m = YouziSidebarMetrics(height: height, scale: scale)
            #expect((0...5).contains(m.visibleRows))
            #expect(m.listHeight <= m.bodyHeight)
            #expect(abs(m.brandHeight + m.footerHeight + 2 + m.sectionHeight + m.gap + m.listsHeight - height) < 0.01)
            #expect(m.footerHeight >= 44)
        }
        #expect(YouziSidebarMetrics(height: 600, scale: 1).visibleRows < 5)
        #expect(YouziSidebarMetrics(height: 1200, scale: 1).visibleRows == 5)
    }

    @Test("Task collection searches all nonarchived tasks, preserving pin ordering")
    func taskCollection() {
        let now = Date()
        var tasks: [YouziTask] = []
        for index in 0..<22 {
            var task = YouziTask(title: "Task \(index)", request: "")
            task.status = index == 21 ? .archived : .draft
            task.isPinned = index == 0
            task.updatedAt = now.addingTimeInterval(Double(index))
            tasks.append(task)
        }
        let all = YouziTaskListQuery().apply(to: tasks)
        #expect(all.count == 21)
        #expect(all.first?.id == tasks[0].id)
        #expect(YouziTaskListQuery(search: " task 19 ").apply(to: tasks).map(\.id) == [tasks[19].id])
        #expect(YouziTaskListQuery(pinnedOnly: true).apply(to: tasks).map(\.id) == [tasks[0].id])
        #expect(YouziTaskListQuery(search: "missing").apply(to: tasks).isEmpty)
    }

    @Test("Synthetic layout renders short/tall, expanded and English states", .enabled(if: ProcessInfo.processInfo.environment["YOUZI_SIDEBAR_VISUAL_QA"] == "1"))
    @MainActor func visualSidebarLayout() async throws {
        let suite = "youzi-sidebar-qa-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let i18n = YouziI18nConfig(defaults: defaults)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("youzi-sidebar-visual-qa")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let host = NSHostingView(rootView: AnyView(EmptyView()))
        let window = NSWindow(contentRect: CGRect(x: 50, y: 50, width: 1120, height: 900),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Youzi Layout QA — synthetic data"
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }
        for (name, height, expanded, workspaceExpanded, english) in [
            ("tall", 1000.0, false, false, false),
            ("short", 600.0, false, false, false),
            ("expanded", 760.0, true, false, false),
            ("workspaces-expanded", 760.0, false, true, false),
            ("both-expanded", 760.0, true, true, false),
            ("english", 760.0, false, false, true),
        ] {
            i18n.language = english ? .en : .zhHans
            window.setContentSize(CGSize(width: 1120, height: height))
            host.rootView = AnyView(SidebarLayoutFixture(expanded: expanded, workspacesExpanded: workspaceExpanded)
                .id(name) // New State identity for each independent layout fixture.
                .environment(i18n).defaultAppStorage(defaults))
            try await Task.sleep(for: .milliseconds(500))
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("sidebar-\(name).png"))
        }
    }
}

private struct SidebarLayoutFixture: View {
    @Environment(YouziI18nConfig.self) private var i18n
    @State var expanded: Bool
    @State var workspacesExpanded: Bool
    var body: some View {
        HStack(spacing: 0) {
            GeometryReader { proxy in
                let m = YouziSidebarMetrics(height: proxy.size.height, scale: RapidFont.fontScale)
                VStack(spacing: 0) {
                    Text("柚子").frame(height: m.brandHeight)
                    Divider()
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(YouziSimpleDestination.primaryNavigation) { d in
                            Label(d.localizedTitle(isChinese: i18n.isChinese), systemImage: d.systemImage)
                        }
                    }.frame(height: m.sectionHeight).padding(.bottom, m.gap)
                    ScrollView {
                        LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                            YouziSidebarSection(title: i18n.text(zh: "任务", en: "Tasks"), id: "Tasks", metrics: m,
                                expanded: $expanded, onMore: {}, bottomSpacing: m.gap) {
                                    rows("Task", m: m)
                                }
                            YouziSidebarSection(title: i18n.text(zh: "工作空间与项目", en: "Workspaces & Projects"), id: "Workspaces", metrics: m,
                                expanded: $workspacesExpanded, onMore: {}) { rows("Workspace", m: m) }
                        }.padding(.horizontal, 8)
                    }.frame(height: m.listsHeight)
                    Divider()
                    Text("柚子   简约   ⌃").frame(height: m.footerHeight)
                }
            }.frame(width: 240).background(RapidTheme.surfaceSidebar)
            YouziCenteredWelcome {
                VStack(spacing: 32) {
                    YouziLogo(size: 80)
                    Text(i18n.text(zh: "今天想让我帮你做什么？", en: "What would you like to do today?"))
                        .font(RapidFont.displayTitle).multilineTextAlignment(.center)
                    Text("Synthetic composer — no model service")
                        .frame(maxWidth: 680).frame(height: 145)
                        .background(RapidTheme.surfaceSidebar, in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }.background(RapidTheme.surfaceCanvas)
    }
    private func rows(_ prefix: String, m: YouziSidebarMetrics) -> some View {
        VStack(alignment: .leading, spacing: m.rowSpacing) {
            ForEach(1...22, id: \.self) { n in
                Label("\(prefix) \(n)", systemImage: "folder")
                    .frame(maxWidth: .infinity, alignment: .leading).frame(height: m.rowHeight)
            }
        }
    }
}
