import AppKit
import SwiftUI
import Testing
@testable import Rapid

@Suite("Youzi native model table")
struct YouziModelTableTests {
    typealias Data = YouziModelTableData

    private func scores(_ quality: Double = 80, speed: Double? = 40) -> BenchScores {
        BenchScores(generalReasoning: quality, generalReasoningSource: "recorded fixture",
                    mmluPro: nil, gpqaDiamond: nil, code: quality, tool: quality, ifeval: quality,
                    speedTps: speed, speedSource: "test hardware / workload")
    }
    private func row(_ alias: String, cached: Bool = false, size: String? = nil,
                     rank: Int? = nil, scores: BenchScores? = nil) -> Data.Row {
        Data.Row(entry: .init(alias: alias, hfRepo: "org/\(alias)", sizeOnDisk: size, cached: cached),
                 badge: cached ? .cached : .notCached, recommendationRank: rank, scores: scores)
    }

    @Test("Numeric sorting covers every requested metric in both directions; gaps always last")
    func sorts() {
        let low = row("a-2b-2bit", size: "2 GB", scores: scores(40, speed: 20))
        let high = row("z-10b-8bit", size: "10 GB", scores: scores(80, speed: 100))
        let missing = row("unknown")
        for column in [Data.Column.size, .accuracy, .quality, .speed, .parameters, .quantization, .value] {
            #expect(Data.visible([missing, high, low], sorts: [.init(column: column)]).map(\.id) == [low.id, high.id, missing.id])
            #expect(Data.visible([missing, low, high], sorts: [.init(column: column, ascending: false)]).map(\.id) == [high.id, low.id, missing.id])
        }
        let cached = row("cached", cached: true)
        #expect(Data.visible([cached, missing], sorts: [.init(column: .downloaded)]).first?.id == missing.id)
        #expect(Data.visible([cached, missing], sorts: [.init(column: .downloaded, ascending: false)]).first?.id == cached.id)
    }

    @Test("Recommendations are two ordinary pinned rows, not duplicates or filter exceptions")
    func recommendations() {
        let primary = row("z-primary", cached: true, rank: 0)
        let alternate = row("x-faster", rank: 1)
        let other = row("a-other", cached: true)
        let rows = [other, alternate, primary]
        for ascending in [true, false] {
            #expect(Data.visible(rows, sorts: [.init(column: .model, ascending: ascending)]).map(\.id) == [primary.id, alternate.id, other.id])
        }
        #expect(Data.visible(rows, query: "other").map(\.id) == [other.id])
        #expect(Data.visible(rows, filter: .notDownloaded).map(\.id) == [alternate.id])
        #expect(Data.visible(rows, recommendedOnly: true).map(\.id) == [primary.id, alternate.id])
        #expect(Set(Data.visible(rows).map(\.id)).count == 3)
    }

    @Test("Search combines terms across alias and repo; filters intersect and never mutate the catalog")
    func filters() {
        let qwen = row("Qwen-8b-4bit", cached: true, scores: scores())
        let gemma = row("gemma-12b-8bit")
        let downloading = Data.Row(entry: .init(alias: "pending", hfRepo: nil, sizeOnDisk: nil, cached: false), badge: .downloading(percent: 42))
        let loaded = Data.Row(entry: qwen.entry, badge: .inUse, loaded: true)
        let failed = Data.Row(entry: gemma.entry, badge: .failed(message: "fixture"))
        let rows = [qwen, gemma, downloading]
        #expect(Data.visible(rows, query: " ORG  qWeN ", filter: .downloaded).map(\.id) == [qwen.id])
        #expect(Data.visible(rows, query: "qwen", filter: .notDownloaded).isEmpty)
        #expect(Data.visible(rows, family: gemma.family, quantization: 8).map(\.id) == [gemma.id])
        #expect(Data.visible(rows, quantization: 2).isEmpty)
        #expect(Data.visible(rows, measuredOnly: true).map(\.id) == [qwen.id])
        #expect(Data.visible(rows, filter: .downloading).map(\.id) == [downloading.id])
        #expect(Data.visible([qwen, loaded], filter: .loaded) == [loaded])
        #expect(Data.visible([gemma, failed], filter: .failed) == [failed])
        #expect(rows.count == 3 && rows[0].entry.cached)
    }

    @Test("Index is transparent, requires all four quality axes, and does not fabricate invalid data")
    func metrics() {
        let result = Data.Metrics(scores: scores(80, speed: 40))
        #expect(result.accuracy == 80 && result.quality == 80 && result.value == 32)
        #expect(result.speedSource == "test hardware / workload")
        let partial = BenchScores(generalReasoning: 95, generalReasoningSource: nil,
            mmluPro: nil, gpqaDiamond: nil, code: nil, tool: nil, ifeval: nil, speedTps: 200)
        let gap = Data.Metrics(scores: partial)
        #expect(gap.accuracy == 95 && gap.qualityCoverage == 1 && gap.quality == nil && gap.value == nil)
        for invalid in [Double.nan, .infinity, -1, 101] {
            #expect(Data.Metrics(scores: scores(invalid)).quality == nil)
        }
        for invalid in [Double.nan, .infinity, -1, 0] {
            #expect(Data.Metrics(scores: scores(speed: invalid)).value == nil)
        }
        #expect(Data.Metrics(scores: nil).value == nil)
        #expect(Data.Metrics(scores: scores(0, speed: 40)).value == 0)
    }

