import Foundation
import Testing
@testable import Rapid

@Suite("Youzi account menu")
struct YouziAccountMenuTests {
    private static func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    @Test("Badge and segments use short labels, accessibility retains full mode names")
    func compactLabels() {
        #expect(YouziExperienceMode.allCases.map { $0.localizedShortDisplayName(isChinese: true) } == ["简约", "专业"])
        #expect(YouziExperienceMode.allCases.map { $0.localizedShortDisplayName(isChinese: false) } == ["Simple", "Pro"])
        #expect(YouziExperienceMode.professional.localizedDisplayName(isChinese: false) == "Professional Mode")
    }

    @Test("Account menu is the shared uncommon-action entry")
    @MainActor
    func sharedEntryContract() throws {
        let menu = try Self.source("Sources/Rapid/UI/YouziAccountMenu.swift")
        let surface = try Self.source("Sources/Rapid/UI/YouziAccountMenuContent.swift")
        let content = try Self.source("Sources/Rapid/UI/ContentView.swift")
        let simple = try Self.source("Sources/Rapid/UI/YouziSimple/YouziSimpleShell.swift")
        let sidebar = try Self.source("Sources/Rapid/UI/SidebarView.swift")

        for label in ["设置", "外观", "检查更新"] {
            #expect(surface.contains(label))
        }
        #expect(menu.contains("系统状态"))
        #expect(!surface.contains("帮助与反馈"))
        #expect(!surface.contains("本机单机运行"))
        #expect(!surface.contains("切换到"))
        #expect(!menu.contains("Youzi.AccountMenu.Help"))
        #expect(surface.contains("Youzi.AccountMenu.ModeBadge"))
        #expect(surface.contains("Youzi.AccountMenu.ExperienceMode"))
        #expect(surface.contains("selection: $mode"))
        #expect(surface.contains(".pickerStyle(.segmented)"))
        #expect(menu.contains("experienceMode.mode = next"))
        #expect(!menu.contains("experienceMode.mode.other"))
        #expect(menu.contains("openWindow(id: \"settings\")"))
        #expect(surface.contains("Youzi.AccountMenu.Settings"))
        #expect(menu.contains("Youzi.AccountMenu.SystemStatus"))
        #expect(!menu.contains("OpenSettingsAction"))
        #expect(!menu.contains("Logout"))
        #expect(!menu.contains("登出"))
        #expect(!menu.contains("个人主页"))

        #expect(menu.contains("var arrowEdge: Edge = .bottom"))
        #expect(content.contains("YouziAccountMenu()"))
        #expect(content.contains("YouziAccountMenu(arrowEdge: .top)"))
        #expect(content.contains("RapidTheme.Radius.card"))
        #expect(simple.contains("YouziAccountMenu()"))
        #expect(!sidebar.contains("YouziAccountMenu"))
        #expect(content.contains("The account menu lives outside SidebarView"))
        #expect(sidebar.contains("Text(\"柚子\")"))
        #expect(!sidebar.contains("Text(\"Youzi\")"))
    }
}
