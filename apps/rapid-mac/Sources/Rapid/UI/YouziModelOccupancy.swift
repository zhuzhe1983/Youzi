import Foundation
import SwiftUI

enum YouziModelLane: String, Equatable, Sendable, CaseIterable, Identifiable {
    case chat
    case image
    case voice
    case video

    var id: String { rawValue }

    var menuTitle: String {
        switch self {
        case .chat: "聊天"
        case .image: "图像"
        case .voice: "语音"
        case .video: "视频"
        }
    }

    var occupancyColor: Color {
        switch self {
        case .chat: RapidTheme.brand
        case .image: RapidTheme.amber
        case .voice: RapidTheme.green
        case .video: Color(red: 0.53, green: 0.34, blue: 0.78)
        }
    }

    static func classify(modality: String) -> YouziModelLane? {
        switch modality.lowercased() {
        case "text", "mllm": .chat
        case "image-gen", "image": .image
        case "audio": .voice
        case "video-gen", "video": .video
        default: nil
        }
    }
}

struct YouziModelOccupancy: Equatable, Sendable {
    var chatBytes: UInt64
    var imageBytes: UInt64
    var voiceBytes: UInt64
    var videoBytes: UInt64
    var remainingBytes: UInt64
    var totalBytes: UInt64
    var hostUsedRatio: Double
    var mode: YouziRuntimeMode
    var voiceMemoryUnknown = false

    var bytes: [YouziModelLane: UInt64] {
        [.chat: chatBytes, .image: imageBytes, .voice: voiceBytes, .video: videoBytes]
    }

    static func resolve(
        residency: ModelResidencySnapshot,
        host: MemoryProbe.Snapshot?,
        voiceLaneResident: Bool
    ) -> YouziModelOccupancy {
        var chat: UInt64 = 0
        var image: UInt64 = 0
        var voice: UInt64 = 0
        var video: UInt64 = 0
        for model in residency.models where model.state == "resident" || model.state == "busy" {
            switch YouziModelLane.classify(modality: model.modality) {
            case .chat: chat += model.displayBytes
            case .image: image += model.displayBytes
            case .voice: voice += model.displayBytes
            case .video: video += model.displayBytes
            case nil: break
            }
        }
        let audioLaneResident = residency.audioLanes.contains { $0.model != nil && ($0.state == "resident" || $0.state == "busy") }
        let hasVoice = voice > 0 || audioLaneResident || voiceLaneResident
        // Shared audio caches currently report readiness but no trustworthy
        // per-model allocation. Do not fabricate a 1-byte memory measurement.
        let voiceMemoryUnknown = hasVoice && voice == 0

        let usedByModels = chat + image + voice + video
        let total = host?.totalBytes
            ?? (residency.memoryLimitBytes > 0 ? residency.memoryLimitBytes : usedByModels)
        let remaining: UInt64
        if let available = residency.memoryAvailableBytes, total > 0 {
            remaining = min(available, total)
        } else if let host {
            remaining = host.totalBytes > host.usedBytes ? host.totalBytes - host.usedBytes : 0
        } else if total >= usedByModels {
            remaining = total - usedByModels
        } else {
            remaining = 0
        }
        let hostRatio = host?.usedRatio ?? (total == 0 ? 0 : Double(usedByModels) / Double(total))
        let mode = YouziRuntimeMode.resolve(
            hasChat: chat > 0 || residency.containsTextOrMLLM,
            hasVoice: hasVoice,
            hasImage: image > 0,
            hasVideo: video > 0
        )
        return YouziModelOccupancy(
            chatBytes: chat,
            imageBytes: image,
            voiceBytes: voice,
            videoBytes: video,
            remainingBytes: remaining,
            totalBytes: max(total, usedByModels + remaining),
            hostUsedRatio: hostRatio,
            mode: mode,
            voiceMemoryUnknown: voiceMemoryUnknown
        )
    }
}

extension ModelResidencySnapshot {
    var containsTextOrMLLM: Bool {
        models.contains {
            ($0.modality == "text" || $0.modality == "mllm") && ($0.state == "resident" || $0.state == "busy")
        }
    }
}


func formatGigabytes(_ bytes: UInt64) -> String {
    let gb = Double(bytes) / Double(1 << 30)
    if gb < 0.1 {
        return "0 GB"
    }
    return String(format: "%.1f GB", gb)
}

