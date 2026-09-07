import Foundation

/// Identity spans every assistant/tool round of one ChatViewModel send, not just
/// one message. A completed turn is still identifiable while its audio drains.
struct LiveVoiceChatTurn: Equatable, Sendable {
    let conversationID: UUID
    let turnID: UUID
}

/// Pure ownership/cancellation authority. Every asynchronous boundary must check
/// BOTH its epoch and the current chat identity before publishing audio or text.
struct LiveVoiceTurnState: Sendable {
    private(set) var epoch: UInt64 = 0
    private(set) var isActive = false
    private(set) var ownedTurn: LiveVoiceChatTurn?

    @discardableResult mutating func start() -> UInt64 {
        epoch &+= 1
        isActive = true
        ownedTurn = nil
        return epoch
    }

    mutating func own(_ turn: LiveVoiceChatTurn, at expectedEpoch: UInt64) -> Bool {
        guard accepts(expectedEpoch) else { return false }
        ownedTurn = turn
        return true
    }

    func accepts(_ expectedEpoch: UInt64) -> Bool {
        isActive && epoch == expectedEpoch
    }

    func accepts(_ expectedEpoch: UInt64, currentTurn: LiveVoiceChatTurn) -> Bool {
        accepts(expectedEpoch) && ownedTurn == currentTurn
    }

    /// Returns a cancellation target only if the current chat still belongs to
    /// this session. Never fall back to a blanket ChatViewModel.stop().
    @discardableResult mutating func invalidate(
        currentTurn: LiveVoiceChatTurn, isStreaming: Bool, stopping: Bool = false
    ) -> LiveVoiceChatTurn? {
        let target = isStreaming && ownedTurn == currentTurn ? ownedTurn : nil
        epoch &+= 1
        ownedTurn = nil
        if stopping { isActive = false }
        return target
    }

    /// Successful completion is an epoch boundary too. A transport callback
    /// retained by the previous turn must not become valid when the next turn
    /// acquires ownership in the same microphone session.
    mutating func releaseTurn() { epoch &+= 1; ownedTurn = nil }
}
