import Foundation
import Testing
@testable import Rapid

@Suite("Sparkle update configuration")
struct SparkleUpdateControllerTests {
    private let publicKey = Data(repeating: 7, count: 32).base64EncodedString()

    @Test("HTTPS feed plus 32-byte EdDSA public key enables Sparkle")
    func validConfiguration() {
        #expect(SparkleUpdateController.hasValidConfiguration([
            "SUFeedURL": "https://dl.rapidmlx.com/appcast.xml",
            "SUPublicEDKey": publicKey,
        ]))
    }

    @MainActor
    @Test("enabled controller remains actionable before Sparkle starts")
    func enabledBeforeStart() {
        let controller = SparkleUpdateController(infoDictionary: [
            "SUFeedURL": "https://dl.rapidmlx.com/appcast.xml",
            "SUPublicEDKey": publicKey,
        ], checksEnabled: true)

        #expect(controller.isEnabled)
        #expect(!controller.isStarted)
        #expect(controller.canCheckForUpdates)
    }

    @Test("build without a public key keeps Sparkle disabled")
    func missingPublicKey() {
        #expect(!SparkleUpdateController.hasValidConfiguration([
            "SUFeedURL": "https://dl.rapidmlx.com/appcast.xml",
        ]))
    }

    @MainActor
    @Test("Youzi bundle configuration enables authenticated in-app updates without automatic downloads")
    func productionConfiguration() throws {
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let info = try #require(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let suite = "Youzi.Updater.Tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = SparkleUpdateController(
            infoDictionary: info, checksEnabled: true, defaults: defaults
        )
        #expect(controller.isEnabled)
        #expect(controller.canCheckForUpdates)
        #expect(!controller.isStarted)
        #expect(!controller.automaticallyDownloadsUpdates)
        #expect(info["SUFeedURL"] as? String ==
            "https://github.com/zhuzhe1983/Youzi/releases/latest/download/appcast.xml")
        #expect(info["SURequireSignedFeed"] as? Bool == true)
        #expect(info["SUVerifyUpdateBeforeExtraction"] as? Bool == true)
    }

    @MainActor
    @Test("saved automatic-download choice overrides bundle default")
    func automaticDownloadPreference() throws {
        let suite = "Youzi.Updater.Tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let info: [String: Any] = [
            "SUFeedURL": "https://example.test/appcast.xml",
            "SUPublicEDKey": publicKey,
            "SUAutomaticallyUpdate": false,
        ]
        defaults.set(true, forKey: "SUAutomaticallyUpdate")
        #expect(SparkleUpdateController(
            infoDictionary: info, checksEnabled: true, defaults: defaults
        ).automaticallyDownloadsUpdates)
        defaults.set(false, forKey: "SUAutomaticallyUpdate")
        var autoInfo = info
        autoInfo["SUAutomaticallyUpdate"] = true
        #expect(!SparkleUpdateController(
            infoDictionary: autoInfo, checksEnabled: true, defaults: defaults
        ).automaticallyDownloadsUpdates)
    }

    @Test("configuration rejects insecure feeds and malformed public keys")
    func invalidConfiguration() {
        #expect(!SparkleUpdateController.hasValidConfiguration([
            "SUFeedURL": "http://dl.rapidmlx.com/appcast.xml",
            "SUPublicEDKey": publicKey,
        ]))
        #expect(!SparkleUpdateController.hasValidConfiguration([
            "SUFeedURL": "https://dl.rapidmlx.com/appcast.xml",
            "SUPublicEDKey": Data(repeating: 7, count: 31).base64EncodedString(),
        ]))
    }

    @MainActor
    @Test("existing update-check opt-out also disables Sparkle")
    func updateCheckOptOut() {
        let controller = SparkleUpdateController(
            infoDictionary: [
                "SUFeedURL": "https://dl.rapidmlx.com/appcast.xml",
                "SUPublicEDKey": publicKey,
            ],
            checksEnabled: false
        )
        #expect(!controller.isEnabled)
    }

    @MainActor
    @Test("golden busy fixture mirrors a background Sparkle session without starting Sparkle")
    func busyFixture() {
        let controller = SparkleUpdateController(
            infoDictionary: [:],
            checksEnabled: false,
            fixtureState: .busy
        )

        #expect(controller.isEnabled)
        #expect(!controller.canCheckForUpdates)
        controller.start()
        #expect(controller.isStarted)
        #expect(!controller.canCheckForUpdates)
        #expect(!controller.checkForUpdates())
    }

    @MainActor
    @Test("disabled controller rejects foreground update hand-off")
    func disabledCheckIsRejected() {
        let controller = SparkleUpdateController(
            infoDictionary: [:],
            checksEnabled: false
        )
        #expect(!controller.checkForUpdates())
        #expect(!controller.isStarted)
    }

    @MainActor
    @Test("foreground check rejects a stale enabled mirror when Sparkle is busy")
    func authoritativeBusyStateRejectsStaleMirror() {
        var mirroredCanCheck = true
        var dispatches = 0

        #expect(!SparkleUpdateController.dispatchForegroundCheck(
            authoritativeCanCheck: { false },
            synchronizeMirror: { mirroredCanCheck = $0 },
            perform: { dispatches += 1 }
        ))
        #expect(!mirroredCanCheck)
        #expect(dispatches == 0)
    }

    @MainActor
    @Test("foreground check dispatches after authoritative acceptance")
    func authoritativeReadyStateDispatches() {
        var mirroredCanCheck = false
        var dispatches = 0

        #expect(SparkleUpdateController.dispatchForegroundCheck(
            authoritativeCanCheck: { true },
            synchronizeMirror: { mirroredCanCheck = $0 },
            perform: { dispatches += 1 }
        ))
        #expect(mirroredCanCheck)
        #expect(dispatches == 1)
    }
}
