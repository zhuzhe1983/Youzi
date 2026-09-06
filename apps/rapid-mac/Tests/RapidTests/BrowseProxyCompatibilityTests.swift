import Foundation
import Testing
@testable import Rapid

struct BrowseProxyCompatibilityTests {
    /// Explicit opt-in: normal unit tests never depend on the network or proxy.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["YOUZI_LIVE_PROXY_SMOKE"] == "1"))
    func livePinnedBrowseThroughProxy() async throws {
        let url = try #require(URL(string: "https://example.com/"))
        let result = try await BrowseTool.fetchFollowingRedirects(startURL: url) { _ in .deny }
        #expect(result.data.count > 0)
        #expect(String(decoding: result.data, as: UTF8.self).contains("Example Domain"))
    }

    @Test func narrowDNSException() throws {
        let fake = try #require(ParsedIP("198.18.0.1"))
        #expect(fake.isBlocked) // No global relaxation of address policy.
        #expect(throws: BrowseSSRFGuard.Rejection.self) {
            try BrowseSSRFGuard.validateDNSAnswers(host: "github.com", addresses: [fake], proxyCompatibility: false)
        }
        #expect(try BrowseSSRFGuard.validateDNSAnswers(host: "github.com", addresses: [fake], proxyCompatibility: true) == [fake])
        for host in ["localhost", "foo.local", "foo.home.arpa.", "localdomain", "intranet", "198.18.0.1", "::ffff:198.18.0.1"] {
            #expect(throws: BrowseSSRFGuard.Rejection.self) {
                try BrowseSSRFGuard.validateDNSAnswers(host: host, addresses: [fake], proxyCompatibility: true)
            }
        }
        for address in ["127.0.0.1", "192.168.1.1", "169.254.169.254", "100.64.0.1", "::1", "fd00::1", "64:ff9b::c612:1", "198.51.100.1"] {
            let privateIP = try #require(ParsedIP(address))
            #expect(throws: BrowseSSRFGuard.Rejection.self) {
                try BrowseSSRFGuard.validateDNSAnswers(host: "example.com", addresses: [fake, privateIP], proxyCompatibility: true)
            }
        }
    }

    @Test func literalAndRedirectTargetsRemainBlocked() async throws {
        for value in ["http://198.18.0.1", "http://127.0.0.1", "http://[::ffff:198.18.0.1]", "http://foo.local"] {
            let url = try #require(URL(string: value))
            await #expect(throws: BrowseSSRFGuard.Rejection.self) {
                try await BrowseSSRFGuard.validatedAddresses(url, proxyCompatibility: true)
            }
        }
    }

    @Test func defaultCompatibleAndImmediatelySwitchable() throws {
        let suite = "test.youzi.proxy." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(BrowseNetworkPreference.proxyCompatibility(in: defaults))
        defaults.set(false, forKey: BrowseNetworkPreference.proxyCompatibilityKey)
        #expect(!BrowseNetworkPreference.proxyCompatibility(in: defaults))
    }
}
