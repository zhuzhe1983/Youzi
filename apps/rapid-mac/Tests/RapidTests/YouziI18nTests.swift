import Foundation
import Testing
@testable import Rapid

@Suite("Youzi i18n configuration and text resolution")
struct YouziI18nTests {
    @Test("AppLanguage cases and display names")
    func appLanguageCases() {
        #expect(AppLanguage.allCases.count == 3)
        #expect(AppLanguage.system.displayName == "跟随系统")
        #expect(AppLanguage.zhHans.displayName == "简体中文")
        #expect(AppLanguage.en.displayName == "English")
        #expect(AppLanguage.system.accessibilityIdentifier == "Settings.Appearance.Language.system")
        #expect(AppLanguage.zhHans.accessibilityIdentifier == "Settings.Appearance.Language.zh-Hans")
        #expect(AppLanguage.en.accessibilityIdentifier == "Settings.Appearance.Language.en")
    }

    @MainActor
    @Test("YouziI18nConfig persistence and language selection")
    func languageSwitchingAndPersistence() {
        let suiteName = "test-youzi-i18n-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let config = YouziI18nConfig(defaults: defaults)
        #expect(config.language == .system)

        config.language = .zhHans
        #expect(config.isChinese == true)
        #expect(config.locale.identifier == "zh-Hans")
        #expect(config.text(zh: "你好", en: "Hello") == "你好")
        #expect(defaults.string(forKey: YouziI18nConfig.storageKey) == "zh-Hans")

        config.language = .en
        #expect(config.isChinese == false)
        #expect(config.locale.identifier == "en")
        #expect(config.text(zh: "你好", en: "Hello") == "Hello")
        #expect(defaults.string(forKey: YouziI18nConfig.storageKey) == "en")

        // Reload from defaults
        let reloaded = YouziI18nConfig(defaults: defaults)
        #expect(reloaded.language == .en)
        #expect(reloaded.isChinese == false)
    }

    @MainActor
    @Test("SettingsToolsPanel localized tool display name and summary")
    func toolsPanelDisplayNameAndSummary() {
        #expect(SettingsToolsPanel.displayName(for: "web_search", isChinese: true) == "联网搜索")
        #expect(SettingsToolsPanel.displayName(for: "browse", isChinese: true) == "浏览网页")
        #expect(SettingsToolsPanel.displayName(for: "weather", isChinese: true) == "天气")
        #expect(SettingsToolsPanel.displayName(for: "custom_tool", isChinese: true) == "custom_tool")

        #expect(SettingsToolsPanel.displayName(for: "web_search", isChinese: false) == "Web Search")
        #expect(SettingsToolsPanel.displayName(for: "browse", isChinese: false) == "Browse Web Page")
        #expect(SettingsToolsPanel.displayName(for: "weather", isChinese: false) == "Weather")
        #expect(SettingsToolsPanel.displayName(for: "custom_tool", isChinese: false) == "custom_tool")

        #expect(SettingsToolsPanel.summary(for: "web_search", fallback: "fallback", isChinese: true).contains("网络"))
        #expect(SettingsToolsPanel.summary(for: "browse", fallback: "fallback", isChinese: true).contains("网页"))
        #expect(SettingsToolsPanel.summary(for: "weather", fallback: "fallback", isChinese: true).contains("天气"))
    }
}
