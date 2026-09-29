import Foundation
import Testing
@testable import Rapid

@MainActor
@Suite("Youzi Know Me Graph-C workbench", .serialized)
struct YouziMemoryWorkbenchTests {
    private let now = Date(timeIntervalSince1970: 1_800_100_000)

    @Test("Graph layout is deterministic, order-independent, finite, and depth-aware")
    func deterministicLayout() throws {
        let nodes = [
            node(id: id(1), label: "项目", kind: .project),
            node(id: id(2), label: "同事", kind: .person),
            node(id: id(3), label: "Swift", kind: .topic),
        ]
        let edge = YouziMemoryEdgeRecord(
            id: id(10), sourceNodeID: id(1), targetNodeID: id(2),
            relation: .responsibleFor, explanation: "负责", confidence: 0.9,
            sensitivity: .ordinary, scope: .personal, state: .confirmed,
            revision: 1, validFrom: nil, validUntil: nil,
            createdAt: now, updatedAt: now, deletedAt: nil
        )

        let first = YouziMemoryGraphLayout.positions(nodes: nodes, edges: [edge])
        let shuffled = YouziMemoryGraphLayout.positions(
            nodes: [nodes[2], nodes[0], nodes[1]], edges: [edge]
        )
        #expect(first == shuffled)
        #expect(first.count == 3)
        #expect(first.values.allSatisfy {
            $0.x.isFinite && $0.y.isFinite && $0.z.isFinite
                && (-1 ... 1).contains($0.x)
                && (-1 ... 1).contains($0.y)
                && (-1 ... 1).contains($0.z)
        })

        let position = try #require(first[id(1)])
        let projected = YouziMemoryGraphLayout.project(
            position, yaw: 0.4, zoom: 1.2, pan: .zero,
            viewport: .init(width: 800, height: 600)
        )
        #expect(projected.point.x.isFinite)
        #expect(projected.point.y.isFinite)
        #expect((0.72 ... 1.12).contains(projected.scale))
    }

    @Test("Workbench reads one repository truth and supports filter, evidence, classification, and forget")
    func realRepositoryLifecycle() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = YouziMemoryMCPService(repository: fixture.repository)
        let categories = try await fixture.repository.seedSystemCategories(at: now)
        let workCategory = try #require(categories.first { $0.name == "项目与工作" })
        let knowledgeCategory = try #require(categories.first { $0.name == "知识主题" })
        let source = source(id: id(20))
        let citation = citation(id: id(21), sourceID: source.id)
        try await fixture.repository.registerSource(source)
        try await fixture.repository.addCitation(citation)

        let workID = id(30)
        let familyID = id(31)
        let knowledgeID = id(32)
        _ = try await service.propose(
            .init(
                idempotencyKey: "workbench-fixture", sourceID: source.id,
                sourceRevision: source.revision, policyVersion: "policy-v1",
                nodes: [
                    candidate(
                        id: workID, key: "project", label: "柚子项目",
                        kind: .project, citationID: citation.id,
                        categoryIDs: [workCategory.id]
                    ),
                    candidate(
                        id: familyID, key: "family", label: "家人小林",
                        kind: .person, citationID: citation.id
                    ),
                    candidate(
                        id: knowledgeID, key: "knowledge", label: "Swift 并发",
                        kind: .topic, citationID: citation.id,
                        categoryIDs: [knowledgeCategory.id]
                    ),
                ],
                edges: [], submittedAt: now
            ),
            context: context()
        )

        let model = YouziMemoryWorkbenchModel(
            service: service, accessContext: context()
        )
        await model.load()
        #expect(model.phase == .loaded)
        #expect(model.visibleNodes.count == 3)
        #expect(model.snapshot?.hasMoreNodes == false)

        model.selectedFacet = .work
        #expect(model.visibleNodes.map(\.id) == [workID])
        model.selectedFacet = .family
        #expect(model.visibleNodes.map(\.id) == [familyID])
        model.selectedFacet = .knowledge
        #expect(model.visibleNodes.map(\.id) == [knowledgeID])
        model.selectedFacet = .all
        model.query = "swift"
        #expect(model.visibleNodes.map(\.id) == [knowledgeID])
        model.query = ""

        await model.select(knowledgeID)
        #expect(model.citations.map(\.id) == [citation.id])
        let loadedCitation = try #require(model.citations.first)
        #expect(loadedCitation.excerpt == citation.excerpt)
        await model.classifySelected(categoryIDs: [workCategory.id, knowledgeCategory.id])
        #expect(model.statusMessage == "分类已更新。")
        #expect(model.categoryIDs(for: knowledgeID) == [workCategory.id, knowledgeCategory.id])

        await model.forgetSelected()
        #expect(model.statusMessage == "这条记忆已删除。")
        #expect(model.snapshot?.nodes.contains { $0.id == knowledgeID } == false)
        try await fixture.repository.integrityCheck()
    }

    @Test("Snapshot reports truncation and node classification is revision guarded")
    func capAndClassificationCAS() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let service = YouziMemoryMCPService(repository: fixture.repository)
        let categories = try await fixture.repository.seedSystemCategories(at: now)
        let category = try #require(categories.first)
        let source = source(id: id(40))
        let citation = citation(id: id(41), sourceID: source.id)
        try await fixture.repository.registerSource(source)
        try await fixture.repository.addCitation(citation)
        let firstID = id(42)
        let secondID = id(43)
        _ = try await service.propose(
            .init(
                idempotencyKey: "cap-fixture", sourceID: source.id,
                sourceRevision: source.revision, policyVersion: "policy-v1",
                nodes: [
                    candidate(id: firstID, key: "one", label: "一", kind: .topic, citationID: citation.id),
                    candidate(id: secondID, key: "two", label: "二", kind: .topic, citationID: citation.id),
                ], edges: [], submittedAt: now
            ),
            context: context()
        )
        let snapshot = try await service.workbenchSnapshot(
            context: context(), maximumNodes: 1
        )
        #expect(snapshot.nodes.count == 1)
        #expect(snapshot.hasMoreNodes)

        let stored = try #require(await fixture.repository.node(id: firstID))
        let revised = try await service.classifyNode(
            nodeID: firstID, expectedRevision: stored.revision,
            categoryIDs: [category.id], context: context(), at: now.addingTimeInterval(1)
        )
        #expect(revised.revision == stored.revision + 1)
        await #expect(throws: YouziMemoryRepositoryError.revisionConflict) {
            try await service.classifyNode(
                nodeID: firstID, expectedRevision: stored.revision,
                categoryIDs: [], context: context(), at: now.addingTimeInterval(2)
            )
        }
    }

    @Test("Simple Mode fails closed without injection and never creates a UI memory store")
    func sourceBoundary() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let uiRoot = root.appendingPathComponent("Sources/Rapid/UI/YouziSimple")
        let shell = try String(
            contentsOf: uiRoot.appendingPathComponent("YouziSimpleShell.swift"),
            encoding: .utf8
        )
        let model = try String(
            contentsOf: uiRoot.appendingPathComponent("YouziMemoryWorkbenchModel.swift"),
            encoding: .utf8
        )
        let view = try String(
            contentsOf: uiRoot.appendingPathComponent("YouziMemoryWorkbenchView.swift"),
            encoding: .utf8
        )

        #expect(shell.contains("@Environment(\\.youziMemoryWorkbenchModel)"))
        #expect(shell.contains("YouziMemoryWorkbenchUnavailableView"))
        #expect(!shell.contains("productModel.document.memoryNodes"))
        #expect(!model.contains("YouziMemoryRepository("))
        #expect(!view.contains("YouziMemoryRepository("))
        #expect(!view.contains("sqlite3_"))
        #expect(model.contains("maximumNodes: 120"))
        #expect(view.contains("已展示前"))
        #expect(view.contains("accessibilityReduceMotion"))
        #expect(view.contains("YouziMemory.Citation."))
        #expect(view.contains("文件内容由同一知我服务按授权读取"))
    }

    private func node(
        id: UUID,
        label: String,
        kind: YouziMemoryRecordKind
    ) -> YouziMemoryNodeRecord {
        .init(
            id: id, canonicalKey: label, label: label, content: label,
            kind: kind, confidence: 0.9, sensitivity: .ordinary,
            scope: .personal, state: .confirmed, revision: 1,
            validFrom: nil, validUntil: nil,
            createdAt: now, updatedAt: now, lastConfirmedAt: now,
            deletedAt: nil, mergedIntoID: nil
        )
    }

    private func source(id: UUID) -> YouziMemorySourceRecord {
        .init(
            id: id, kind: .chat, externalIdentifier: "conversation-\(id.uuidString)",
            revision: "r1", title: "知我测试来源", scope: .personal,
            permissionID: nil, importMode: nil, authorization: .authorized,
            contentChecksum: nil, importedAt: now, updatedAt: now, deletedAt: nil
        )
    }

    private func citation(id: UUID, sourceID: UUID) -> YouziMemoryCitationRecord {
        .init(
            id: id, sourceID: sourceID, sourceRevision: "r1",
            locator: .init(kind: .message, key: "message-1", detail: nil, ordinal: 0),
            sourceTimestamp: now, excerpt: "有权访问的结构化引用",
            contentChecksum: String(repeating: "a", count: 64), createdAt: now
        )
    }

    private func candidate(
        id: UUID,
        key: String,
        label: String,
        kind: YouziMemoryRecordKind,
        citationID: UUID,
        categoryIDs: [UUID] = []
    ) -> YouziMemoryNodeCandidate {
        .init(
            id: id, canonicalKey: key, label: label, content: "\(label) 的详情",
            kind: kind, confidence: 0.9, sensitivity: .ordinary,
            scope: .personal, validFrom: nil, validUntil: nil,
            citationIDs: [citationID], categoryIDs: categoryIDs
        )
    }

    private func context() -> YouziMemoryAccessContext {
        .init(
            requestID: UUID(), allowedScopes: [.personal], mayReadSensitive: false,
            mayPropose: true, mayManageCandidates: true, maximumResults: 20
        )
    }

    private func id(_ value: UInt8) -> UUID {
        UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
    }

    private final class Fixture {
        let root: URL
        let repository: YouziMemoryRepository

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "youzi-memory-workbench-\(UUID().uuidString)", isDirectory: true
            )
            repository = try YouziMemoryRepository(
                databaseURL: root.appendingPathComponent("memory.sqlite")
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
