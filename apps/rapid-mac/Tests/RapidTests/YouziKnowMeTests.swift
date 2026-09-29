import AppKit
import SwiftUI
import Testing
@testable import Rapid

@MainActor
@Suite("About Me memory review", .serialized)
struct YouziKnowMeTests {
    private final class WriteGate {
        var fail = false
    }

    @MainActor private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("youzi-know-me-\(UUID())")
        let suite = "youzi-know-me-\(UUID())"
        let gate = WriteGate()
        let store: MemoryStore
        let i18n: YouziI18nConfig
        let fonts: YouziFontSizeConfig
        var domainURL: URL { root.appendingPathComponent("domain.json") }
        var legacyURL: URL { root.appendingPathComponent("legacy.json") }

        init(importedCount: Int = 0) throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let defaults = try #require(UserDefaults(suiteName: suite))
            if importedCount > 0 {
                let entries = (1...importedCount).map { MemoryEntry(content: "Fixture preference \($0)") }
                try JSONEncoder().encode(MemoryLibrary(entries: entries))
                    .write(to: root.appendingPathComponent("legacy.json"))
            }
            let gate = gate
            let product = YouziProductModel(store: YouziDomainStore(
                fileURL: root.appendingPathComponent("domain.json"), beforeAtomicReplace: {
                    if gate.fail { throw CocoaError(.fileWriteUnknown) }
                }))
            store = MemoryStore(fileURL: root.appendingPathComponent("legacy.json"), defaults: defaults, product: product)
            i18n = YouziI18nConfig(defaults: defaults)
            i18n.language = .zhHans
            fonts = YouziFontSizeConfig(defaults: defaults)
        }

        func stage(alias: String = "") -> GoldenStage {
            GoldenStage(KnowMeFixtureView(assistantAlias: alias)
                .environment(store).environment(i18n).environment(fonts),
                size: CGSize(width: 920, height: 1800))
        }

        func reload() -> MemoryStore {
            MemoryStore(fileURL: legacyURL, defaults: UserDefaults(suiteName: suite)!,
                        product: YouziProductModel(store: YouziDomainStore(fileURL: domainURL)))
        }

        deinit {
            try? FileManager.default.removeItem(at: root)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
    }

    @Test("Eight migrated memories are visible for review; native confirmation updates the page and survives restart")
    func importedReview() async throws {
        let fixture = try Fixture(importedCount: 8)
        let stage = fixture.stage()
        let id = try #require(fixture.store.service.nodes.first?.id)
        let confirm = "YouziSimple.KnowMe.Confirm.\(id.uuidString)"
        try await stage.waitForText("待你确认（8）")
        #expect(fixture.store.service.nodes.allSatisfy { $0.state == .proposed && $0.lastConfirmedAt == nil })
        try stage.press(confirm)
        try await stage.waitForText("待你确认（7）")
        try await stage.waitForText("已记住（1）")
        try await stage.waitForIdentifierGone(confirm)
        #expect(fixture.store.service.nodes.first(where: { $0.id == id })?.state == .confirmed)
        let reloaded = fixture.reload()
        #expect(reloaded.service.nodes.count == 8)
        #expect(reloaded.service.nodes.first(where: { $0.id == id })?.lastConfirmedAt != nil)
        #expect(reloaded.service.nodes.filter { $0.state == .proposed }.count == 7)
    }

    @Test("Manual native entry saves while collection is off; remote mode explains why it creates no automatic memories")
    func manualEntry() async throws {
        let fixture = try Fixture()
        let stage = fixture.stage(alias: "youzi-remote/fixture")
        try await stage.waitForText("自动记忆已关闭")
        try stage.setValue("Fixture: concise answers", for: "YouziSimple.KnowMe.AddField")
        try stage.press("YouziSimple.KnowMe.Add")
        try await stage.waitForText("已记住（1）")
        #expect(fixture.store.service.nodes.first?.state == .confirmed)
        #expect(fixture.reload().entries.first?.content == "Fixture: concise answers")
        #expect(!fixture.store.isEnabled)
        fixture.store.isEnabled = true
        try await stage.waitForText("当前使用远程模型，不会自动收集或引用记忆")
        #expect(fixture.store.ingestion.jobs.isEmpty)
    }

    @Test("A failed native confirmation stays pending and displays the error without changing stored data")
    func failedConfirmation() async throws {
        let fixture = try Fixture(importedCount: 1)
        let stage = fixture.stage()
        let id = try #require(fixture.store.service.nodes.first?.id)
        let original = try Data(contentsOf: fixture.domainURL)
        fixture.gate.fail = true
        let confirm = "YouziSimple.KnowMe.Confirm.\(id.uuidString)"
        try await stage.waitForIdentifier(confirm)
        try stage.press(confirm)
        try await stage.waitForIdentifier("YouziSimple.KnowMe.Error")
        #expect(stage.treeText().contains("待你确认（1）"))
        #expect(fixture.store.service.nodes.first?.state == .proposed)
        #expect(try Data(contentsOf: fixture.domainURL) == original)
    }
}

private struct KnowMeFixtureView: View {
    @Environment(MemoryStore.self) private var store
    let assistantAlias: String

    var body: some View {
        YouziSimpleKnowMePage(nodes: store.service.product.document.memoryNodes, assistantAlias: assistantAlias)
    }
}
