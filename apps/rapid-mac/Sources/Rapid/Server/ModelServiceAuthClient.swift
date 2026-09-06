import Foundation

/// Runtime-only policy update. No credentials in URL, response errors or logs.
struct ModelServiceAuthClient: Sendable {
    enum Failure: Error { case unavailable, rejected, staleSession }
    private struct Policy: Codable { let anonymous_inference: Bool }
    var session: URLSession = .shared

    func apply(anonymous: Bool, port: Int, bearer: String) async throws -> Bool {
        guard (1...65535).contains(port), !bearer.isEmpty,
              let url = URL(string: ModelAPIAccess.baseURL(port: port) + "/service/auth")
        else { throw Failure.unavailable }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 10
        request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Policy(anonymous_inference: anonymous))
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              let policy = try? JSONDecoder().decode(Policy.self, from: data),
              policy.anonymous_inference == anonymous
        else { throw Failure.rejected }
        return policy.anonymous_inference
    }
}
