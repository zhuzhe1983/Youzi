import SwiftUI

/// Youzi's pomelo mark, shared by every prominent product-brand surface.
///
/// The source artwork comes from `youziold/assets/app-logo-youzi-v1.png`. Its
/// warm canvas is deterministically removed for the bundled transparent PNG;
/// the mark itself is not redrawn or recoloured. Keeping one master avoids
/// visual drift between onboarding, chat, About, and snapshot fixtures.
struct YouziLogo: View {
    var size: CGFloat

    var body: some View {
        if let nsImage = Self.load() {
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "leaf.fill")
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .foregroundStyle(.green)
                .accessibilityHidden(true)
        }
    }

    static func load() -> NSImage? {
        if let url = Bundle.main.url(forResource: "youzi-logo", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }

        let executableAnchor = Bundle(for: BundleFinder.self).bundleURL
        let anchors = [
            executableAnchor.deletingLastPathComponent(),
            executableAnchor,
        ]
        for anchor in anchors {
            let bundleURL = anchor.appendingPathComponent("Rapid_Rapid.bundle")
            if let bundle = Bundle(url: bundleURL),
               let url = bundle.url(forResource: "youzi-logo", withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                return image
            }
        }

        return nil
    }
}

private final class BundleFinder {}
