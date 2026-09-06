import Foundation
import Observation

struct YouziShareRecord: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable { case file, task }
    let id: UUID
    let kind: Kind
    let sourceID: UUID
    let title: String
    let service: String
    let sharedAt: Date

    init(id: UUID = UUID(), kind: Kind, sourceID: UUID, title: String,
         service: String, sharedAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.sourceID = sourceID
        self.title = title
        self.service = service
        self.sharedAt = sharedAt
    }
}

/// Local audit metadata, not an online publishing service. Never stores shared
/// contents, recipients, credentials or temporary file paths. Failed reads are
/// preserved and block writes instead of silently replacing unreadable history.
@MainActor
@Observable
final class YouziShareHistory {
    private struct Envelope: Codable {
        var version = 1
        var records: [YouziShareRecord]
    }
    private(set) var records: [YouziShareRecord] = []
    private(set) var lastError: String?
    private var readable = true
    private let fileURL: URL

    init(fileURL: URL = YouziDomainStore.defaultFileURL()
        .deletingLastPathComponent().appendingPathComponent("shares.json")) {
        self.fileURL = fileURL
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: fileURL))
                guard envelope.version == 1 else { throw CocoaError(.coderReadCorrupt) }
                records = envelope.records
            }
        } catch {
            readable = false
            lastError = error.localizedDescription
        }
    }

    @discardableResult
    func record(_ record: YouziShareRecord) -> Bool {
        var next = records.filter { $0.id != record.id }
        next.insert(record, at: 0)
        return save(next)
    }

    /// Removes only this local history entry; cannot retract a delivered copy.
    @discardableResult
    func removeRecord(_ id: UUID) -> Bool {
        save(records.filter { $0.id != id })
    }

    func matching(kind: YouziShareRecord.Kind, query: String) -> [YouziShareRecord] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return records.filter {
            $0.kind == kind && (query.isEmpty || $0.title.localizedStandardContains(query)
                               || $0.service.localizedStandardContains(query))
        }.sorted {
            if $0.sharedAt != $1.sharedAt { return $0.sharedAt > $1.sharedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private func save(_ next: [YouziShareRecord]) -> Bool {
        guard readable else { return false }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(Envelope(records: next)).write(to: fileURL, options: .atomic)
            records = next
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }
}
