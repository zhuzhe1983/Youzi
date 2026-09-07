import Foundation

/// A conservative scheduling estimate for backpressure, never an assertion of
/// audible completion. Only the engine's dataPlayedBack/drained callback clears
/// outstanding playback. Use a monotonic clock (systemUptime), not wall time.
struct LiveVoicePlaybackPacing {
    private(set) var scheduledUntil: TimeInterval = 0
    let maximumAhead: TimeInterval
    init(maximumAhead: TimeInterval = 1.5) { self.maximumAhead = maximumAhead }

    func shouldWait(now: TimeInterval) -> Bool { scheduledUntil - now > maximumAhead }

    mutating func scheduled(byteCount: Int, sampleRate: Double, now: TimeInterval) {
        guard byteCount > 0, sampleRate.isFinite, sampleRate > 0 else { return }
        // TTS speed is already represented in emitted PCM sample count. Applying
        // the generation speed setting again here would pace the same audio twice.
        scheduledUntil = max(now, scheduledUntil) + Double(byteCount) / 2 / sampleRate
    }

    mutating func drained() { scheduledUntil = 0 }
}
