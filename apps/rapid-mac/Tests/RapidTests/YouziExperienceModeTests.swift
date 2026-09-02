import Foundation
import Testing
@testable import Rapid

@MainActor
@Suite("YouziExperienceMode")
final class YouziExperienceModeTests {
    nonisolated(unsafe) private var createdSuiteNames: [String] = []

    deinit {
        TestDefaultsScope.cleanup(suiteNames: createdSuiteNames)
    }

    private func freshDefaults() -> UserDefaults {
        let name = TestDefaultsScope.mintSuiteName(prefix: "youzi-experience-mode-")
        createdSuiteNames.append(name)
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("A fresh preference domain opens in Simple Mode")
    func freshDefaultIsSimple() {
        let config = YouziExperienceModeConfig(defaults: freshDefaults())
        #expect(config.mode == .simple)
        #expect(YouziExperienceMode.defaultMode == .simple)
    }

    @Test("Mode choice persists and Professional Mode can be restored")
    func modeRoundTrips() {
        let defaults = freshDefaults()
        let writer = YouziExperienceModeConfig(defaults: defaults)
        writer.mode = .professional

        #expect(
            defaults.string(forKey: YouziExperienceModeConfig.storageKey)
                == YouziExperienceMode.professional.rawValue
        )
        #expect(YouziExperienceModeConfig(defaults: defaults).mode == .professional)

        writer.mode = .simple
        #expect(YouziExperienceModeConfig(defaults: defaults).mode == .simple)
    }

    @Test("An unknown stored value fails safely to Simple Mode")
    func unknownValueFallsBackToSimple() {
        let defaults = freshDefaults()
        defaults.set("future-experience", forKey: YouziExperienceModeConfig.storageKey)
        #expect(YouziExperienceModeConfig(defaults: defaults).mode == .simple)
    }

    @Test("Simple navigation has five stable task-first destinations")
    func destinationContract() {
        #expect(
            YouziSimpleDestination.allCases.map(\.title)
                == ["新任务", "工作空间", "帮手", "知我", "成果"]
        )
        #expect(
            YouziSimpleDestination.allCases.map(\.accessibilityIdentifier)
                == [
                    "YouziSimple.Navigation.newTask",
                    "YouziSimple.Navigation.workspaces",
                    "YouziSimple.Navigation.helpers",
                    "YouziSimple.Navigation.knowMe",
                    "YouziSimple.Navigation.results",
                ]
        )
        #expect(Set(YouziSimpleDestination.allCases.map(\.systemImage)).count == 5)
    }

    @Test("Both experience modes expose stable accessibility identities")
    func modeAccessibilityContract() {
        #expect(YouziExperienceMode.simple.displayName == "简约模式")
        #expect(YouziExperienceMode.professional.displayName == "专业模式")
        #expect(
            YouziExperienceMode.simple.accessibilityIdentifier
                == "Youzi.ExperienceMode.simple"
        )
        #expect(
            YouziExperienceMode.professional.accessibilityIdentifier
                == "Youzi.ExperienceMode.professional"
        )
    }

    @Test("Simple and Professional presentations reuse the app-owned runtime")
    func sharedRuntimeWiring() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let contentView = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/Rapid/UI/ContentView.swift"),
            encoding: .utf8
        )
        let rapidApp = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/Rapid/RapidApp.swift"),
            encoding: .utf8
        )
        let simpleTask = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/Rapid/UI/YouziSimple/YouziSimpleTaskView.swift"
            ),
            encoding: .utf8
        )
        let simpleShell = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/Rapid/UI/YouziSimple/YouziSimpleShell.swift"
            ),
            encoding: .utf8
        )

        #expect(contentView.contains("@Environment(ServerManager.self) private var server"))
        #expect(contentView.contains("@Environment(ChatViewModel.self) private var chat"))
        #expect(contentView.contains("if experienceMode.mode == .simple"))
        #expect(contentView.contains("simpleProductionShell"))
        #expect(contentView.contains("productionShell"))
        let simpleBranch = try #require(
            contentView.range(of: "if experienceMode.mode == .simple")
        )
        let onboardingBranch = try #require(
            contentView.range(of: "else if quickstartVisible")
        )
        #expect(simpleBranch.lowerBound < onboardingBranch.lowerBound)

        #expect(rapidApp.contains(".environment(server)"))
        #expect(rapidApp.contains(".environment(chatViewModel)"))
        #expect(rapidApp.contains(".environment(experienceMode)"))

        #expect(simpleTask.contains("@Environment(ChatViewModel.self) private var chat"))
        #expect(simpleTask.contains("@Environment(ServerManager.self) private var server"))
        #expect(simpleShell.contains("@Environment(ChatViewModel.self) private var chat"))
        #expect(!simpleTask.contains("ServerManager()"))
        #expect(!simpleTask.contains("ChatViewModel("))
        #expect(!simpleShell.contains("ServerManager()"))
        #expect(!simpleShell.contains("ChatViewModel("))
        for retiredEnglishCopy in [
            "\"RECENT TASKS\"", "\"Settings…\"", "\"Professional Mode\"",
            "\"Your work, in the right place\"", "title: \"Helpers\"",
            "title: \"Know Me\"", "title: \"Results\"",
        ] {
            #expect(!simpleShell.contains(retiredEnglishCopy))
        }
    }
}
