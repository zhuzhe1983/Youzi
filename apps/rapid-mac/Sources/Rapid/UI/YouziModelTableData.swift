import Foundation

/// Presentation-only model-file table. No load policy, downloads or preferences
/// are changed by filtering/sorting. Missing measurements always sort last.
enum YouziModelTableData {
    enum Column: String, CaseIterable, Sendable {
        case model, downloaded, actions, size, accuracy, quality, speed, parameters, quantization, value

        func title(chinese: Bool) -> String {
            switch self {
            case .model: return chinese ? "模型" : "Model"
            case .downloaded: return chinese ? "文件 / 状态" : "Files / Status"
            case .actions: return chinese ? "操作" : "Actions"
            case .size: return chinese ? "文件大小" : "File size"
            case .accuracy: return chinese ? "准确度" : "Accuracy"
            case .quality: return chinese ? "综合质量" : "Quality"
            case .speed: return chinese ? "速度" : "Speed"
            case .parameters: return chinese ? "参数规模" : "Parameters"
            case .quantization: return chinese ? "量化" : "Quantization"
            case .value: return chinese ? "性价比 · 速质" : "Value · Q×S"
            }
        }
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all, downloaded, notDownloaded, loaded, downloading, failed
        var id: Self { self }
        func title(chinese: Bool) -> String {
            switch self {
            case .all: return chinese ? "全部状态" : "All states"
            case .downloaded: return chinese ? "已下载" : "Downloaded"
            case .notDownloaded: return chinese ? "未下载" : "Not downloaded"
            case .loaded: return chinese ? "已加载" : "Loaded"
            case .downloading: return chinese ? "下载中" : "Downloading"
            case .failed: return chinese ? "下载失败" : "Download failed"
            }
        }
    }

    struct Sort: Equatable {
        var column: Column = .model
        var ascending = true
    }

    struct Metrics: Equatable {
        var accuracy: Double?
        var quality: Double?
        var speed: Double?
        var qualityCoverage: Int = 0
        var accuracySource: String?
        var speedSource: String?
        /// Quality-adjusted throughput, not money saved or a local benchmark.
        var value: Double? {
            guard let quality, let speed, quality.isFinite, speed.isFinite,
                  (0...100).contains(quality), speed > 0 else { return nil }
            return quality / 100 * speed
        }

        init(scores: BenchScores?) {
            func percent(_ value: Double?) -> Double? {
                guard let value, value.isFinite, (0...100).contains(value) else { return nil }
                return value
            }
            accuracy = percent(scores?.generalReasoning)
            let axes = [accuracy, percent(scores?.code), percent(scores?.tool), percent(scores?.ifeval)]
            qualityCoverage = axes.compactMap { $0 }.count
            // Don't reward incomplete benchmark rows with a cherry-picked average.
            quality = qualityCoverage == 4 ? axes.compactMap { $0 }.reduce(0, +) / 4 : nil
            speed = scores?.speedTps.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            accuracySource = scores?.generalReasoningSource
            speedSource = scores?.speedSource
        }
    }

    struct Row: Identifiable, Equatable {
        let entry: ModelEntry
        let badge: ModelCacheActions.StatusBadge
        let loaded: Bool
        let loading: Bool
        var recommendationRank: Int?
        var favorite: Bool = false
        let metrics: Metrics
        let family: String
        let parameters: Double?
        let quantization: Double?
        let sizeBytes: Double?
        let estimatedSize: Bool
        var id: String { entry.alias }

