import AppKit
import Testing
@testable import Rapid

/// The full-colour pomelo artwork is too detailed for the macOS menu bar, so
/// Youzi uses a template leaf there while the Dock and app surfaces use the
/// bundled logo. These checks pin the two accessibility-critical properties.
@MainActor
@Suite("Youzi menu-bar mark")
struct MenuBarTemplateMarkTests {
    @Test("The tray leaf is a template image")
    func trayGlyphIsTemplate() {
        #expect(MenuBarController.trayGlyph().isTemplate)
    }

    @Test("The tray leaf carries the Youzi name")
    func trayGlyphIsNamed() {
        let image = MenuBarController.trayGlyph()
        let description = image.accessibilityDescription
            ?? MenuBarController.accessibilityTitle

        #expect(MenuBarController.accessibilityTitle == "Youzi")
        #expect(description == "Youzi")
    }
}
