import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Job transport deliberately omits history/list and arbitrary file/URL access.
/// A conversation may only retrieve/delete the ID returned by its own POST.
protocol YouziVideoToolClient: Sendable {
    func capabilities(model: String?, port: Int, bearer: String?) async throws -> VideoCapabilities
    func create(_ request: VideoCreateRequest, port: Int, bearer: String?) async throws -> VideoJob
    func retrieve(id: String, port: Int, bearer: String?) async throws -> VideoJob
    func cancelPending(id: String, port: Int, bearer: String?) async throws
    func videoData(id: String, maximumBytes: Int, port: Int, bearer: String?) async throws -> Data
}

@MainActor
struct YouziLocalVideoTool {
    typealias Failure = YouziLocalModelTools.Failure
    static let maximumOutputBytes = 64 * 1024 * 1024
    static let maximumWait: TimeInterval = 600
    static let maximumPolls = 300

    /// Credentials never enter tool arguments/results. Epoch prevents reuse of
    /// the same port/key after a server restart; no call migrates to a new host.
    struct Session: Equatable {
        let epoch: UInt64
        let port: Int
        let bearer: String
    }
    struct Input: Sendable {
        let prompt: String
        let size: String?
        let seconds: Int?
        let reference: YouziLocalModelTools.Asset?
    }

    var client: any YouziVideoToolClient
    var session: @MainActor () -> Session?
    var defaults = ModelGenerationDefaults()
    var now: @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var wait: @MainActor () async throws -> Void = { try await Task.sleep(for: .seconds(2)) }

    private func check(_ captured: Session) throws {
        try Task.checkCancellation()
        guard session() == captured else { throw Failure.model_not_ready }
    }

    private func capabilities(_ entry: ModelEntry, session captured: Session) async throws -> VideoCapabilities {
        try check(captured)
        let caps = try await client.capabilities(model: entry.alias, port: captured.port, bearer: captured.bearer).validated()
        try check(captured)
        guard caps.model == entry.alias || caps.model == entry.hfRepo else { throw Failure.capability_not_supported }
        return caps
    }

    func describe(_ entry: ModelEntry) async throws -> VideoCapabilities {
        guard let captured = session() else { throw Failure.model_not_ready }
        return try await capabilities(entry, session: captured)
    }

    func generate(_ input: Input, entry: ModelEntry) async throws -> Data {
        guard let captured = session() else { throw Failure.model_not_ready }
        let caps = try await capabilities(entry, session: captured)
        let size = input.size ?? defaults.resolveVideoSize(available: caps.sizePresets)
        guard caps.sizePresets.contains(size) else { throw Failure.invalid_arguments }
        let durations = caps.durationPresets(for: size)
        let seconds = input.seconds ?? defaults.resolveVideoSeconds(available: durations)
        guard durations.contains(seconds) else { throw Failure.invalid_arguments }
        let mime: String?
        if let reference = input.reference {
            guard caps.supportsImageInput else { throw Failure.capability_not_supported }
            mime = try Self.referenceMIME(reference, capabilities: caps)
        } else {
            guard caps.modes.contains(.textToVideo) else { throw Failure.capability_not_supported }
            mime = nil
        }
        let request = VideoCreateRequest(prompt: input.prompt, model: entry.alias, seconds: seconds, size: size,
            seed: 42, reference: input.reference?.data, referenceFileName: "reference-image", referenceMIMEType: mime)
        var ownedID: String?
        var ownedJobIsPending = false
        let started = now()
        do {
            try check(captured)
            var job = try await client.create(request, port: captured.port, bearer: captured.bearer)
            // Validate before adopting the ID. Never cancel an unrelated job
            // named by an invalid/mismatched response.
            try validate(job, request: request, entry: entry)
            ownedID = job.id
            ownedJobIsPending = job.status == .queued || job.status == .inProgress
            try check(captured)
            var polls = 0
            while job.status != .completed {
                guard job.status != .failed else { throw Failure.generation_failed }
                guard polls < Self.maximumPolls, now() - started < Self.maximumWait else { throw Failure.video_timeout }
                try await wait()
                try check(captured)
                guard now() - started < Self.maximumWait else { throw Failure.video_timeout }
                let next = try await client.retrieve(id: job.id, port: captured.port, bearer: captured.bearer)
                try check(captured)
                guard next.id == ownedID else { throw Failure.generation_failed }
                try validate(next, request: request, entry: entry)
                job = next
                ownedJobIsPending = job.status == .queued || job.status == .inProgress
                polls += 1
            }
            try check(captured)
            guard now() - started < Self.maximumWait else { throw Failure.video_timeout }
            let data = try await client.videoData(id: job.id, maximumBytes: Self.maximumOutputBytes,
                port: captured.port, bearer: captured.bearer)
            try check(captured)
            guard data.count <= Self.maximumOutputBytes else { throw Failure.output_too_large }
            guard Self.isMP4(data) else { throw Failure.generation_failed }
            // Keep the completed server job for the Video workspace. Artifact
            // persistence is owned by the caller's captured conversation/task.
            return data
        } catch {
            if let id = ownedID, ownedJobIsPending, session() == captured {
                // Parent may be canceled. This bounded transport task may cancel
                // our queued job, but MUST NOT unload a model or follow a new
                // session. Running GPU work returns 409 and remains in Videos.
                await Task { @MainActor in
                    guard session() == captured else { return }
                    try? await client.cancelPending(id: id, port: captured.port, bearer: captured.bearer)
                }.value
            }
            if Task.isCancelled { throw CancellationError() }
            if let error = error as? VideoClientError, error == .outputTooLarge { throw Failure.output_too_large }
            throw error
        }
    }

    private func validate(_ job: VideoJob, request: VideoCreateRequest, entry: ModelEntry) throws {
        _ = try VideoClient.cacheFileName(for: job.id) // strict ID alphabet/length, no paths
        guard (job.model == entry.alias || job.model == entry.hfRepo),
              job.prompt == request.prompt.trimmingCharacters(in: .whitespacesAndNewlines),
              job.size == request.size, job.seconds == String(request.seconds) else { throw Failure.generation_failed }
    }

    static func isMP4(_ data: Data) -> Bool {
        data.count >= 12 && data.subdata(in: 4..<8) == Data("ftyp".utf8)
    }

    static func referenceMIME(_ asset: YouziLocalModelTools.Asset, capabilities: VideoCapabilities) throws -> String {
        guard asset.kind == .image, !asset.data.isEmpty,
              asset.data.count <= capabilities.referenceMaximumBytes else { throw Failure.invalid_arguments }
        guard let source = CGImageSourceCreateWithData(asset.data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source), let mime = UTType(type as String)?.preferredMIMEType,
              capabilities.acceptedReferenceMIMETypes.contains(mime),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw Failure.invalid_arguments }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixels <= min(capabilities.referenceMaximumPixels ?? 40_000_000, 40_000_000) else {
            throw Failure.invalid_arguments
        }
        return mime
    }
}
