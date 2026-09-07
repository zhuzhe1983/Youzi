import Foundation
import Testing
@testable import Rapid

@MainActor
@Suite("Youzi conversation video job lifecycle", .serialized)
struct YouziLocalVideoToolTests {
    @MainActor final class Fixture: YouziVideoToolClient {
        let entry = ModelEntry(alias: "explicit-video", hfRepo: "org/video", sizeOnDisk: nil, cached: true, kind: .video, videoCapabilities: [.textToVideo, .imageToVideo])
        var active: YouziLocalVideoTool.Session? = .init(epoch: 1, port: 8123, bearer: "test-only")
        var time: TimeInterval = 0
        var polls = 0
        var capabilitiesModels: [String?] = []
        var requests: [VideoCreateRequest] = []
        var deleted: [String] = []
        var downloaded: [String] = []
        var statuses: [VideoJobStatus] = [.queued, .inProgress, .completed]
        var onCapabilities: () -> Void = {}
        var onCreate: () -> Void = {}
        var onRetrieve: () -> Void = {}
        var onDownload: () -> Void = {}
        var waitAction: (() async throws -> Void)?
        var badModel = false
        var badID = false
        var capsModel = "org/video"
        var data = Data([0, 0, 0, 20]) + Data("ftypisom0000".utf8)
        let suite = "YouziVideoTool." + UUID().uuidString
        lazy var preferences = UserDefaults(suiteName: suite)!
        deinit { UserDefaults.standard.removePersistentDomain(forName: suite) }
        // Construct on the actor instead of a lazy stored initializer; the
        // runner captures the fixture and must not form a retained self-cycle.
        var runner: YouziLocalVideoTool {
            YouziLocalVideoTool(client: self, session: { [self] in active },
                defaults: ModelGenerationDefaults(defaults: preferences), now: { [self] in time }, wait: { [self] in
                    if let waitAction { try await waitAction() } else { time += 2 }
                })
        }
        var input: YouziLocalVideoTool.Input { .init(prompt: "A moonlit lake", size: nil, seconds: nil, reference: nil) }
        func capabilities(model: String?, port: Int, bearer: String?) async throws -> VideoCapabilities {
            capabilitiesModels.append(model); onCapabilities()
            let json = """
            {"model":"\(capsModel)","family":"ltx-2.3","modes":["text-to-video","image-to-video"],"limits":{
            "size":{"type":"fixed","values":["512x512","768x512"]},
            "seconds":{"minimum":1,"maximum":4,"default":4},"fps":{"minimum":24,"maximum":24,"default":24,"fixed":true},
            "frames":{"minimum":9,"maximum":121,"step":8,"offset":1},
            "workload":{"metric":"pixel_frames","maximum":100000000,"dimension_rounding":"ceil_to_64"},
            "input_reference":{"maximum_bytes":1024,"maximum_pixels":4,"formats":["png"]}}}
            """
            return try JSONDecoder().decode(VideoCapabilities.self, from: Data(json.utf8))
        }
        func job(_ status: VideoJobStatus) -> VideoJob {
            let request = requests.last!
            return .init(id: badID ? "other_job" : "video_own", model: badModel ? "another-model" : request.model,
                prompt: request.prompt, seconds: String(request.seconds), size: request.size, status: status,
                progress: status == .completed ? 100 : 0, createdAt: 1, completedAt: nil, error: nil)
        }
        func create(_ request: VideoCreateRequest, port: Int, bearer: String?) async throws -> VideoJob {
            requests.append(request); onCreate(); return job(statuses.first ?? .queued)
        }
        func retrieve(id: String, port: Int, bearer: String?) async throws -> VideoJob {
            polls += 1; onRetrieve(); return job(statuses[min(polls, statuses.count - 1)])
        }
        func cancelPending(id: String, port: Int, bearer: String?) async throws { deleted.append(id) }
        func videoData(id: String, maximumBytes: Int, port: Int, bearer: String?) async throws -> Data {
            downloaded.append(id); onDownload(); return data
        }
    }

    @Test("Capabilities and job address the explicit model, settings choose compatible presets")
    func success() async throws {
        let f = Fixture()
        f.preferences.set("768x512", forKey: ModelGenerationDefaults.Key.videoSize)
        f.preferences.set(2, forKey: ModelGenerationDefaults.Key.videoSeconds)
        let data = try await f.runner.generate(f.input, entry: f.entry)
        #expect(data == f.data)
        #expect(f.capabilitiesModels == [f.entry.alias])
        #expect(f.requests.count == 1 && f.requests[0].model == f.entry.alias)
        #expect(f.requests[0].size == "768x512" && f.requests[0].seconds == 2)
        #expect(f.polls == 2 && f.downloaded == ["video_own"] && f.deleted.isEmpty)
    }

    @Test("Explicit unsupported controls fail before POST, never silently substitute")
    func controls() async throws {
        let f = Fixture()
        let input = YouziLocalVideoTool.Input(prompt: "moon", size: "999x999", seconds: 3, reference: nil)
        await #expect(throws: YouziLocalModelTools.Failure.invalid_arguments) { try await f.runner.generate(input, entry: f.entry) }
        #expect(f.requests.isEmpty && f.deleted.isEmpty)
    }