struct YouziModelOccupancyBar: View {
    @Environment(YouziI18nConfig.self) private var i18n
    let occupancy: YouziModelOccupancy

    var body: some View {
        VStack(alignment: .leading, spacing: RapidTheme.Space.xxs) {
            YouziModelOccupancyTrack(occupancy: occupancy)
                .help(i18n.text(zh: "颜色对应不同模型类型。数值可能含运行时估算；灰色是其他占用，浅色是剩余预算。语音未上报的内存不伪造比例。", en: "Colors identify model types; values may include runtime estimates. Gray is other usage, pale is remaining budget. Unreported audio memory has no fabricated segment."))

            HStack(spacing: RapidTheme.Space.xs) {
                if occupancy.chatBytes > 0 {
                    occupancyLegend(lane: .chat, bytes: occupancy.chatBytes)
                }
                if occupancy.imageBytes > 0 {
                    occupancyLegend(lane: .image, bytes: occupancy.imageBytes)
                }
                if occupancy.voiceMemoryUnknown {
                    Text(i18n.text(zh: "语音 · —", en: "VOICE · —")).font(RapidFont.caption)
                        .foregroundStyle(YouziModelLane.voice.occupancyColor)
                        .help(i18n.text(zh: "语音模型已常驻；运行时暂未提供该模型的内存占用。", en: "Audio is resident; per-model memory is not reported by the runtime."))
                } else if occupancy.voiceBytes > 0 {
                    occupancyLegend(lane: .voice, bytes: occupancy.voiceBytes)
                }
                if occupancy.videoBytes > 0 {
                    occupancyLegend(lane: .video, bytes: occupancy.videoBytes)
                }
                Spacer(minLength: 0)
                Text(Self.availableMemoryText(occupancy.remainingBytes, isChinese: i18n.isChinese))
                    .font(RapidFont.caption)
                    .foregroundStyle(RapidTheme.textSecondary)
            }
            .lineLimit(1).minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(i18n.text(zh: "模型内存占用", en: "Model memory usage"))
    }

    static func availableMemoryText(_ bytes: UInt64, isChinese: Bool) -> String {
        let size = String(format: "%.1fG", Double(bytes) / Double(1 << 30))
        return (isChinese ? "可用内存：" : "Available memory: ") + size
    }

    private func title(_ lane: YouziModelLane) -> String {
        switch lane {
        case .chat: i18n.text(zh: "聊天", en: "LLM")
        case .image: i18n.text(zh: "图片", en: "IMG")
        case .voice: i18n.text(zh: "语音", en: "VOICE")
        case .video: i18n.text(zh: "视频", en: "VIDEO")
        }
    }

    private func occupancyLegend(lane: YouziModelLane, bytes: UInt64) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(lane.occupancyColor)
                .frame(width: 6, height: 6)
            Text("\(title(lane)) \(formatGigabytes(bytes))")
                .font(RapidFont.caption)
                .foregroundStyle(RapidTheme.textSecondary)
        }
    }
}

/// Shared visual only: no polling, loading, or model-selection side effects.
struct YouziModelOccupancyTrack: View {
    let occupancy: YouziModelOccupancy

    var body: some View {
        GeometryReader { proxy in
            let total = max(1, Double(occupancy.totalBytes))
            let known = occupancy.bytes.values.reduce(UInt64(0), +)
            let other = occupancy.totalBytes > known + occupancy.remainingBytes
                ? occupancy.totalBytes - known - occupancy.remainingBytes : 0
            HStack(spacing: 0) {
                ForEach(YouziModelLane.allCases) { lane in
                    let bytes = occupancy.bytes[lane] ?? 0
                    if bytes > 0 {
                        Rectangle().fill(lane.occupancyColor)
                            .frame(width: CGFloat(Double(bytes) / total) * proxy.size.width)
                    }
                }
                if other > 0 {
                    Rectangle().fill(Color.secondary.opacity(0.25))
                        .frame(width: CGFloat(Double(other) / total) * proxy.size.width)
                }
                Rectangle().fill(Color.secondary.opacity(0.08))
            }
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        }
        .frame(height: 7)
    }
}
