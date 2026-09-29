import Foundation
import Testing
@testable import Rapid

@Suite("Youzi voice — immersive orb contract")
struct YouziVoiceOrbOverlayTests {
    @Test("Every runtime motion maps to one bounded visual state")
    func visualStateMapping() {
        let pairs: [(YouziVoiceOrbPresentation.Motion, YouziVoiceOrbVisualState.Rhythm)] = [
            (.still, .still), (.breathe, .breathe), (.attend, .focus),
            (.orbit, .orbit), (.resonate, .resonate), (.recoil, .recoil),
        ]
        for (motion, expected) in pairs {
            let state = YouziVoiceOrbVisualState(.init(
                phase: .listening,
                motion: motion,
                energy: 4,
                scope: .global
            ))
            #expect(state.rhythm == expected)
            #expect(state.energy == 1)
            #expect(!state.isFailure)
        }
    }

    @Test("Global and assistant scopes use the same orb language without identity chrome")
    func scopeIsAColorShiftOnly() {
        let global = YouziVoiceOrbVisualState(.init(
            phase: .thinking, motion: .orbit, energy: 0.5, scope: .global
        ))
        let assistant = YouziVoiceOrbVisualState(.init(
            phase: .thinking, motion: .orbit, energy: 0.5,
            scope: .assistant(id: UUID())
        ))
        #expect(global.rhythm == assistant.rhythm)
        #expect(global.energy == assistant.energy)
        #expect(global.coreHue == assistant.coreHue)
        #expect(global.haloHue != assistant.haloHue)
    }

    @Test("The global overlay renders no visible product copy or control labels")
    func sourceContract() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Sources/Rapid/UI/YouziVoice/YouziVoiceOrbOverlay.swift"
            ),
            encoding: .utf8
        )
        let renderedControlLines = source.split(separator: "\n").map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter {
            $0.hasPrefix("Text(") || $0.hasPrefix("Button(") || $0.hasPrefix("Label(")
        }
        #expect(renderedControlLines.isEmpty)
        #expect(source.contains("onTapGesture"))
        #expect(source.contains("accessibilityReduceMotion"))
        #expect(source.contains("YouziVoice.GlobalOrb"))
    }
}