    @Test("A different capability model cannot authorize video generation")
    func wrongCapabilities() async throws {
        let f = Fixture(); f.capsModel = "different-model"
        await #expect(throws: YouziLocalModelTools.Failure.capability_not_supported) { try await f.runner.generate(f.input, entry: f.entry) }
        #expect(f.requests.isEmpty)
    }

    @Test("A same-port, same-key session change invalidates each async stage", arguments: ["capabilities", "create", "retrieve", "download"])
    func sessionChange(stage: String) async throws {
        let f = Fixture()
        let change = { f.active = .init(epoch: 2, port: 8123, bearer: "test-only") }
        switch stage {
        case "capabilities": f.onCapabilities = change
        case "create": f.onCreate = change
        case "retrieve": f.onRetrieve = change
        default: f.onDownload = change
        }
        await #expect(throws: YouziLocalModelTools.Failure.model_not_ready) { try await f.runner.generate(f.input, entry: f.entry) }
        #expect(f.deleted.isEmpty) // Never send cleanup to a replacement server.
        if stage == "capabilities" { #expect(f.requests.isEmpty) }
    }

    @Test("Both elapsed time and poll count bound waiting, without resubmission", arguments: [true, false])
    func timeout(useClock: Bool) async throws {
        let f = Fixture(); f.statuses = [.queued]
        f.waitAction = { if useClock { f.time += 601 } }
        await #expect(throws: YouziLocalModelTools.Failure.video_timeout) { try await f.runner.generate(f.input, entry: f.entry) }
        #expect(f.requests.count == 1 && f.downloaded.isEmpty && f.deleted == ["video_own"])
        #expect(f.polls == (useClock ? 0 : YouziLocalVideoTool.maximumPolls))
    }

    @Test("Stop during waiting cleans up only the tool-owned pending ID")
    func cancellation() async throws {
        let f = Fixture()
        f.waitAction = { throw CancellationError() }
        await #expect(throws: CancellationError.self) { try await f.runner.generate(f.input, entry: f.entry) }
        #expect(f.deleted == ["video_own"] && f.downloaded.isEmpty && f.requests.count == 1)
    }

    @Test("Canceling the actual parent Task still runs cleanup without saving content")
    func actualTaskCancellation() async throws {
        let f = Fixture()
        f.waitAction = { try await Task.sleep(for: .seconds(30)) }
        let operation = Task { try await f.runner.generate(f.input, entry: f.entry) }
        for _ in 0..<200 where f.requests.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!f.requests.isEmpty)
        operation.cancel()
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(f.deleted == ["video_own"] && f.downloaded.isEmpty)
    }

    @Test("Failed jobs and invalid completed media never return invented artifacts")
    func badOutputs() async throws {
        let f = Fixture(); f.statuses = [.failed]
        await #expect(throws: YouziLocalModelTools.Failure.generation_failed) { try await f.runner.generate(f.input, entry: f.entry) }
        #expect(f.downloaded.isEmpty && f.deleted.isEmpty)
        let completed = Fixture(); completed.statuses = [.completed]; completed.data = Data("<html>error</html>".utf8)
        await #expect(throws: YouziLocalModelTools.Failure.generation_failed) { try await completed.runner.generate(completed.input, entry: completed.entry) }
        #expect(completed.deleted.isEmpty) // Preserve the server result for inspection.
    }

    @Test("Mismatched create responses never grant access to another job")
    func wrongJob() async throws {
        let f = Fixture(); f.badModel = true
        await #expect(throws: YouziLocalModelTools.Failure.generation_failed) { try await f.runner.generate(f.input, entry: f.entry) }
        #expect(f.deleted.isEmpty && f.downloaded.isEmpty)
        let polled = Fixture(); polled.onRetrieve = { polled.badID = true }
        await #expect(throws: YouziLocalModelTools.Failure.generation_failed) { try await polled.runner.generate(polled.input, entry: polled.entry) }
        #expect(polled.deleted == ["video_own"] && polled.downloaded.isEmpty)
    }

    @Test("Image input is decoded for MIME and pixel limits, not trusted by its extension")
    func referenceValidation() async throws {
        let f = Fixture()
        let caps = try await f.runner.describe(f.entry)
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jGmQAAAAASUVORK5CYII=")!
        let asset = YouziLocalModelTools.Asset(id: UUID(), name: "not-trusted.jpg", kind: .image, mime: "image/jpeg", data: png)
        #expect(try YouziLocalVideoTool.referenceMIME(asset, capabilities: caps) == "image/png")
        let input = YouziLocalVideoTool.Input(prompt: "Animate the moon", size: nil, seconds: nil, reference: asset)
        _ = try await f.runner.generate(input, entry: f.entry)
        #expect(f.requests[0].reference == png && f.requests[0].referenceMIMEType == "image/png")
        let bad = YouziLocalModelTools.Asset(id: UUID(), name: "fake.png", kind: .image, mime: "image/png", data: Data("not an image".utf8))
        #expect(throws: YouziLocalModelTools.Failure.invalid_arguments) { try YouziLocalVideoTool.referenceMIME(bad, capabilities: caps) }
    }
}
