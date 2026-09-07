import AVFoundation
import Foundation

/// AVFAudio's tap and playback blocks are not annotated @Sendable in the SDK.
/// Creating them inside a @MainActor method inherits isolation, then traps at
/// closure entry when AVFAudio calls them on RealtimeMessenger.mServiceQueue.
/// An inner Task cannot fix that entry trap. Keep the *outer* closures explicitly
/// nonisolated and Sendable; only owned values/events cross to MainActor.
enum YouziLiveAudioCallbacks {
    typealias InputTap = @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    typealias PlaybackCompletion = @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void

    nonisolated static func inputTap(_ capture: YouziCaptureConverter) -> InputTap {
        { buffer, _ in
            // Consume/copy synchronously on this tap's serial service queue.
            // Never retain the framework's transient PCM buffer in a Task.
            capture.consume(buffer)
        }
    }

    nonisolated static func playbackCompletion(
        _ action: @escaping @MainActor @Sendable () -> Void
    ) -> PlaybackCompletion {
        let deliver = deliverOnMainActor(action)
        return { _ in deliver() }
    }

    nonisolated static func configurationChange(
        _ onChange: @escaping @Sendable () -> Void
    ) -> @Sendable (Notification) -> Void {
        { _ in onChange() }
    }

    nonisolated static func deliverOnMainActor(
        _ action: @escaping @MainActor @Sendable () -> Void
    ) -> @Sendable () -> Void {
        {
            // Also mandatory for notifications: the SDK forbids destroying
            // the engine synchronously on its configuration-change queue.
            Task { @MainActor in action() }
        }
    }
}
