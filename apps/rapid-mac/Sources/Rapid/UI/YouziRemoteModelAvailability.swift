import Foundation
import Observation

/// Read-only presentation probe. Never uses the local service bearer, runs inference,
/// follows redirects, or writes settings. Online means authenticated /models listed
/// this exact model recently, not a promise that a later generation will succeed.
@MainActor @Observable
final class YouziRemoteModelAvailability {
    enum Status: Equatable { case unchecked, checking, online, offline }
    struct Check {
        var status: Status
        var checkedAt: Date
        var revision: Int
    }
    static let lifetime: TimeInterval = 60
    private(set) var checks: [String: Check] = [:]
    private var generation = UUID()
    @ObservationIgnored private let discover: @Sendable (RemoteModelEndpoint) async throws -> [String]

    init(discover: @escaping @Sendable (RemoteModelEndpoint) async throws -> [String] = { endpoint in
        try await endpoint.discover(session: YouziRemoteModelAvailability.probeSession)
    }) { self.discover = discover }

    func status(_ alias: String, revision: Int, now: Date = .now) -> Status {
        guard let check = checks[alias], check.revision == revision,
              now.timeIntervalSince(check.checkedAt) < Self.lifetime else { return .unchecked }
        return check.status
    }

    func refresh(aliases: [String], settings: RemoteModelSettings, force: Bool = false, now: Date = .now) async {
        guard !Task.isCancelled else { return }
        let token = UUID()
        generation = token
        let revision = settings.revision
        let enabled = Set(settings.document.models.filter(\.enabled).map(\.alias))
        checks = checks.filter { enabled.contains($0.key) && $0.value.revision == revision }
        var pending: [RemoteModelEndpoint] = []
        for alias in Set(aliases).sorted() where enabled.contains(alias) {
            let previous = status(alias, revision: revision, now: now)
            if !force && (previous == .online || previous == .offline) { continue }
            checks[alias] = Check(status: .checking, checkedAt: now, revision: revision)
            do {
                if let endpoint = try settings.repository.endpoint(alias: alias) { pending.append(endpoint) }
                else { checks[alias] = Check(status: .offline, checkedAt: now, revision: revision) }
            } catch {
                checks[alias] = Check(status: .offline, checkedAt: now, revision: revision)
            }
        }
        defer {
            if generation == token {
                // Cancellation is not evidence that a provider is offline.
                checks = checks.filter { $0.value.status != .checking }
            }
        }
        // Bound parallel work; closing/backgrounding the view cancels structured children.
        let discover = discover
        await withTaskGroup(of: (String, Bool).self) { group in
            var iterator = pending.makeIterator()
            func enqueue(_ endpoint: RemoteModelEndpoint) {
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        let models = try await discover(endpoint)
                        return (endpoint.configuration.alias, models.contains(endpoint.modelID))
                    } catch { return (endpoint.configuration.alias, false) }
                }
            }
            for _ in 0..<3 { if let endpoint = iterator.next() { enqueue(endpoint) } }
            while let (alias, online) = await group.next() {
                guard !Task.isCancelled, generation == token, settings.revision == revision else {
                    group.cancelAll(); return
                }
                checks[alias] = Check(status: online ? .online : .offline, checkedAt: .now, revision: revision)
                if let endpoint = iterator.next() { enqueue(endpoint) }
            }
        }
    }

    nonisolated private static let probeSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 8 // Also bounds a slow/trickling response body.
        config.httpMaximumConnectionsPerHost = 3
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.urlCredentialStorage = nil
        return URLSession(configuration: config, delegate: YouziProbeNoRedirects(), delegateQueue: nil)
    }()
}

private final class YouziProbeNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
