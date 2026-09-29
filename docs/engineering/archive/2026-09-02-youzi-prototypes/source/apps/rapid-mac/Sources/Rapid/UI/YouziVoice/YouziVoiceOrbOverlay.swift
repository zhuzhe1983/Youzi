import SwiftUI

/// The global voice surface is intentionally an interruption-free sensory
/// layer, not a dashboard. It renders one interactive object and no visible
/// copy, controls, transcript, diagnostics, or secondary chrome.
struct YouziVoiceOrbOverlay: View {
    let presentation: YouziVoiceOrbPresentation
    let onTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if presentation.phase != .hidden {
                ZStack {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .overlay(Color.black.opacity(0.46))
                        .ignoresSafeArea()
                        .accessibilityHidden(true)

                    YouziVoiceOrb(
                        visualState: .init(presentation),
                        reduceMotion: reduceMotion
                    )
                    .frame(width: 230, height: 230)
                    .contentShape(Circle())
                    .onTapGesture(perform: onTap)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("柚子语音")
                    .accessibilityValue(presentation.phase.accessibilityValue)
                    .accessibilityHint("点按结束语音")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier("YouziVoice.GlobalOrb")
                }
                .transition(.opacity)
                .accessibilityIdentifier("YouziVoice.ImmersiveOverlay")
            }
        }
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.22),
            value: presentation.phase
        )
    }
}

struct YouziVoiceOrbVisualState: Equatable, Sendable {
    enum Rhythm: Equatable, Sendable {
        case still
        case breathe
        case focus
        case orbit
        case resonate
        case recoil
    }

    var rhythm: Rhythm
    var energy: Double
    var coreHue: Double
    var haloHue: Double
    var isFailure: Bool

    init(_ presentation: YouziVoiceOrbPresentation) {
        rhythm = switch presentation.motion {
        case .still: .still
        case .breathe: .breathe
        case .attend: .focus
        case .orbit: .orbit
        case .resonate: .resonate
        case .recoil: .recoil
        }
        energy = min(max(Double(presentation.energy), 0), 1)
        isFailure = presentation.phase == .failed

        // Global and assistant-scoped voices share one language. Assistant
        // scope shifts the secondary light only; it never adds a badge/name.
        coreHue = isFailure ? 0.01 : 0.105
        haloHue = switch presentation.scope {
        case .assistant: 0.92
        case .global, .none: 0.48
        }
    }
}

private struct YouziVoiceOrb: View {
    let visualState: YouziVoiceOrbVisualState
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1.0 : 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let pulse = reduceMotion ? 0.0 : sin(t * pulseFrequency)
            let counterPulse = reduceMotion ? 0.0 : cos(t * pulseFrequency * 0.73)
            let expansion = 1 + pulse * pulseAmount
            let orbit = reduceMotion ? Angle.zero : Angle.radians(t * orbitSpeed)

            ZStack {
                Circle()
                    .fill(haloGradient)
                    .blur(radius: 25 + visualState.energy * 18)
                    .scaleEffect(1.04 + counterPulse * 0.055)
                    .opacity(0.48 + visualState.energy * 0.24)

                Circle()
                    .strokeBorder(
                        AngularGradient(
                            colors: [
                                haloColor.opacity(0.08),
                                haloColor.opacity(0.82),
                                coreColor.opacity(0.62),
                                haloColor.opacity(0.08),
                            ],
                            center: .center
                        ),
                        lineWidth: 2.5 + visualState.energy * 4
                    )
                    .rotationEffect(orbit)
                    .padding(10)
                    .opacity(visualState.rhythm == .still ? 0.35 : 0.9)

                Circle()
                    .fill(coreGradient)
                    .overlay(aliveSurface(t: t))
                    .overlay(
                        Circle()
                            .strokeBorder(.white.opacity(0.18), lineWidth: 0.8)
                    )
                    .shadow(color: coreColor.opacity(0.38), radius: 26, y: 10)
                    .padding(24)
                    .scaleEffect(expansion)
            }
            .drawingGroup(opaque: false, colorMode: .extendedLinear)
        }
    }

    private var coreColor: Color {
        Color(hue: visualState.coreHue, saturation: 0.78, brightness: 1)
    }

    private var haloColor: Color {
        Color(hue: visualState.haloHue, saturation: 0.68, brightness: 0.96)
    }

    private var coreGradient: some ShapeStyle {
        RadialGradient(
            colors: [
                .white.opacity(0.96),
                coreColor.opacity(0.96),
                haloColor.opacity(0.72),
                Color.black.opacity(0.92),
            ],
            center: UnitPoint(x: 0.36, y: 0.3),
            startRadius: 2,
            endRadius: 104
        )
    }

    private var haloGradient: some ShapeStyle {
        RadialGradient(
            colors: [coreColor.opacity(0.68), haloColor.opacity(0.34), .clear],
            center: .center,
            startRadius: 10,
            endRadius: 112
        )
    }

    private func aliveSurface(t: TimeInterval) -> some View {
        Canvas { context, size in
            guard visualState.rhythm != .still else { return }
            let count = visualState.rhythm == .resonate ? 5 : 3
            let radius = min(size.width, size.height) * 0.5
            for index in 0..<count {
                let phase = t * (0.55 + Double(index) * 0.11) + Double(index) * 1.7
                let x = size.width * 0.5 + cos(phase) * radius * (0.18 + visualState.energy * 0.16)
                let y = size.height * 0.5 + sin(phase * 1.23) * radius * 0.28
                let diameter = radius * (0.22 + visualState.energy * 0.2)
                let rect = CGRect(
                    x: x - diameter / 2,
                    y: y - diameter / 2,
                    width: diameter,
                    height: diameter
                )
                context.fill(
                    Path(ellipseIn: rect),
                    with: .color(index.isMultiple(of: 2)
                        ? .white.opacity(0.16) : haloColor.opacity(0.18))
                )
            }
        }
        .clipShape(Circle())
        .blendMode(.plusLighter)
    }

    private var pulseFrequency: Double {
        switch visualState.rhythm {
        case .still: 0
        case .breathe: 1.45
        case .focus: 2.6
        case .orbit: 1.9
        case .resonate: 4.8
        case .recoil: 7.2
        }
    }

    private var pulseAmount: Double {
        let base = switch visualState.rhythm {
        case .still: 0.0
        case .breathe: 0.025
        case .focus: 0.018
        case .orbit: 0.02
        case .resonate: 0.035
        case .recoil: 0.045
        }
        return base + visualState.energy * 0.022
    }

    private var orbitSpeed: Double {
        switch visualState.rhythm {
        case .still, .breathe: 0.08
        case .focus: 0.18
        case .orbit: 0.52
        case .resonate: 0.34
        case .recoil: -0.75
        }
    }
}

private extension YouziVoiceOrbPresentation.Phase {
    var accessibilityValue: String {
        switch self {
        case .hidden: "未启动"
        case .awakening: "正在唤醒"
        case .listening: "正在聆听"
        case .hearing: "听见你了"
        case .thinking: "正在思考"
        case .speaking: "正在回应"
        case .interrupted: "已打断"
        case .failed: "暂时不可用"
        }
    }
}
