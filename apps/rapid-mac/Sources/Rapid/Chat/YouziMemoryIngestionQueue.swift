import Foundation
import Observation

struct YouziMemoryIngestionJob: Sendable, Identifiable {
    let id: UUID // user-message ID, not a new ID on every retry
    let source: YouziMemoryChatSource
    let scope: YouziMemoryScope
    let model: String
    let baseURL: URL
    var attempts = 0
}

/// Ephemeral, bounded, user-visible queue. It never scans history on launch.
/// Cancellation drops late results by generation even if a transport ignores it.
@MainActor @Observable
final class YouziMemoryIngestionQueue {
    private(set) var jobs: [YouziMemoryIngestionJob] = []
    private(set) var isProcessing = false
    private(set) var lastError: String?
    private(set) var completedCount = 0
    var isPaused = false {
        didSet { if isPaused { interrupt() } else { kick() } }
    }
    var voiceIsOpen = false {
        didSet { if voiceIsOpen { interrupt() } else { kick() } }
    }
    @ObservationIgnored var canRun: (YouziMemoryIngestionJob) -> Bool = { _ in false }
    @ObservationIgnored var process: (YouziMemoryIngestionJob) async throws -> Void = { _ in }
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var completed: Set<UUID> = []
    @ObservationIgnored private var lastForegroundAt = Date()
    @ObservationIgnored private let idleDelay: TimeInterval
    @ObservationIgnored private let pollNanoseconds: UInt64

    init(idleDelay: TimeInterval = 8, pollNanoseconds: UInt64 = 1_000_000_000) {
        self.idleDelay = idleDelay; self.pollNanoseconds = pollNanoseconds
    }

    func enqueue(_ job: YouziMemoryIngestionJob) {
        guard !completed.contains(job.id), !jobs.contains(where: { $0.id == job.id }) else { return }
        guard jobs.count < 32 else {
            lastError = "记忆队列已满，本条未加入；可以手动记住。 / Memory queue is full; remember this message manually."
            return
        }
        jobs.append(job); lastForegroundAt = Date(); kick()
    }

    func resumeWhenIdle() { kick() }

    func foregroundStarted() { lastForegroundAt = Date(); interrupt() }

    func cancelAll() { interrupt(); jobs = []; lastError = nil }

    func cancel(conversationID: UUID) {
        interrupt(); jobs.removeAll { $0.source.conversationID == conversationID }; kick()
    }

    func retry() {
        for i in jobs.indices { jobs[i].attempts = 0 }
        lastError = nil; kick()
    }

    private func interrupt() {
        generation += 1; worker?.cancel(); worker = nil; isProcessing = false
    }

    private func kick() {
        guard worker == nil, !jobs.isEmpty, !isPaused, !voiceIsOpen else { return }
        let epoch = generation
        worker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, epoch == self.generation else { return }
                guard !self.jobs.isEmpty, !self.isPaused, !self.voiceIsOpen else {
                    self.worker = nil; return
                }
                guard self.jobs.contains(where: { $0.attempts < 3 }) else { self.worker = nil; return }
                guard Date().timeIntervalSince(self.lastForegroundAt) >= self.idleDelay,
                      let job = self.jobs.first(where: { $0.attempts < 3 && self.canRun($0) }) else {
                    do { try await Task.sleep(nanoseconds: self.pollNanoseconds) } catch { return }
                    continue
                }
                self.isProcessing = true
                // Other media lanes can become busy while the HTTP request is
                // in flight. Cancel it promptly, retaining the job for idle time.
                let availabilityMonitor = Task { @MainActor [weak self] in
                    while !Task.isCancelled {
                        guard let self else { return }
                        do { try await Task.sleep(nanoseconds: self.pollNanoseconds) } catch { return }
                        guard epoch == self.generation else { return }
                        if !self.canRun(job) {
                            self.interrupt(); self.kick(); return
                        }
                    }
                }
                defer { availabilityMonitor.cancel() }
                do {
                    try await self.process(job)
                    guard !Task.isCancelled, epoch == self.generation else { return }
                    self.completed.insert(job.id); self.completedCount += 1
                    self.jobs.removeAll { $0.id == job.id }; self.lastError = nil
                } catch {
                    guard !Task.isCancelled, epoch == self.generation else { return }
                    self.lastError = error.localizedDescription
                    if let index = self.jobs.firstIndex(where: { $0.id == job.id }) { self.jobs[index].attempts += 1 }
                    self.lastForegroundAt = Date()
                }
                self.isProcessing = false
            }
        }
    }
}
