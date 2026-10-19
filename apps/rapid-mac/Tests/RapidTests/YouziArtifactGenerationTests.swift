import SwiftUI

import AppKit
import ImageIO
import Testing
@testable import Rapid

@Suite("Artifact generation metadata and reroll", .serialized)
struct YouziArtifactGenerationTests {
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aD1sAAAAASUVORK5CYII=")!
    static var record: YouziArtifactGeneration {
        .init(operation: .image, source: .init(location: .local, modelAlias: "qwen-image", modelName: "Qwen Image", modelID: "example/model", server: "http://127.0.0.1:8000/v1"), prompt: "七步诗，水墨画 🌸",
              requested: ["size": .string("1920x1080"), "seed": .number(7)],
              submitted: ["size": .string("1920x1088")], reported: ["seed": .number(7), "steps": .number(40)])
    }
    static func word(_ count: Int, little: Bool = false) -> Data {
        let bytes = (0..<4).reversed().map { UInt8(truncatingIfNeeded: count >> ($0 * 8)) }
        return Data(little ? bytes.reversed() : bytes)
    }
    static var wav: Data {
        let pcm = Data([0,0,1,0,2,0,3,0])
        let format = Data([1,0,1,0,0x80,0xbb,0,0,0,0x77,1,0,2,0,16,0])
        let body = Data("WAVEfmt ".utf8)+word(format.count,little:true)+format+Data("data".utf8)+word(pcm.count,little:true)+pcm
        return Data("RIFF".utf8)+word(body.count,little:true)+body
    }
    static var mp4: Data {
        word(20)+Data("ftypisom".utf8)+Data(repeating:0,count:4)+Data("isom".utf8)+word(12)+Data("mdatDATA".utf8)
    }
    @Test("PNG metadata travels with the file and does not change image pixels")
    func pngRoundTrip() throws {
        let original = Self.png
        let output = try YouziGenerationEmbedding.embed(Self.record, in: original, kind: .image)
        #expect(try YouziGenerationEmbedding.read(output, kind: .image) == Self.record)
        #expect(try YouziGenerationEmbedding.embed(Self.record, in: output, kind: .image) == output)
        let before = try #require(CGImageSourceCreateWithData(original as CFData,nil))
        let after = try #require(CGImageSourceCreateWithData(output as CFData,nil))
        let left = try #require(CGImageSourceCreateImageAtIndex(before,0,nil))
        let right = try #require(CGImageSourceCreateImageAtIndex(after,0,nil))
        #expect(left.width == right.width && left.height == right.height)
        #expect(left.dataProvider?.data == right.dataProvider?.data)
        var next = Self.record; next.prompt = "新的提示词"
        let replaced = try YouziGenerationEmbedding.embed(next, in: output, kind: .image)
        #expect(try YouziGenerationEmbedding.read(replaced, kind: .image) == next)
        #expect(replaced.count < output.count * 2)
    }
    @Test("WAV PCM and MP4 media positions survive metadata insertion")
    func mediaPreservation() throws {
        for (kind, original) in [(YouziArtifactKind.audio,Self.wav),(.video,Self.mp4)] {
            let output = try YouziGenerationEmbedding.embed(Self.record,in:original,kind:kind)
            #expect(try YouziGenerationEmbedding.read(output,kind:kind) == Self.record)
            if kind == .audio { #expect(output[8..<original.count] == original[8..<original.count]) }
            else { #expect(output.prefix(original.count) == original) }
            #expect(try YouziGenerationEmbedding.embed(Self.record,in:output,kind:kind) == output)
        }
        // A final zero-length MP4 box is made explicit, without moving data.
        var openEnded = Self.mp4; openEnded.replaceSubrange(20..<24,with:Self.word(0))
        let output = try YouziGenerationEmbedding.embed(Self.record,in:openEnded,kind:.video)
        #expect(output[24..<32] == openEnded[24..<32])
        #expect(try YouziGenerationEmbedding.read(output,kind:.video) == Self.record)
    }
    @Test("Malformed or oversized containers fail safely before mutation")
    func malformed() throws {
        for (kind, bytes) in [(YouziArtifactKind.image,Self.png),(.audio,Self.wav),(.video,Self.mp4)] {
            for length in [0,4,9,bytes.count-1] {
                #expect(throws: (any Error).self) { try YouziGenerationEmbedding.embed(Self.record,in:Data(bytes.prefix(length)),kind:kind) }
            }
        }
        var huge = Self.record; huge.prompt = String(repeating:"x",count:300_000)
        #expect(throws: (any Error).self) { try YouziGenerationEmbedding.embed(huge,in:Self.png,kind:.image) }
    }
    @Test("Reroll preserves effective settings, changes seed, and rejects server drift")
    func replayParameters() throws {
        let args = Self.record.rerollArguments(seed:7)
        #expect(args["size"] == .string("1920x1088") && args["seed"] == .number(8))
        #expect(args["steps"] == .number(40) && args["prompt"] == .string(Self.record.prompt))
        let address = YouziGenerationSource.safeServer("https://user:password@example.test/v1?api_key=secret#token")
        #expect(address == "https://example.test/v1")
        var remote = Self.record
        remote.source = .init(location:.remote,modelAlias:"youzi-remote/id",modelName:"Example",modelID:"provider-model",server:address)
        #expect(remote.canReroll && remote.source.matches(remote.source))
        var moved = remote.source; moved.server = "https://other.test/v1"
        #expect(!remote.source.matches(moved))
        #expect(remote.rerollArguments()["seed"] == nil && remote.rerollArguments()["steps"] == nil)
        remote.source.server = nil
        #expect(!remote.canReroll)
    }
    @Test("Legacy artifacts decode without metadata and recovery joins exact tool IDs")
    func historicalRecovery() throws {
        let artifact = YouziArtifact(taskID:UUID(),title:"old.png",kind:.image,fileID:UUID())
        let decoded = try JSONDecoder().decode(YouziArtifact.self,from:JSONEncoder().encode(artifact))
        #expect(decoded.generation == nil)
        let args: [String:CodableJSON] = ["prompt":.string("七步诗"),"size":.string("1920x1080")]
        let call = ToolCall(id:"owned",name:"youzi_generate_image",arguments:String(decoding:try JSONEncoder().encode(args),as:UTF8.self))
        let messages = [ChatMessage(role:.assistant,content:"",toolCalls:[call]),
            ChatMessage(role:.tool,content:"{\"artifact_id\":\"\(artifact.id)\",\"generation\":{\"model\":\"local-image\",\"parameters_reported\":false,\"seed\":123,\"effective_size\":\"1920x1088\"}}",toolCallID:"owned")]
        let recovered = try #require(YouziArtifactGeneration.recover(artifact:artifact,messages:messages))
        #expect(recovered.prompt == "七步诗" && recovered.source.server == nil && recovered.reported["seed"] == nil)
        #expect(recovered.submitted["size"] == .string("1920x1088") && recovered.canReroll)
        var unrelated = artifact; unrelated.taskID = UUID()
        let other = YouziArtifact(taskID:unrelated.taskID,title:artifact.title,kind:.image,fileID:artifact.fileID)
        #expect(YouziArtifactGeneration.recover(artifact:other,messages:messages) == nil)
    }
    @Test("Artifact bytes, metadata, export and historical embedding stay consistent")
    func persistence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("youzi-generation-\(UUID())")
        defer { try? FileManager.default.removeItem(at:root) }
        let store = YouziDomainStore(fileURL:root.appendingPathComponent("domain.json"))
        let access = YouziWorkspaceAccessCoordinator(managedRoot:root.appendingPathComponent("workspaces"))
        let files = YouziManagedFileStore(root:root.appendingPathComponent("files"),workspaceAccess:access)
        let repository = YouziLifecycleRepository(store:store,workspaceAccess:access,fileStore:files)
        let task = YouziTask(title:"Original task",request:"")
        try store.save(.init(tasks:[task]))
        let (artifact, doc) = try repository.createArtifact(data:Self.png,named:"test.png",kind:.image,taskID:task.id,generation:Self.record)
        #expect(doc.artifacts[0].generation == Self.record)
        let saved = try repository.withAccess(toFile:artifact.fileID) { try Data(contentsOf:$0) }
        #expect(try YouziGenerationEmbedding.read(saved,kind:.image) == Self.record)
        let export = root.appendingPathComponent("export.png")
        try files.export(doc.files[0],to:export,workspaces:[:])
        #expect(try Data(contentsOf:export) == saved)
        let (old, _) = try repository.createArtifact(data:Self.png,named:"old.png",kind:.image,taskID:task.id)
        _ = try store.update { doc in doc.artifacts[doc.artifacts.firstIndex(where: { $0.id == old.id })!].generation = Self.record }
        let embedded = try repository.embedGeneration(artifactID:old.id)
        #expect(embedded.artifacts.count == 2 && embedded.files.first(where: { $0.id == old.fileID })!.byteCount! > Int64(Self.png.count))
        #expect(try repository.withAccess(toFile:old.fileID) { try YouziGenerationEmbedding.read(Data(contentsOf:$0),kind:.image) } == Self.record)
    }
    @MainActor @Test("Tool reroll saves a new artifact with original owner and parent provenance")
    func reroll() async throws {
        let f = YouziLocalModelToolsTests.Fixture(); f.ready.insert(f.image.alias)
        let first = try await f.call("youzi_generate_image",["model":f.image.alias,"prompt":"moon","size":"768x512","seed":7])
        #expect(!first.isError)
        let saved = try #require(f.saved.first)
        let record = try #require(saved.value.1.generation)
        #expect(record.prompt == "moon" && record.source.modelAlias == f.image.alias)
        let artifact = YouziArtifact(id:saved.key,taskID:f.context.taskID,title:"first.png",kind:.image,generation:record,fileID:UUID())
        let controller = YouziArtifactReroll()
        controller.start(artifact:artifact,generation:record,tools:f.tools)
        controller.start(artifact:artifact,generation:record,tools:f.tools) // suppressed while in flight
        for _ in 0..<100 where controller.running { try await Task.sleep(for:.milliseconds(5)) }
        #expect(controller.result?.isError == false && f.saved.count == 2 && f.generations == 2)
        let generated = try #require(f.saved.first { $0.key != saved.key })
        #expect(generated.value.1.generation?.parentArtifactID == artifact.id)
        #expect(generated.value.1.taskID == artifact.taskID && f.saved[saved.key]?.0.data == saved.value.0.data)
        #expect(f.capturedImage?.seed != 7)
        var wrong = record.source; wrong.modelID = "different weights"
        f.tools.requiredSource = wrong
        let failure = try await f.call("youzi_generate_image",["model":f.image.alias,"prompt":"moon"])
        #expect(failure.isError && failure.content.contains("source_changed") && f.generations == 2)
    }
    @MainActor @Test("Generation details render without sending requests", .enabled(if:ProcessInfo.processInfo.environment["YOUZI_GENERATION_RENDER"] == "1"))
    func render() async throws {
        let defaults = UserDefaults(suiteName:"generation-render-\(UUID())")!
        let i18n = YouziI18nConfig(defaults:defaults); i18n.language = .zhHans
        let view = YouziGenerationInformation(generation:Self.record).padding(24).frame(width:600).environment(i18n).environment(\.colorScheme,.light).background(Color.white)
        let host = NSHostingView(rootView:view)
        host.frame = CGRect(x:0,y:0,width:600,height:650)
        host.sizingOptions = []
        let window = NSWindow(contentRect:host.frame,styleMask:[.borderless],backing:.buffered,defer:false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named:.aqua)
        window.contentView = host; window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        try await Task.sleep(for:.milliseconds(90))
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in:host.bounds))
        host.cacheDisplay(in:host.bounds,to:bitmap)
        try #require(bitmap.representation(using:.png,properties:[:])).write(to:FileManager.default.temporaryDirectory.appendingPathComponent("youzi-generation-detail.png"))
    }
}
