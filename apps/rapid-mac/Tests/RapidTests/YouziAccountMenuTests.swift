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


    @Test("Profile uses the user's chosen address with localized empty fallback",
          arguments: ["", " ", "\n\t ", "  测试用户  ", "Ada", "🍊伙伴"])
    @MainActor
    func profileDisplayName(address: String) {
        let clean = address.trimmingCharacters(in: .whitespacesAndNewlines)
        for chinese in [true, false] {
            #expect(YouziAccountMenuTrigger.displayName(userAddress: address, isChinese: chinese)
                == (clean.isEmpty ? (chinese ? "柚子" : "Youzi") : clean))
        }
    }

    @Test("Profile follows personal address edits, clear, and reload, never the AI name")
    @MainActor
    func personalizationProfile() throws {
        let suite = "youzi-profile-tests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let config = CustomInstructionsConfig(defaults: defaults)
        func label(_ config: CustomInstructionsConfig) -> String {
            YouziAccountMenuTrigger.displayName(userAddress: config.userAddress, isChinese: true)
        }
        config.assistantName = "Assistant-only name"
        #expect(label(config) == "柚子")
        config.userAddress = "  测试用户  "
        #expect(label(config) == "测试用户")
        #expect(label(CustomInstructionsConfig(defaults: defaults)) == "测试用户")
        config.userAddress = "Alex"
        #expect(label(config) == "Alex")
        config.userAddress = "\n\t "
        #expect(label(config) == "柚子")
        #expect(label(CustomInstructionsConfig(defaults: defaults)) == "柚子")
        #expect(config.assistantName == "Assistant-only name")
    }

    @Test("Only the profile logo is removed; name observation and full accessibility remain")
    @MainActor
    func profileWiring() throws {
        let menu = try Self.source("Sources/Rapid/UI/YouziAccountMenu.swift")
        let trigger = try Self.source("Sources/Rapid/UI/YouziAccountMenuContent.swift")
            .components(separatedBy: "struct YouziAccountMenuContent")[0]
        let shell = try Self.source("Sources/Rapid/UI/YouziSimple/YouziSimpleShell.swift")
        #expect(!trigger.contains("YouziLogo("))
        #expect(shell.contains("YouziLogo("))
        #expect(menu.contains("@Environment(CustomInstructionsConfig.self)"))
        #expect(menu.contains("userAddress: personalization.userAddress"))
        #expect(!menu.contains("personalization.assistantName"))
        #expect(menu.contains("\\(profileDisplayName)菜单"))
        #expect(trigger.contains(".help(displayName)"))
        #expect(trigger.contains(".truncationMode(.tail)"))
        #expect(trigger.contains("Youzi.AccountMenu.ModeBadge"))
        #expect(trigger.contains("chevron.up.chevron.down"))
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
