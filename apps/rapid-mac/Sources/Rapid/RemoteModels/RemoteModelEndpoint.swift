import Foundation

/// Snapshot once per request/turn. Never reuse the local sidecar's bearer.
struct RemoteModelEndpoint: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    var description: String { "RemoteModelEndpoint(\(configuration.alias), \(baseURL.host ?? ""))" }
    var debugDescription: String { description }
    let configuration: RemoteModelConfiguration
    let baseURL: URL
    let apiKey: String?
    var modelID: String { configuration.modelID }
    init(configuration: RemoteModelConfiguration, apiKey: String?) throws {
        self.configuration = try configuration.validated()
        baseURL = try Self.normalizedBaseURL(configuration.baseURL, allowHTTP: configuration.allowInsecureHTTP)
        if let apiKey, apiKey.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) { throw RemoteModelError.invalidKey }
        self.apiKey = apiKey?.isEmpty == false ? apiKey : nil
    }
    static func isRemote(_ alias: String) -> Bool { alias.hasPrefix("youzi-remote/") }
    static func normalizedBaseURL(_ text: String, allowHTTP: Bool) throws -> URL {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.contains(where: { $0.isWhitespace }),
              var components = URLComponents(string: clean),
              let host = components.host, !host.isEmpty,
              ["https", "http"].contains(components.scheme?.lowercased() ?? ""),
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true else { throw RemoteModelError.invalidURL }
        if components.scheme?.lowercased() == "http" && !allowHTTP { throw RemoteModelError.insecureHTTP }
        var path = components.path
        guard !path.contains("\\"), !path.contains("%"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." }),
              !path.contains("//") else { throw RemoteModelError.invalidURL }
        while path.hasSuffix("/") { path.removeLast() }
        guard !["/chat/completions", "/models", "/responses", "/images/generations", "/images/edits", "/audio/speech", "/audio/transcriptions", "/videos"].contains(where: path.hasSuffix) else { throw RemoteModelError.invalidURL }
        if path.isEmpty { path = "/v1" }
        components.path = path
        guard let url = components.url else { throw RemoteModelError.invalidURL }
        return url
    }
    func url(_ path: String) -> URL { baseURL.appendingPathComponent(path.hasPrefix("v1/") ? String(path.dropFirst(3)) : path) }
    func request(_ path: String, method: String = "GET", timeout: TimeInterval = 180) -> URLRequest {
        var request = URLRequest(url: url(path))
        request.httpMethod = method; request.timeoutInterval = timeout
        if let apiKey { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        return request
    }
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 180
        config.timeoutIntervalForResource = 30 * 60
        config.httpShouldSetCookies = false
        config.urlCache = nil
        return URLSession(configuration: config, delegate: RemoteModelNoRedirects(), delegateQueue: nil)
    }()
    /// No inference, no billing probe. A successful list is not a capability claim.
    func discover(session: URLSession = Self.session) async throws -> [String] {
        let (bytes, response) = try await session.bytes(for: request("models", timeout: 20))
        defer { bytes.task.cancel() }
        guard let response = response as? HTTPURLResponse else { throw RemoteModelError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw RemoteModelError.http(response.statusCode) }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 4 * 1024 * 1024 else { throw RemoteModelError.invalidResponse }
            data.append(byte)
        }
        struct List: Decodable { struct Item: Decodable { let id: String }; let data: [Item] }
        guard let list = try? JSONDecoder().decode(List.self, from: data) else { throw RemoteModelError.invalidResponse }
        return Array(Set(list.data.map(\.id))).sorted()
    }
}
private final class RemoteModelNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
