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
        #expect(
            plist["SUFeedURL"] as? String
                == "https://github.com/zhuzhe1983/Youzi/releases/latest/download/appcast.xml"
        )
    }

    @Test("shared Youzi logo is high-resolution with a transparent canvas")
    func logoAsset() throws {
        let logoURL = try Self.appRoot()
            .appendingPathComponent("Sources/Rapid/Resources/youzi-logo.png")
        let image = try #require(NSImage(contentsOf: logoURL))
        let bitmap = try #require(image.representations.first as? NSBitmapImageRep)

        #expect(bitmap.pixelsWide == bitmap.pixelsHigh)
        #expect(bitmap.pixelsWide >= 1024)
        #expect(bitmap.hasAlpha)
        #expect(bitmap.colorAt(x: 0, y: 0)?.alphaComponent == 0)
        #expect(bitmap.colorAt(x: bitmap.pixelsWide - 1, y: 0)?.alphaComponent == 0)
        #expect(bitmap.colorAt(x: 0, y: bitmap.pixelsHigh - 1)?.alphaComponent == 0)
        #expect(
            bitmap.colorAt(
                x: bitmap.pixelsWide - 1,
                y: bitmap.pixelsHigh - 1
            )?.alphaComponent == 0
        )
        #expect(
            bitmap.colorAt(
                x: bitmap.pixelsWide / 2,
                y: bitmap.pixelsHigh / 2
            )?.alphaComponent == 1
        )
    }

    @Test("responsive Youzi logo assets preserve transparency")
    func responsiveLogoAssets() throws {
        let imageSetURL = try Self.appRoot()
            .appendingPathComponent(
                "Sources/Rapid/Resources/Assets.xcassets/RapidLogo.imageset"
            )

        for filename in ["RapidLogo.png", "RapidLogo@2x.png", "RapidLogo@3x.png"] {
            let image = try #require(
                NSImage(contentsOf: imageSetURL.appendingPathComponent(filename))
            )
            let bitmap = try #require(image.representations.first as? NSBitmapImageRep)
            #expect(bitmap.hasAlpha, "\(filename) lost its alpha channel")
            #expect(
                bitmap.colorAt(x: 0, y: 0)?.alphaComponent == 0,
                "\(filename) regained an opaque canvas"
            )
        }
    }

    private enum BrandingTestError: Error {
        case packageRootNotFound
    }
}
