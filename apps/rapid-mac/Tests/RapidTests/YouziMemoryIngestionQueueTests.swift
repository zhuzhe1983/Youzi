import Foundation
import Testing
@testable import Rapid

@MainActor
@Suite("Memory ingestion queue")
struct YouziMemoryIngestionQueueTests {
    private func job() -> YouziMemoryIngestionJob {
        let source = YouziMemoryChatSource(conversationID: UUID(), messageID: UUID(), title: "Test",
                                           text: "I prefer Swift", createdAt: Date())
        return .init(id: source.messageID, source: source, scope: .personal, model: "local-model",
                     baseURL: URL(string: "http://127.0.0.1:9999")!)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() && Date() < deadline { try await Task.sleep(for: .milliseconds(2)) }
        #expect(condition())
    }

    @Test("Pause and voice gates defer work, then complete each message only once")
    func gatesAndDeduplication() async throws {
        let queue = YouziMemoryIngestionQueue(idleDelay: 0, pollNanoseconds: 1_000_000)
        defer { queue.cancelAll() }
        queue.canRun = { _ in true }
        var processed = 0
        queue.process = { _ in processed += 1 }
        queue.isPaused = true
        queue.voiceIsOpen = true
        let first = job()
        queue.enqueue(first); queue.enqueue(first)
        #expect(queue.jobs.count == 1 && processed == 0)
        queue.isPaused = false
        #expect(processed == 0)
        queue.voiceIsOpen = false
        try await waitUntil { queue.completedCount == 1 }
        queue.enqueue(first)
        #expect(queue.jobs.isEmpty && processed == 1)
    }

    @Test("Unavailable model does not block an eligible queued message")
    func eligibleJobSelection() async throws {
        let queue = YouziMemoryIngestionQueue(idleDelay: 0, pollNanoseconds: 1_000_000)
        defer { queue.cancelAll() }
        let blocked = job(); let ready = job()
        queue.canRun = { $0.id == ready.id }
        queue.enqueue(blocked); queue.enqueue(ready)
        try await waitUntil { queue.completedCount == 1 }
        #expect(queue.jobs.map(\.id) == [blocked.id])
    }

    @Test("Cancellation discards late completion from a transport that ignores cancellation")
    func lateCompletion() async throws {
        let queue = YouziMemoryIngestionQueue(idleDelay: 0, pollNanoseconds: 1_000_000)
        defer { queue.cancelAll() }
        queue.canRun = { _ in true }
        var continuation: CheckedContinuation<Void, Never>?
        queue.process = { _ in await withCheckedContinuation { continuation = $0 } }
        queue.enqueue(job())
        try await waitUntil { continuation != nil }
        queue.cancelAll()
        continuation?.resume()
        for _ in 0..<10 { await Task.yield() }
        #expect(queue.completedCount == 0 && queue.jobs.isEmpty && !queue.isProcessing)
    }

    @Test("Foreground work cancels in-flight processing and resumes from the same message")
    func foregroundCancellation() async throws {
        let queue = YouziMemoryIngestionQueue(idleDelay: 0, pollNanoseconds: 1_000_000)
        defer { queue.cancelAll() }
        queue.canRun = { _ in true }
        var started = 0
        queue.process = { _ in
            started += 1
            if started == 1 { try await Task.sleep(for: .seconds(10)) }
        }
        queue.enqueue(job())
        try await waitUntil { started == 1 }
        queue.foregroundStarted()
        #expect(!queue.isProcessing && queue.jobs.count == 1)
        queue.resumeWhenIdle()
        try await waitUntil { queue.completedCount == 1 }
        #expect(started == 2)
    }

    @Test("A newly busy media lane interrupts extraction and preserves its retry")
    func mediaLaneCancellation() async throws {
        let queue = YouziMemoryIngestionQueue(idleDelay: 0, pollNanoseconds: 1_000_000)
        defer { queue.cancelAll() }
        var available = true
        var attempts = 0
        queue.canRun = { _ in available }
        queue.process = { _ in
            attempts += 1
            if attempts == 1 { try await Task.sleep(for: .seconds(10)) }
        }
        queue.enqueue(job())
        try await waitUntil { attempts == 1 }
        available = false
        try await waitUntil { !queue.isProcessing }
        #expect(queue.jobs.count == 1 && queue.completedCount == 0)
        available = true
        try await waitUntil { queue.completedCount == 1 }
        #expect(attempts == 2)
    }

    @Test("Retry budget is bounded and explicit retry succeeds")
    func retryBudget() async throws {
        let queue = YouziMemoryIngestionQueue(idleDelay: 0, pollNanoseconds: 1_000_000)
        defer { queue.cancelAll() }
        queue.canRun = { _ in true }
        var calls = 0
        queue.process = { _ in calls += 1; throw CocoaError(.fileReadUnknown) }
        queue.enqueue(job())
        try await waitUntil { calls == 3 }
        #expect(queue.jobs.first?.attempts == 3 && queue.lastError != nil)
        queue.process = { _ in calls += 1 }
        queue.retry()
        try await waitUntil { queue.completedCount == 1 }
        #expect(calls == 4 && queue.lastError == nil)
    }

    @Test("Queue is bounded and conversation cancellation preserves other jobs")
    func boundedQueue() {
        let queue = YouziMemoryIngestionQueue()
        defer { queue.cancelAll() }
        queue.isPaused = true
        let first = job()
        queue.enqueue(first)
        for _ in 0..<40 { queue.enqueue(job()) }
        #expect(queue.jobs.count == 32 && queue.lastError != nil)
        queue.cancel(conversationID: first.source.conversationID)
        #expect(queue.jobs.count == 31 && !queue.jobs.contains(where: { $0.id == first.id }))
    }
}

extension MemoryExtractorTests {
    @Test("Candidate parser rejects fabricated evidence, foreign messages and control operations")
    func groundedCandidates() throws {
        let source = YouziMemoryChatSource(conversationID: UUID(), messageID: UUID(), title: "Test",
                                           text: "I prefer Swift", createdAt: Date())
        let valid: [String: Any] = ["content": "Prefers Swift", "kind": "preference",
                                    "message_id": source.messageID.uuidString, "quote": "prefer Swift"]
        var invented = valid; invented["quote"] = "prefer Rust"
        var foreign = valid; foreign["message_id"] = UUID().uuidString
        var deletion = valid; deletion["action"] = "remove"
        var unknown = valid; unknown["kind"] = "credential"
        let bytes = try JSONSerialization.data(withJSONObject: [valid, invented, foreign, deletion, unknown])
        let parsed = try MemoryExtractor.parseCandidates(String(decoding: bytes, as: UTF8.self), source: source)
        #expect(parsed.count == 1 && parsed.first?.quote == "prefer Swift")
        #expect(throws: MemoryExtractor.ExtractError.self) { try MemoryExtractor.parseCandidates("invalid", source: source) }
    }
}
