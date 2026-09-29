import Foundation
import Observation

/// A single durable fact the assistant has learned about the user across
/// conversations. Backed by the Open WebUI memory-review pattern: after a
/// conversation turn completes, a lightweight background pass decides
/// whether anything enduring should be saved.
struct MemoryEntry: Codable, Equatable, Hashable, Identifiable, Sendable {
    let id: UUID
    var content: String
    var evidenceCount: Int
    var sourceConversationIDs: [UUID]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        content: String,
        evidenceCount: Int = 1,
        sourceConversationIDs: [UUID] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.content = content
        self.evidenceCount = evidenceCount
        self.sourceConversationIDs = sourceConversationIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Schema version marker so future migrations can distinguish disk shapes.
struct MemoryLibrary: Codable, Sendable {
    var schemaVersion: Int = 1
    var entries: [MemoryEntry] = []
}

/// Source-compatible facade over the unified graph. There is deliberately no
/// independent entries array, legacy JSON writer, substring deletion or pruning.
@MainActor @Observable
final class MemoryStore {
    /// Historical compatibility constant, NOT a graph retention policy.
    static let maximumEntries = 80
    static let maximumInjectedCharacters = 2_000
    let service: YouziMemoryService
    let ingestion = YouziMemoryIngestionQueue()
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var collectionSessionStartedAt = Date()
    private(set) var actionError: String?
    var lastError: String? { actionError ?? service.lastError }

    var entries: [MemoryEntry] {
        service.nodes.map { node in
            MemoryEntry(id: node.id, content: node.content,
                evidenceCount: node.legacy?.evidenceCount ?? max(1, node.citationIDs.count),
                sourceConversationIDs: node.legacy?.sourceConversationIDs ?? service.citations.compactMap {
                    node.citationIDs.contains($0.id) ? YouziMemoryChatSource.reference($0.stableLocator)?.conversation : nil
                }, createdAt: node.createdAt, updatedAt: node.updatedAt)
        }
    }

    /// Preserve the existing opt-in AND prompt-use gate on upgrade.
    var isEnabled: Bool {
        didSet {
            if isEnabled && !oldValue { collectionSessionStartedAt = Date() }
            defaults.set(isEnabled, forKey: "rapid.memory.enabled")
            if !isEnabled { ingestion.cancelAll(); service.resetContext() }
        }
    }

    init(fileURL: URL? = nil, defaults: UserDefaults = .standard,
         product: YouziProductModel? = nil) {
        self.defaults = defaults
        self.isEnabled = defaults.bool(forKey: "rapid.memory.enabled")
        let legacy = fileURL ?? ApplicationSupportLocator.applicationSupportRoot()
            .appendingPathComponent("memory-library-v1.json")
        // Explicit test URLs never open the user's real domain document.
        let product = product ?? YouziProductModel(store: fileURL.map {
            YouziDomainStore(fileURL: $0.appendingPathExtension("youzi-domain.json"))
        } ?? YouziDomainStore())
        service = YouziMemoryService(product: product, legacyURL: legacy)
    }

    func canAutomaticallyCollect(_ source: YouziMemoryChatSource) -> Bool {
        isEnabled && source.createdAt >= collectionSessionStartedAt && service.mayCollect(source)
    }

    @discardableResult
    func upsert(content: String, conversationID: UUID) -> MemoryEntry {
        do {
            let id = try service.upsertLegacy(content: content, conversationID: conversationID)
            actionError = nil
            if let entry = entries.first(where: { $0.id == id }) { return entry }
        } catch { actionError = error.localizedDescription }
        return MemoryEntry(content: "", createdAt: .distantPast, updatedAt: .distantPast)
    }

    func update(id: UUID, content: String) { perform { try service.correct(id, content: content) } }
    func remove(id: UUID) { perform { try service.forget([id]) } }
    func removeAll() { ingestion.cancelAll(); perform { try service.forgetAll() } }

    func perform(_ action: () throws -> Void) {
        do { try action(); actionError = nil } catch { actionError = error.localizedDescription }
    }

    func formattedForPrompt() -> String? {
        guard isEnabled else { service.resetContext(); return nil }
        return service.context(.init())
    }

    func formattedForPrompt(query: String, conversationID: UUID) -> String? {
        guard isEnabled, !service.control.excludedConversationIDs.contains(conversationID) else {
            service.resetContext(); return nil
        }
        return service.context(service.contextRequest(query: query, conversationID: conversationID))
    }
}
