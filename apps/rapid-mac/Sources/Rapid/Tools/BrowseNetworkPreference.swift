import Foundation

/// Read for each new browse hop. Does not change approval or active sockets.
enum BrowseNetworkPreference {
    static let proxyCompatibilityKey = "youzi.security.browse.proxyCompatibility.v1"
    static func proxyCompatibility(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: proxyCompatibilityKey) == nil
            ? true : defaults.bool(forKey: proxyCompatibilityKey)
    }
}
