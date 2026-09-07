import Foundation

/// Authenticated, policy-only update; never starts/stops a service or model.
struct ModelLoadingPolicyClient: Sendable {
    struct Policy: Codable, Equatable, Sendable { let automatic: [String: [String]] }
    enum Failure: Error { case unavailable, rejected, staleSession }
    var session: URLSession = .shared

    func apply(_ policy: Policy, port: Int, bearer: String) async throws {
        guard (1...65535).contains(port), !bearer.isEmpty,
              let url = URL(string: ModelAPIAccess.baseURL(port: port) + "/service/model-policy")
        else { throw Failure.unavailable }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 10
        request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(policy)
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              let applied = try? JSONDecoder().decode(Policy.self, from: data), applied == policy
        else { throw Failure.rejected }
    }
}
