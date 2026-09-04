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

    @Test("Account menu is the shared uncommon-action entry")
    func sharedEntryContract() throws {
        let menu = try Self.source("Sources/Rapid/UI/YouziAccountMenu.swift")
        let content = try Self.source("Sources/Rapid/UI/ContentView.swift")
        let simple = try Self.source("Sources/Rapid/UI/YouziSimple/YouziSimpleShell.swift")
        let sidebar = try Self.source("Sources/Rapid/UI/SidebarView.swift")

        #expect(YouziAccountMenu.helpURL.absoluteString == "https://github.com/zhuzhe1983/Youzi/issues")
        #expect(menu.contains("title: \"设置\""))
        #expect(menu.contains("Label(\"外观\""))
        #expect(menu.contains("Label(\"系统状态\""))
        #expect(menu.contains("title: \"检查更新\""))
        #expect(menu.contains("title: \"帮助与反馈\""))
        #expect(menu.contains("experienceMode.mode.other"))
        #expect(menu.contains("openWindow(id: \"settings\")"))
        #expect(menu.contains("Youzi.AccountMenu.Settings"))
        #expect(menu.contains("Youzi.AccountMenu.SystemStatus"))
        #expect(!menu.contains("OpenSettingsAction"))
        #expect(!menu.contains("Logout"))
        #expect(!menu.contains("登出"))
        #expect(!menu.contains("个人主页"))

        #expect(content.contains("YouziAccountMenu()"))
        #expect(simple.contains("YouziAccountMenu()"))
        #expect(!sidebar.contains("YouziAccountMenu"))
        #expect(content.contains("The account menu lives outside SidebarView"))
        #expect(sidebar.contains("Text(\"柚子\")"))
        #expect(!sidebar.contains("Text(\"Youzi\")"))
    }
}
