import Foundation

/// Provider-generated URLs are untrusted input, not configured API endpoints.
/// Fetch public HTTPS only, with pinned DNS, no bearer, no cookies or redirects.
/// LAN gateways can return b64_json instead of asking the app to fetch private URLs.
enum RemoteImageDownload {
    static let maximumBytes = 32 * 1024 * 1024
    static func validateURL(_ url: URL) throws {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme?.lowercased() == "https", c.host?.isEmpty == false,
              c.user == nil, c.password == nil, c.fragment == nil else { throw RemoteModelError.invalidResponse }
    }
    static func fetch(_ url: URL) async throws -> Data {
        do {
            try validateURL(url)
            let address = try await BrowseSSRFGuard.validatedAddress(url)
            let (data, response) = try await IPPinnedHTTPTransport.fetch(url: url, address: address, byteLimit: maximumBytes)
            guard (200..<300).contains(response.statusCode), !data.isEmpty else { throw RemoteModelError.invalidResponse }
            return data
        } catch {
            if Task.isCancelled { throw CancellationError() }
            // Do not display signed CDN URLs or upstream body/error descriptions.
            throw RemoteModelError.invalidResponse
        }
    }
}
