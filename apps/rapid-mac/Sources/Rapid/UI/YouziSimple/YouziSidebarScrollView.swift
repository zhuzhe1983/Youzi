import AppKit
import SwiftUI

/// Only the three collection viewports use this policy. Keep the native scroller
/// and its gutter, but hide its painting and hit area when the viewport is idle.
/// SwiftUI's `.hidden` alone can leave legacy macOS scrollbars visible.
struct YouziSidebarScrollView<Content: View>: View {
    @State private var hovering = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView(.vertical) {
            content().background(YouziSidebarScrollIndicatorProbe(hovering: hovering))
        }
        .scrollIndicators(.visible, axes: .vertical)
        .onHover { hovering = $0 }
    }
}

struct YouziSidebarScrollIndicatorProbe: NSViewRepresentable {
    let hovering: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.coordinator = context.coordinator
        DispatchQueue.main.async { context.coordinator.attach(to: view) }
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        context.coordinator.setHovering(hovering)
        context.coordinator.attach(to: view)
    }

    static func dismantleNSView(_ view: ProbeView, coordinator: Coordinator) {
        coordinator.detach()
        view.coordinator = nil
    }

    final class ProbeView: NSView {
        weak var coordinator: Coordinator?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            coordinator?.attach(to: self)
        }
        override func layout() {
            super.layout()
            coordinator?.attach(to: self)
        }
    }

    @MainActor final class Coordinator: NSObject {
        static let idleDelay: TimeInterval = 1.2
        private weak var scrollView: NSScrollView?
        private var previousStyle: NSScroller.Style = .legacy
        private var hovering = false
        private var scrolling = false
        private var liveScrolling = false
        private var lastOrigin: NSPoint?
        private var idleWork: DispatchWorkItem?

        func attach(to probe: NSView) {
            guard let next = probe.enclosingScrollView else { return }
            if next !== scrollView {
                detach()
                scrollView = next
                previousStyle = next.scrollerStyle
                lastOrigin = next.contentView.bounds.origin
                next.contentView.postsBoundsChangedNotifications = true
                NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged(_:)),
                    name: NSView.boundsDidChangeNotification, object: next.contentView)
                NotificationCenter.default.addObserver(self, selector: #selector(scrollStarted(_:)),
                    name: NSScrollView.willStartLiveScrollNotification, object: next)
                NotificationCenter.default.addObserver(self, selector: #selector(scrollEnded(_:)),
                    name: NSScrollView.didEndLiveScrollNotification, object: next)
            }
            applyVisibility()
        }

        func setHovering(_ value: Bool) {
            hovering = value
            applyVisibility()
        }

        func detach() {
            idleWork?.cancel()
            idleWork = nil
            NotificationCenter.default.removeObserver(self)
            if let scrollView {
                scrollView.verticalScroller?.alphaValue = 1
                scrollView.verticalScroller?.isHidden = false
                scrollView.scrollerStyle = previousStyle
            }
            scrollView = nil
            lastOrigin = nil
            scrolling = false
            liveScrolling = false
        }

        private func applyVisibility() {
            guard let scrollView else { return }
            // Legacy scrollers have no independent overlay fade animation. The
            // viewport owns visibility, so a hovered indicator stays visible.
            // Keeping the style and gutter fixed avoids shifting or truncating rows.
            if scrollView.scrollerStyle != .legacy { scrollView.scrollerStyle = .legacy }
            let visible = hovering || scrolling
            scrollView.verticalScroller?.alphaValue = visible ? 1 : 0
            scrollView.verticalScroller?.isHidden = !visible
        }

        private func revealForScrolling() {
            scrolling = true
            idleWork?.cancel()
            applyVisibility()
            guard !liveScrolling else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.scrolling = false
                self.applyVisibility()
                self.idleWork = nil
            }
            idleWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleDelay, execute: work)
        }

        @objc private func boundsChanged(_ notification: Notification) {
            guard let clip = scrollView?.contentView else { return }
            let origin = clip.bounds.origin
            defer { lastOrigin = origin }
            if let lastOrigin, abs(origin.y - lastOrigin.y) > 0.1 {
                revealForScrolling()
            } else {
                applyVisibility() // Native re-layout must not reveal idle scrollers.
            }
        }

        @objc private func scrollStarted(_ notification: Notification) {
            liveScrolling = true
            revealForScrolling()
        }

        @objc private func scrollEnded(_ notification: Notification) {
            liveScrolling = false
            revealForScrolling()
        }
    }
}
