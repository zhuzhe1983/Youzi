import Foundation

/// Read the exact public catalogue. Never discovers remote services or loads models.
struct ModelServiceCatalogClient: Sendable {
    struct Model: Decodable, Equatable, Identifiable, Sendable {
        let id: String
        let capabilities: [String]?
    }
    private struct Envelope: Decodable { let data: [Model] }
    enum Failure: Error { case unavailable, rejected }
    var session: URLSession = .shared

    func models(port: Int, bearer: String) async throws -> [Model] {
        guard (1...65535).contains(port), !bearer.isEmpty,
              let url = URL(string: ModelAPIAccess.baseURL(port: port) + "/models")
        else { throw Failure.unavailable }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw Failure.rejected }
        return try JSONDecoder().decode(Envelope.self, from: data).data
    }
}
