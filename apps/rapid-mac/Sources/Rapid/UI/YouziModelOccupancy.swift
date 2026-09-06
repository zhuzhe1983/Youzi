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
        for model in residency.models where model.state != "evicting" {
            switch YouziModelLane.classify(modality: model.modality) {
            case .chat: chat += model.displayBytes
            case .image: image += model.displayBytes
            case .voice: voice += model.displayBytes
            case .video: video += model.displayBytes
            case nil: break
            }
        }
        let audioLaneResident = residency.audioLanes.contains { $0.state == "resident" }
        let hasVoice = voice > 0 || audioLaneResident || voiceLaneResident
        if hasVoice, voice == 0 {
            voice = 1
        }

        let usedByModels = chat + image + voice + video
        let total = host?.totalBytes
            ?? (residency.memoryLimitBytes > 0 ? residency.memoryLimitBytes : usedByModels)
        let remaining: UInt64
        if let available = residency.memoryAvailableBytes, total > 0 {
            remaining = min(available, total)
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
            mode: mode
        )
    }
}

extension ModelResidencySnapshot {
    var containsTextOrMLLM: Bool {
        models.contains {
            ($0.modality == "text" || $0.modality == "mllm") && $0.state != "evicting"
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
    let occupancy: YouziModelOccupancy

    var body: some View {
        VStack(alignment: .leading, spacing: RapidTheme.Space.xxs) {
            GeometryReader { proxy in
                let width = max(0, proxy.size.width)
                let total = max(1, Double(occupancy.totalBytes))
                let chatWidth = max(0, CGFloat(Double(occupancy.chatBytes) / total) * width)
                let imageWidth = max(0, CGFloat(Double(occupancy.imageBytes) / total) * width)
                let voiceWidth = max(0, CGFloat(Double(occupancy.voiceBytes) / total) * width)
                let videoWidth = max(0, CGFloat(Double(occupancy.videoBytes) / total) * width)

                HStack(spacing: 1) {
                    if chatWidth > 1 {
                        Rectangle()
                            .fill(YouziModelLane.chat.occupancyColor)
                            .frame(width: chatWidth)
                    }
                    if imageWidth > 1 {
                        Rectangle()
                            .fill(YouziModelLane.image.occupancyColor)
                            .frame(width: imageWidth)
                    }
                    if voiceWidth > 1 {
                        Rectangle()
                            .fill(YouziModelLane.voice.occupancyColor)
                            .frame(width: voiceWidth)
                    }
                    if videoWidth > 1 {
                        Rectangle()
                            .fill(YouziModelLane.video.occupancyColor)
                            .frame(width: videoWidth)
                    }
                    Rectangle()
                        .fill(RapidTheme.surfaceRaised)
                }
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            }
            .frame(height: 6)

            HStack(spacing: RapidTheme.Space.xs) {
                if occupancy.chatBytes > 0 {
                    occupancyLegend(lane: .chat, bytes: occupancy.chatBytes)
                }
                if occupancy.imageBytes > 0 {
                    occupancyLegend(lane: .image, bytes: occupancy.imageBytes)
                }
                if occupancy.voiceBytes > 0 {
                    occupancyLegend(lane: .voice, bytes: occupancy.voiceBytes)
                }
                if occupancy.videoBytes > 0 {
                    occupancyLegend(lane: .video, bytes: occupancy.videoBytes)
                }
                Spacer(minLength: 0)
                Text("可用 " + formatGigabytes(occupancy.remainingBytes))
                    .font(RapidFont.caption)
                    .foregroundStyle(RapidTheme.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("模型内存占用: 聊天 \(formatGigabytes(occupancy.chatBytes)), 图像 \(formatGigabytes(occupancy.imageBytes)), 可用 \(formatGigabytes(occupancy.remainingBytes))")
    }

    private func occupancyLegend(lane: YouziModelLane, bytes: UInt64) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(lane.occupancyColor)
                .frame(width: 6, height: 6)
            Text("\(lane.menuTitle) \(formatGigabytes(bytes))")
                .font(RapidFont.caption)
                .foregroundStyle(RapidTheme.textSecondary)
        }
    }
}