    @Test("Disk measurements, estimates, total parameters and explicit precision remain distinguishable")
    func fileMetrics() {
        let measured = row("qwen-8b-4bit", cached: true, size: "7.9 GiB")
        #expect(measured.sizeBytes == Double(ModelCacheActions.parseSizeBytes("7.9 GiB")!))
        #expect(!measured.estimatedSize)
        let estimated = row("qwen-8b-4bit")
        #expect(estimated.sizeBytes == 4_000_000_000 && estimated.estimatedSize)
        #expect(row("qwen-8b-4bit", cached: true).sizeBytes == nil)
        #expect(row("custom").quantization == nil)
        #expect(row("custom").sizeBytes == nil)
        #expect(Data.Row.explicitQuantization("fp16") == 16)
        #expect(Data.Row.explicitQuantization("bf16") == 16)
        #expect(Data.Row.explicitQuantization("model-1.58bit-ternary") == 1.58)
        #expect(Data.Row.explicitQuantization("model-16-bit") == 16)
        #expect(row("qwen-80b-a3b-4bit").parameters == 80)
    }

    @Test("Load/download/delete availability never permits deletion of external or resident weights")
    func actions() {
        let file = row("downloaded", cached: true)
        #expect(file.canLoad && file.canDelete && !file.canDownload)
        let missing = row("missing")
        #expect(missing.canDownload && !missing.canLoad && !missing.canDelete)
        for row in [Data.Row(entry: file.entry, badge: .inUse, loaded: true),
                    Data.Row(entry: file.entry, badge: .cached, loading: true),
                    Data.Row(entry: file.entry, badge: .downloading(percent: nil))] {
            #expect(!row.canDelete && !row.canLoad && !row.canDownload)
        }
        var external = file.entry
        external.isExternal = true
        let linked = Data.Row(entry: external, badge: .cached)
        #expect(linked.canLoad && !linked.canDelete)
    }

    @Test("Catalog retains actual speed benchmark provenance")
    func provenance() {
        let scored = BenchScoresCatalog.allAliases.compactMap { BenchScoresCatalog.lookup(alias: $0) }.filter { $0.speedTps != nil }
        #expect(!scored.isEmpty)
        #expect(scored.allSatisfy { $0.speedSource?.isEmpty == false })
    }

    @Test("Native columns have resize floors and sorting; actions stay near the model")
    @MainActor func nativeTable() {
        let rows = [row("a-model"), row("z-model")]
        var observed: [Data.Sort] = []
        let view = YouziNativeModelTable(rows: rows, chinese: true, scale: 1, sorts: [.init()], onSort: { observed = $0 }, cell: { row, _ in AnyView(Text(row.id)) })
        let coordinator = view.makeCoordinator()
        let table = NSTableView()
        table.dataSource = coordinator; table.delegate = coordinator
        table.reloadData()
        #expect(table.numberOfRows == 2)
        table.sortDescriptors = [NSSortDescriptor(key: "size", ascending: false)]
        #expect(observed == [.init(column: .size, ascending: false)])
        #expect(Data.Column.allCases.prefix(3) == [.model, .downloaded, .actions])
        #expect(YouziNativeModelTable.width(.actions, scale: 1.32) >= 200)
    }

    @Test("Available memory has an explicit localized label and compact G unit")
    @MainActor func availableMemoryLabel() {
        #expect(YouziModelOccupancyBar.availableMemoryText(80 << 30, isChinese: true) == "可用内存：80.0G")
        #expect(YouziModelOccupancyBar.availableMemoryText(0, isChinese: true) == "可用内存：0.0G")
        #expect(YouziModelOccupancyBar.availableMemoryText((1 << 30) / 2, isChinese: true) == "可用内存：0.5G")
        #expect(YouziModelOccupancyBar.availableMemoryText(80 << 30, isChinese: false) == "Available memory: 80.0G")
        #expect(formatGigabytes(80 << 30) == "80.0 GB", "Other model-size labels must not change")
    }

    @Test("Scenario popover removes the paragraph and keeps settings in the scenario toolbar")
    func scenarioSource() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/Rapid/UI/YouziScenarioModelPicker.swift"), encoding: .utf8)
        #expect(!source.contains("勾选表示已就绪"))
        #expect(!source.contains("场景模型选择"))
        #expect(!source.contains("Scenario models"))
        #expect(source.contains("YouziScenarioModelMemoryHeader(occupancy: occupancy, refreshing: loading)"))
        let toolbar = try #require(source.range(of: "HStack(spacing: 12) {"))
        let end = try #require(source.range(of: "YouziScenarioModelPicker.ScenarioToolbar"))
        #expect(source[toolbar.lowerBound..<end.upperBound].contains("moreModelSettings"))
        #expect(source.components(separatedBy: "Button(i18n.text(zh: \"更多模型设置…\"").count == 2)
    }
}
