import Foundation

/// Only public display metadata reaches the tray; never put key material in it.
enum YouziTraySnapshot {
    static func boundedPercent(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return min(100, max(0, value))
    }

    static func percent(_ value: Double?) -> String {
        boundedPercent(value).map { "\(Int($0.rounded()))%" } ?? "—"
    }

    static func isReady(_ state: String) -> Bool { state == "resident" || state == "busy" }

    static func resourceLine(cpu: Double?, gpu: Double?, memory: MemoryProbe.Snapshot?, isChinese: Bool) -> String {
        return "CPU \(percent(cpu)) · GPU \(percent(gpu)) · \(isChinese ? "内存" : "Memory") \(percent(memory.map { $0.usedRatio * 100 }))"
    }

    static func modelLines(residency: ModelResidencySnapshot, isChinese: Bool) -> [String] {
        var lines = residency.models.filter { isReady($0.state) }.map { model in
            let lane: String
            switch YouziModelLane.classify(modality: model.modality) {
            case .chat: lane = "LLM"
            case .voice: lane = "VOICE"
            case .image: lane = "IMAGE"
            case .video: lane = "VIDEO"
            case nil: lane = model.modality.uppercased()
            }
            let size = ByteCountFormatter.string(fromByteCount: Int64(clamping: model.displayBytes), countStyle: .memory)
            return "\(lane) · \(model.displayName()) · \(size)"
        }
        for audio in residency.audioLanes where isReady(audio.state) {
            guard let name = audio.model,
                  !residency.models.contains(where: { isReady($0.state) && $0.matches(name) }) else { continue }
            let displayName = name.split(separator: "/").last.map(String.init) ?? name
            lines.append("VOICE · \(displayName)")
        }
        if lines.isEmpty { lines = [isChinese ? "暂无已加载模型" : "No loaded models"] }
        return lines
    }
}