        init(entry: ModelEntry, badge: ModelCacheActions.StatusBadge, loaded: Bool = false,
             loading: Bool = false, recommendationRank: Int? = nil, favorite: Bool = false,
             scores: BenchScores? = nil) {
            self.entry = entry
            self.badge = badge
            self.loaded = loaded
            self.loading = loading
            self.recommendationRank = recommendationRank
            self.favorite = favorite
            metrics = Metrics(scores: scores)
            family = ModelBrandStyle.displayFamily(forAlias: entry.alias)
            parameters = ModelSizing.parseParamsBillions(entry.alias)
                ?? entry.hfRepo.flatMap { ModelSizing.parseParamsBillions($0) }
            quantization = Self.explicitQuantization(entry.alias)
                ?? entry.hfRepo.flatMap(Self.explicitQuantization)
            if let measured = ModelCacheActions.parseSizeBytes(entry.sizeOnDisk), measured > 0 {
                sizeBytes = Double(measured)
                estimatedSize = false
            } else if !entry.cached, let parameters, let quantization {
                // Unlike memory admission estimates, file sizes exclude KV/runtime.
                sizeBytes = parameters * 1_000_000_000 * quantization / 8
                estimatedSize = true
            } else {
                sizeBytes = nil
                estimatedSize = false
            }
        }

        static func explicitQuantization(_ name: String) -> Double? {
            let lower = name.lowercased()
            if lower.contains("bf16") || lower.contains("fp16") { return 16 }
            if lower.contains("fp32") { return 32 }
            if lower.contains("ternary") { return 1.58 }
            guard let range = lower.range(of: #"(?<![\d.])\d+(?:\.\d+)?-?bit\b"#, options: .regularExpression),
                  let value = Double(lower[range].replacingOccurrences(of: "-", with: "")
                    .replacingOccurrences(of: "bit", with: "")), value > 0, value <= 32 else { return nil }
            return value
        }

        var downloading: Bool { if case .downloading = badge { return true }; return false }
        var failed: Bool { if case .failed = badge { return true }; return false }
        var canLoad: Bool { entry.cached && !loaded && !loading && !downloading }
        var canDelete: Bool { entry.cached && !entry.isExternal && !loaded && !loading && !downloading }
        var canDownload: Bool { !entry.cached && !loaded && !loading && !downloading }

        func number(for column: Column) -> Double? {
            switch column {
            case .downloaded: return entry.cached ? 1 : 0
            case .size: return sizeBytes
            case .accuracy: return metrics.accuracy
            case .quality: return metrics.quality
            case .speed: return metrics.speed
            case .parameters: return parameters
            case .quantization: return quantization
            case .value: return metrics.value
            default: return nil
            }
        }
    }

    static func visible(_ rows: [Row], query: String = "", filter: Filter = .all,
                        family: String? = nil, quantization: Double? = nil,
                        recommendedOnly: Bool = false, measuredOnly: Bool = false,
                        sorts: [Sort] = [Sort()]) -> [Row] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return rows.filter { row in
            let haystack = [row.id, row.entry.hfRepo ?? "", row.family].joined(separator: " ")
            guard terms.allSatisfy({ haystack.localizedStandardContains($0) }),
                  family == nil || family == row.family,
                  quantization == nil || quantization == row.quantization,
                  !recommendedOnly || row.recommendationRank != nil,
                  !measuredOnly || row.metrics.value != nil else { return false }
            switch filter {
            case .all: return true
            case .downloaded: return row.entry.cached
            case .notDownloaded: return !row.entry.cached
            case .loaded: return row.loaded
            case .downloading: return row.downloading
            case .failed: return row.failed
            }
        }.sorted { lhs, rhs in
            let leftRank = lhs.recommendationRank ?? Int.max
            let rightRank = rhs.recommendationRank ?? Int.max
            if leftRank != rightRank { return leftRank < rightRank }
            if lhs.favorite != rhs.favorite { return lhs.favorite }
            for sort in sorts {
                let result: ComparisonResult
                if sort.column == .model {
                    result = lhs.id.localizedStandardCompare(rhs.id)
                } else if sort.column == .actions {
                    continue
                } else {
                    let left = lhs.number(for: sort.column), right = rhs.number(for: sort.column)
                    // Deliberately independent of sort direction.
                    if left == nil && right != nil { return false }
                    if left != nil && right == nil { return true }
                    guard let left, let right else { continue }
                    result = left == right ? .orderedSame : (left < right ? .orderedAscending : .orderedDescending)
                }
                if result != .orderedSame { return sort.ascending ? result == .orderedAscending : result == .orderedDescending }
            }
            return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
        }
    }
}
