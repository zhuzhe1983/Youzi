import Foundation
import Observation

/// Only a human UI action can grant this request. No tool argument can assert
/// consent, and browse/MCP auto-approval never applies to model loading.
@MainActor @Observable
final class YouziModelApprovalStore {
    struct Request: Identifiable, Equatable {
        let id: UUID
        let alias: String
        let reason: String
        let diskSize: String?
    }
    private(set) var pending: Request?
    private var continuation: CheckedContinuation<Bool, Never>?

    func request(alias: String, reason: String, diskSize: String?) async -> Bool {
        guard pending == nil, !Task.isCancelled else { return false }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: false); return }
                self.continuation = continuation
                pending = Request(id: id, alias: alias, reason: reason, diskSize: diskSize)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resolve(id: id, allow: false) }
        }
    }

    func resolve(id: UUID, allow: Bool) {
        guard pending?.id == id else { return }
        let answer = continuation
        continuation = nil
        pending = nil
        answer?.resume(returning: allow)
    }
}
