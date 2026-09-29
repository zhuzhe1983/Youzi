import Foundation
import Observation
import SwiftUI

enum YouziMemoryWorkbenchFacet: String, CaseIterable, Identifiable, Sendable {
    case all
    case work
    case family
    case knowledge

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "全部"
        case .work: "工作"
        case .family: "家庭"
        case .knowledge: "知识"
        }
    }

    var systemImage: String {
        switch self {
        case .all: "circle.grid.2x2"
        case .work: "briefcase"
        case .family: "person.2"
        case .knowledge: "book.closed"
        }
    }
}

enum YouziMemoryWorkbenchPresentation: String, CaseIterable, Identifiable, Sendable {
    case graph
    case list

    var id: Self { self }
    var title: String { self == .graph ? "图谱" : "列表" }
}

typealias YouziMemoryFileRequestProvider = @MainActor (
    _ mode: YouziMemoryImportMode,
    _ scope: YouziMemoryScopeRecord,
    _ categoryIDs: [UUID]
) async throws -> [YouziMemoryFileImportRequest]

@MainActor
@Observable
final class YouziMemoryWorkbenchModel: @unchecked Sendable {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private let service: YouziMemoryMCPService
    private let accessContext: YouziMemoryAccessContext
    private let fileRequestProvider: YouziMemoryFileRequestProvider?

    private(set) var phase: Phase = .idle
    private(set) var snapshot: YouziMemoryWorkbenchSnapshot?
    private(set) var citations: [YouziMemoryCitationRecord] = []
    private(set) var isLoadingCitations = false
    private(set) var isMutating = false
    var selectedFacet: YouziMemoryWorkbenchFacet = .all
    var selectedCategoryIDs: Set<UUID> = []
    var selectedNodeID: UUID?
    var presentation: YouziMemoryWorkbenchPresentation = .graph
    var query = ""
    var statusMessage: String?

    init(
        service: YouziMemoryMCPService,
        accessContext: YouziMemoryAccessContext,
        fileRequestProvider: YouziMemoryFileRequestProvider? = nil
    ) {
        self.service = service
        self.accessContext = accessContext
        self.fileRequestProvider = fileRequestProvider
    }

    var canImportFiles: Bool { fileRequestProvider != nil }

    var categories: [YouziMemoryCategoryRecord] {
        (snapshot?.categories ?? []).filter { !$0.isHidden }
    }

    var availableScopes: [YouziMemoryScopeRecord] {
        accessContext.allowedScopes.sorted { lhs, rhs in
            Self.scopeSortKey(lhs) < Self.scopeSortKey(rhs)
        }
    }

    var selectedNode: YouziMemoryNodeRecord? {
        guard let selectedNodeID else { return nil }
        return snapshot?.nodes.first { $0.id == selectedNodeID }
    }

    var visibleNodes: [YouziMemoryNodeRecord] {
        guard let snapshot else { return [] }
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedLowercase
        return snapshot.nodes.filter { node in
            guard matchesFacet(node, snapshot: snapshot) else { return false }
            let memberships = Set(snapshot.nodeCategoryIDs[node.id] ?? [])
            guard selectedCategoryIDs.isEmpty || !memberships.isDisjoint(with: selectedCategoryIDs)
            else { return false }
            guard !normalizedQuery.isEmpty else { return true }
            return node.label.localizedLowercase.contains(normalizedQuery)
                || node.content.localizedLowercase.contains(normalizedQuery)
        }
    }

    var visibleEdges: [YouziMemoryEdgeRecord] {
        guard let snapshot else { return [] }
        let visibleIDs = Set(visibleNodes.map(\.id))
        return snapshot.edges.filter {
            visibleIDs.contains($0.sourceNodeID) && visibleIDs.contains($0.targetNodeID)
        }
    }

    var selectedRelations: [YouziMemoryEdgeRecord] {
        guard let selectedNodeID, let snapshot else { return [] }
        return snapshot.edges.filter {
            $0.sourceNodeID == selectedNodeID || $0.targetNodeID == selectedNodeID
        }
    }

    func node(id: UUID) -> YouziMemoryNodeRecord? {
        snapshot?.nodes.first { $0.id == id }
    }

    func categoryIDs(for nodeID: UUID) -> Set<UUID> {
        Set(snapshot?.nodeCategoryIDs[nodeID] ?? [])
    }

    func citationCount(for nodeID: UUID) -> Int {
        snapshot?.citationCountByNodeID[nodeID] ?? 0
    }

    func load() async {
        let previousSelection = selectedNodeID
        phase = .loading
        do {
            let loaded = try await service.workbenchSnapshot(
                context: operationContext(), maximumNodes: 120
            )
            snapshot = loaded
            phase = .loaded
            let visibleIDs = Set(loaded.nodes.map(\.id))
            selectedNodeID = previousSelection.flatMap { visibleIDs.contains($0) ? $0 : nil }
                ?? loaded.nodes.first?.id
            await loadCitationsForSelection()
        } catch {
            snapshot = nil
            citations = []
            selectedNodeID = nil
            phase = .failed(Self.safeMessage(error))
        }
    }

