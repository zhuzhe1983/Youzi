import AppKit
import Foundation
import Testing

@Suite("Youzi product branding")
struct AppBrandingTests {
    private static func appRoot() throws -> URL {
        var directory = URL(fileURLWithPath: #file).deletingLastPathComponent()
        for _ in 0..<10 {
            if FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("Package.swift").path
            ) {
                return directory
            }
            directory.deleteLastPathComponent()
        }
        throw BrandingTestError.packageRootNotFound
    }

    @Test("bundle presents Youzi while compatibility identifiers stay stable")
    func bundleIdentity() throws {
        let plistURL = try Self.appRoot().appendingPathComponent("Resources/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try #require(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )

        #expect(plist["CFBundleDisplayName"] as? String == "Youzi")
        #expect(plist["CFBundleName"] as? String == "Youzi")
        #expect(plist["CFBundleExecutable"] as? String == "Rapid")
        #expect(plist["CFBundleIdentifier"] as? String == "com.rapidmlx.rapid")
    }

    @Test("shared Youzi logo is a high-resolution square image")
    func logoAsset() throws {
        let logoURL = try Self.appRoot()
            .appendingPathComponent("Sources/Rapid/Resources/youzi-logo.png")
        let image = try #require(NSImage(contentsOf: logoURL))
        let bitmap = try #require(image.representations.first as? NSBitmapImageRep)

        #expect(bitmap.pixelsWide == bitmap.pixelsHigh)
        #expect(bitmap.pixelsWide >= 1024)
    }

    private enum BrandingTestError: Error {
        case packageRootNotFound
    }
}
