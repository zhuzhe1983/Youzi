import Foundation

/// A recommendation is a picker default, not permission to download or load.
enum YouziImageRecommendation {
    static let alias = "qwen-image-2.1"

    static func rank(for entry: ModelEntry, physicalMemoryGB: Double) -> Int? {
        guard entry.alias == alias, entry.kind == .image, !entry.isRemote,
              entry.imageCapability?.supportsGeneration == true,
              physicalMemoryGB >= max(24, entry.minimumMemoryGB ?? 24) else { return nil }
        return 0
    }

    /// Prefer the recommendation when downloaded, but keep a usable cached
    /// alternative ahead of a model that would require a new download.
    static func fallbackAlias(in entries: [ModelEntry]) -> String? {
        let recommended = entries.first { $0.alias == alias && !$0.isRemote }
        return (recommended.flatMap { $0.cached ? $0 : nil }
            ?? entries.first { $0.cached }
            ?? recommended
            ?? entries.first)?.alias
    }
}
