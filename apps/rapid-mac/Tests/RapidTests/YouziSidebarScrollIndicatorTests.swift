import AppKit
import SwiftUI
import Testing
@testable import Rapid

@Suite("Youzi sidebar native scroll indicators", .serialized)
@MainActor struct YouziSidebarScrollIndicatorTests {
    @MainActor private final class Fixture {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 220, height: 140))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 900))
        let probe = NSView(frame: .zero)
        let coordinator = YouziSidebarScrollIndicatorProbe.Coordinator()

        init() {
            _ = NSApplication.shared
            scroll.scrollerStyle = .legacy // Reproduce the always-visible native tracks.
            scroll.hasVerticalScroller = true
            scroll.documentView = document
            document.addSubview(probe)
            scroll.tile()
            coordinator.attach(to: probe)
        }

        func scrollTo(_ y: CGFloat) {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            NotificationCenter.default.post(name: NSView.boundsDidChangeNotification,
                                            object: scroll.contentView)
        }
    }

    @Test("Legacy indicators are hidden at rest, reveal on hover, and keep the content frame stable")
    func hoverAndLayout() throws {
        let fixture = Fixture()
        defer { fixture.coordinator.detach() }
        let scroller = try #require(fixture.scroll.verticalScroller)
        let frame = fixture.scroll.contentView.frame
        #expect(scroller.isHidden && scroller.alphaValue == 0)
        fixture.coordinator.setHovering(true)
        #expect(!scroller.isHidden && scroller.alphaValue == 1)
        #expect(fixture.scroll.contentView.frame == frame)
        fixture.coordinator.setHovering(false)
        #expect(scroller.isHidden && scroller.alphaValue == 0)
        fixture.scroll.tile()
        fixture.coordinator.attach(to: fixture.probe)
        #expect(scroller.alphaValue == 0)
        #expect(fixture.scroll.contentView.frame == frame)
    }

    @Test("Scrolling works while hidden and reveals feedback until motion settles")
    func scrollingAndIdle() async throws {
        let fixture = Fixture()
        defer { fixture.coordinator.detach() }
        let scroller = try #require(fixture.scroll.verticalScroller)
        fixture.scrollTo(100)
        #expect(fixture.scroll.contentView.bounds.origin.y == 100)
        #expect(!scroller.isHidden && scroller.alphaValue == 1)
        try await Task.sleep(for: .milliseconds(700))
        fixture.scrollTo(180)
        try await Task.sleep(for: .milliseconds(700))
        #expect(scroller.alphaValue == 1) // An earlier timeout must not hide a new scroll.
        try await Task.sleep(for: .milliseconds(700))
        #expect(scroller.isHidden && scroller.alphaValue == 0)
        #expect(fixture.scroll.contentView.bounds.origin.y == 180)
    }

    @Test("Hover keeps the indicator visible after scrolling and nested viewports stay independent")
    func nestedAndHovered() async throws {
        let outer = Fixture()
        let inner = Fixture()
        defer { outer.coordinator.detach(); inner.coordinator.detach() }
        outer.document.addSubview(inner.scroll)
        inner.coordinator.attach(to: inner.probe)
        inner.coordinator.setHovering(true)
        inner.scrollTo(120)
        try await Task.sleep(for: .milliseconds(1400))
        #expect(inner.scroll.verticalScroller?.alphaValue == 1)
        #expect(outer.scroll.verticalScroller?.alphaValue == 0)
        inner.coordinator.setHovering(false)
        #expect(inner.scroll.verticalScroller?.alphaValue == 0)
        #expect(outer.scroll.contentView.bounds.origin.y == 0)
    }

    @Test("Detaching cancels delayed work and restores the native scroller")
    func detach() async throws {
        let fixture = Fixture()
        let scroller = try #require(fixture.scroll.verticalScroller)
        fixture.scrollTo(100)
        fixture.coordinator.detach()
        try await Task.sleep(for: .milliseconds(1400))
        #expect(!scroller.isHidden && scroller.alphaValue == 1)
    }

    @Test("The production SwiftUI wrapper actually attaches to its native viewport")
    func swiftUIAttachment() async throws {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: YouziSidebarScrollView {
            VStack(alignment: .leading) {
                ForEach(0..<30) { Text("Synthetic row \($0)").frame(height: 30) }
            }
        }.frame(width: 220, height: 140))
        let window = NSWindow(contentRect: NSRect(x: 10000, y: 10000, width: 220, height: 140),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
        func viewport(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap { viewport(in: $0) }.first
        }
        let scroll = try #require(viewport(in: host))
        let scroller = try #require(scroll.verticalScroller)
        #expect(scroller.isHidden && scroller.alphaValue == 0)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 80))
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(scroller.alphaValue == 1)
        try await Task.sleep(for: .milliseconds(1400))
        #expect(scroller.isHidden && scroller.alphaValue == 0)
    }
}
