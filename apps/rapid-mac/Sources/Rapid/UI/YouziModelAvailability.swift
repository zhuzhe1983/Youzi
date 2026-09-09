import SwiftUI

/// UI availability is exact-selection readiness, not download state or any resident sibling.
/// Audio is one sector even when both selected ASR and TTS are available.
enum YouziModelAvailability {
    static func slot(for entry: ModelEntry) -> RemoteModelSlot? {
        switch entry.kind {
        case .chat: .chat
        case .image: .image
        case .video: .video
        case .audio:
            switch entry.audioCapability {
            case .speech: .speech
            case .transcription: .transcription
            default: nil
            }
        }
    }

    static func readySlots(selections: [RemoteModelSlot: String], entries: [ModelEntry],
                           residency: ModelResidencySnapshot, localReachable: Bool,
                           remoteOnline: Set<String>) -> Set<RemoteModelSlot> {
        Set(selections.compactMap { slot, alias in
            guard !alias.isEmpty else { return nil }
            if RemoteModelEndpoint.isRemote(alias) {
                return remoteOnline.contains(alias) ? slot : nil
            }
            guard localReachable else { return nil }
            // The selected canonical identity can be resident before the disk catalog arrives.
            let entry = entries.first { $0.alias == alias }
                ?? ModelEntry(alias: alias, hfRepo: nil, sizeOnDisk: nil, cached: false, kind: slot.kind)
            return YouziScenarioModels.isReady(entry, in: residency) ? slot : nil
        })
    }

    static func lanes(for slots: Set<RemoteModelSlot>) -> [YouziModelLane] {
        YouziModelLane.allCases.filter { lane in
            switch lane {
            case .chat: slots.contains(.chat)
            case .image: slots.contains(.image)
            case .voice: slots.contains(.speech) || slots.contains(.transcription)
            case .video: slots.contains(.video)
            }
        }
    }
}

/// Equal-area color sectors, not a memory chart. Palette stays blue/yellow/green/purple
/// regardless of the user's accent color. Shading adds depth without blurring the sectors.
struct YouziModelAvailabilityOrb: View {
    let lanes: [YouziModelLane]
    var body: some View {
        ZStack {
            Circle().fill(Color.secondary.opacity(0.35))
            ForEach(Array(lanes.enumerated()), id: \.element) { index, lane in
                YouziOrbSector(index: index, count: lanes.count).fill(Self.color(lane))
            }
            Circle().fill(RadialGradient(colors: [.white.opacity(0.5), .clear, .black.opacity(0.22)],
                                        center: .init(x: 0.28, y: 0.22), startRadius: 0, endRadius: 30))
            Circle().strokeBorder(.white.opacity(0.22), lineWidth: 0.6)
        }
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
    }

    static func color(_ lane: YouziModelLane) -> Color {
        switch lane {
        case .chat: Color(red: 0.15, green: 0.48, blue: 0.96)
        case .image: Color(red: 0.98, green: 0.76, blue: 0.18)
        case .voice: Color(red: 0.17, green: 0.76, blue: 0.51)
        case .video: Color(red: 0.65, green: 0.39, blue: 0.92)
        }
    }
}

struct YouziOrbSector: Shape {
    let index: Int
    let count: Int
    var degrees: Double { count > 0 ? 360 / Double(count) : 0 }
    func path(in rect: CGRect) -> Path {
        guard count > 0, (0..<count).contains(index) else { return Path() }
        if count == 1 { return Path(ellipseIn: rect) }
        let center = CGPoint(x: rect.midX, y: rect.midY)
        return Path { path in
            path.move(to: center)
            path.addArc(center: center, radius: min(rect.width, rect.height) / 2,
                        startAngle: .degrees(-90 + Double(index) * degrees),
                        endAngle: .degrees(-90 + Double(index + 1) * degrees), clockwise: false)
            path.closeSubpath()
        }
    }
}
