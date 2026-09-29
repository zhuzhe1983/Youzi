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

/// Equal-area readiness sectors in the composer's muted palette. A matte surface
/// and the shared control outline keep this secondary picker below the primary action.
struct YouziModelAvailabilityOrb: View {
    let lanes: [YouziModelLane]
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Circle().fill(RapidTheme.surfaceOverlay)
            ForEach(Array(lanes.enumerated()), id: \.element) { index, lane in
                YouziOrbSector(index: index, count: lanes.count)
                    .fill(Self.color(lane).opacity(colorScheme == .dark ? 0.65 : 0.7))
            }
            Circle().strokeBorder(RapidTheme.hairlineStrong, lineWidth: 1)
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }

    static func color(_ lane: YouziModelLane) -> Color {
        switch lane {
        case .chat: RapidTheme.brandSecondary
        case .image: RapidTheme.brandPrimaryDeep
        case .voice: RapidTheme.green
        case .video: Color(red: 0.55, green: 0.46, blue: 0.67)
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