    func select(_ id: UUID) async {
        guard snapshot?.nodes.contains(where: { $0.id == id }) == true else { return }
        selectedNodeID = id
        await loadCitationsForSelection()
    }

    func classifySelected(categoryIDs: Set<UUID>) async {
        guard let node = selectedNode else { return }
        isMutating = true
        defer { isMutating = false }
        do {
            _ = try await service.classifyNode(
                nodeID: node.id,
                expectedRevision: node.revision,
                categoryIDs: categoryIDs.sorted(by: Self.stableUUIDOrder),
                context: operationContext(),
                at: Date()
            )
            statusMessage = "分类已更新。"
            await load()
        } catch {
            statusMessage = Self.safeMessage(error)
        }
    }

    func forgetSelected() async {
        guard let node = selectedNode else { return }
        isMutating = true
        defer { isMutating = false }
        do {
            _ = try await service.forget(
                nodeID: node.id,
                expectedRevision: node.revision,
                context: operationContext(),
                at: Date()
            )
            statusMessage = "这条记忆已删除。"
            selectedNodeID = nil
            await load()
        } catch {
            statusMessage = Self.safeMessage(error)
        }
    }

    func importFiles(
        mode: YouziMemoryImportMode,
        scope: YouziMemoryScopeRecord,
        categoryIDs: Set<UUID>
    ) async {
        guard let fileRequestProvider else {
            statusMessage = "文件导入尚未连接。"
            return
        }
        guard accessContext.allowedScopes.contains(scope) else {
            statusMessage = YouziMemoryRepositoryError.operationNotPermitted.localizedDescription
            return
        }
        isMutating = true
        defer { isMutating = false }
        do {
            let requests = try await fileRequestProvider(
                mode, scope, categoryIDs.sorted(by: Self.stableUUIDOrder)
            )
            guard !requests.isEmpty else { return }
            var queued = 0
            for request in requests {
                _ = try await service.importFile(request, context: operationContext())
                queued += 1
            }
            statusMessage = "已将 \(queued) 个文件加入分析队列。"
            await load()
        } catch {
            statusMessage = Self.safeMessage(error)
        }
    }

    func dismissStatus() {
        statusMessage = nil
    }

    private func loadCitationsForSelection() async {
        guard let nodeID = selectedNodeID else {
            citations = []
            return
        }
        isLoadingCitations = true
        defer { isLoadingCitations = false }
        do {
            let loaded = try await service.queryCitations(
                nodeID: nodeID, context: operationContext()
            )
            guard selectedNodeID == nodeID else { return }
            citations = loaded
        } catch {
            guard selectedNodeID == nodeID else { return }
            citations = []
            statusMessage = Self.safeMessage(error)
        }
    }

    private func matchesFacet(
        _ node: YouziMemoryNodeRecord,
        snapshot: YouziMemoryWorkbenchSnapshot
    ) -> Bool {
        let categoryNames = Set((snapshot.nodeCategoryIDs[node.id] ?? []).compactMap { id in
            snapshot.categories.first(where: { $0.id == id })?.name
        })
        switch selectedFacet {
        case .all:
            return true
        case .work:
            return node.scope.kind == .project || node.scope.kind == .workspace
                || [.project, .workspace, .file, .artifact, .organization].contains(node.kind)
                || categoryNames.contains("项目与工作")
        case .family:
            return [.person, .event, .location].contains(node.kind)
                || !categoryNames.isDisjoint(with: ["人物与关系", "经历与事件", "重要日期"])
        case .knowledge:
            return [.topic, .document, .decision].contains(node.kind)
                || categoryNames.contains("知识主题")
        }
    }

    private func operationContext() -> YouziMemoryAccessContext {
        var context = accessContext
        context.requestID = UUID()
        return context
    }

    private static func safeMessage(_ error: Error) -> String {
        if let repositoryError = error as? YouziMemoryRepositoryError {
            return repositoryError.localizedDescription
        }
        return "知我暂时无法完成这个操作，请重试。"
    }

    private static func scopeSortKey(_ scope: YouziMemoryScopeRecord) -> String {
        "\(scope.kind.rawValue):\(scope.identifier?.uuidString.lowercased() ?? "")"
    }

    private static func stableUUIDOrder(_ lhs: UUID, _ rhs: UUID) -> Bool {
        lhs.uuidString.lowercased() < rhs.uuidString.lowercased()
    }
}

private struct YouziMemoryWorkbenchEnvironmentKey: EnvironmentKey {
    static let defaultValue: YouziMemoryWorkbenchModel? = nil
}

extension EnvironmentValues {
    var youziMemoryWorkbenchModel: YouziMemoryWorkbenchModel? {
        get { self[YouziMemoryWorkbenchEnvironmentKey.self] }
        set { self[YouziMemoryWorkbenchEnvironmentKey.self] = newValue }
    }
}
