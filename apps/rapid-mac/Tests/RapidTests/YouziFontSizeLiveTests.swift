import os

import AppKit
import Foundation
import Observation
import Testing
@testable import Rapid

@Suite("Live app font size", .serialized)
@MainActor
struct YouziFontSizeLiveTests {
    @Test("RapidFont observes in-memory selection instead of polling defaults")
    func reactiveTypography() {
        let config = YouziFontSizeConfig.shared
        let original = config.size
        defer { config.size = original }
        config.size = .medium
        let changed = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = RapidFont.body
        } onChange: {
            changed.withLock { $0 = true }
        }
        config.size = .extraLarge
        #expect(changed.withLock { $0 })
        #expect(RapidFont.fontScale == 1.32)
    }

    @Test("Selection persists immediately; zoom follows all four steps and clamps")
    func persistenceAndZoom() throws {
        let name = "YouziFontSizeLiveTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let config = YouziFontSizeConfig(defaults: defaults)
        #expect(config.size == .medium)
        config.size = .small
        #expect(YouziFontSizeConfig(defaults: defaults).size == .small)
        config.zoomOut(); #expect(config.size == .small)
        config.zoomIn(); #expect(config.size == .medium)
        config.zoomIn(); #expect(config.size == .large)
        config.zoomIn(); config.zoomIn(); #expect(config.size == .extraLarge)
        config.reset(); #expect(config.size == .medium)
    }

    @Test("Native composer rescales without changing the draft or selected range")
    func composer() {
        let view = AutosizingTextView.makeForComposer()
        view.string = "保留草稿 Keep my draft"
        view.setSelectedRange(NSRange(location: 2, length: 3))
        for size in YouziFontSize.allCases {
            ComposeTextEditor.applyFontScale(size.scale, to: view)
            #expect(view.font?.pointSize == round(15 * size.scale))
            #expect(view.string == "保留草稿 Keep my draft")
            #expect(view.selectedRange() == NSRange(location: 2, length: 3))
            let options = TextKitMarkdownView.options(basePointSize: 15 * size.scale)
            #expect(abs(options.codePointSize - 13 * size.scale) < 0.001)
        }
    }
}
