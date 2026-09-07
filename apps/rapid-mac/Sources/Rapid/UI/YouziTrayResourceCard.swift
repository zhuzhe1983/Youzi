import AppKit
import SwiftUI

/// Read-only telemetry. The controller samples only while its menu is open;
/// this view never starts a server or changes model/default preferences.
struct YouziTrayResourceCard: View {
    let status: String
    let state: ServerState
    let residency: ModelResidencySnapshot
    let cpu: Double?
    let gpu: Double?
    let memory: MemoryProbe.Snapshot?
    let isChinese: Bool

    static let width: CGFloat = 400
    static let height: CGFloat = 152

    private var occupancy: YouziModelOccupancy {
        YouziModelOccupancy.resolve(residency: residency, host: memory, voiceLaneResident: false)
    }

    private var statusColor: Color {
        switch state {
        case .ready: .green
        case .starting: .orange
        case .crashed, .missing: .red
        case .idle, .stopped: .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 6, height: 6)
                Text(status).font(.system(size: 12, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
            }
            .foregroundStyle(Color(nsColor: .labelColor))
            .help(status)

            HStack(spacing: 16) {
                metric("CPU", value: cpu, color: YouziModelLane.chat.occupancyColor)
                metric("GPU", value: gpu, color: YouziModelLane.image.occupancyColor)
                metric(isChinese ? "内存" : "Memory", value: memory.map { $0.usedRatio * 100 },
                       color: YouziModelLane.video.occupancyColor)
            }

            VStack(spacing: 6) {
                HStack {
                    Text(isChinese ? "模型预算 · 含估算" : "Model budget · estimated")
                    Spacer(minLength: 4)
                    Text((isChinese ? "可用 " : "Available ") + availableLabel)
                }
                .font(.system(size: 11)).foregroundStyle(Color(nsColor: .secondaryLabelColor))
                YouziModelOccupancyTrack(occupancy: occupancy)
                HStack(spacing: 8) {
                    ForEach(YouziModelLane.allCases) { lane in
                        HStack(spacing: 4) {
                            Circle().fill(lane.occupancyColor).frame(width: 5, height: 5)
                            Text(title(lane)).fontWeight(.medium)
                            Text(value(lane)).monospacedDigit()
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(Color(nsColor: .labelColor))
                        if lane != .video { Spacer(minLength: 0) }
                    }
                }
                .lineLimit(1).minimumScaleFactor(0.9)
            }
            .help(isChinese
                ? "颜色与场景模型选择一致。模型数值包含预算估算，并非逐模型实测物理内存；灰色是其他占用，浅色是可用预算。语音未上报内存时显示 —，不计入比例。视频就绪不代表权重一直驻留内存。"
                : "Colors match the scenario picker. Model values include budget estimates, not per-model physical memory measurements. Gray is other usage; pale is available budget. Unreported audio memory is shown as — without an invented segment. Video readiness does not imply permanent weight residency.")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(width: Self.width, height: Self.height, alignment: .topLeading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isChinese ? "服务与资源状态" : "Service and resources")
        .accessibilityIdentifier("Youzi.MenuBar.Resources")
    }

    private var availableLabel: String {
        guard memory != nil || residency.memoryAvailableBytes != nil else { return "—" }
        return formatGigabytes(occupancy.remainingBytes)
    }

    private func title(_ lane: YouziModelLane) -> String {
        switch lane {
        case .chat: isChinese ? "聊天" : "LLM"
        case .image: isChinese ? "图片" : "IMG"
        case .voice: isChinese ? "语音" : "VOICE"
        case .video: isChinese ? "视频" : "VIDEO"
        }
    }

    private func value(_ lane: YouziModelLane) -> String {
        if lane == .voice && occupancy.voiceMemoryUnknown { return "—" }
        let bytes = occupancy.bytes[lane] ?? 0
        return bytes > 0 ? formatGigabytes(bytes) : "—"
    }

    private func metric(_ name: String, value: Double?, color: Color) -> some View {
        VStack(spacing: 5) {
            HStack(spacing: 4) {
                Text(name).foregroundStyle(Color(nsColor: .secondaryLabelColor))
                Spacer(minLength: 0)
                Text(YouziTraySnapshot.percent(value))
                    .foregroundStyle(Color(nsColor: .labelColor)).monospacedDigit()
            }.font(.system(size: 12))
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.12))
                    if let percent = YouziTraySnapshot.boundedPercent(value) {
                        Capsule().fill(color).frame(width: proxy.size.width * percent / 100)
                    }
                }
            }.frame(height: 3)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) \(YouziTraySnapshot.percent(value))")
    }
}
