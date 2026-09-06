import Foundation
import Testing
@testable import Rapid

@Suite("Model generation defaults", .serialized)
struct ModelGenerationDefaultsTests {
    private func isolatedDefaults() -> (String, UserDefaults) {
        let name = "ModelGenerationDefaultsTests.\(UUID().uuidString)"
        return (name, UserDefaults(suiteName: name)!)
    }

    @Test("Fresh defaults preserve inexpensive generation and reject invalid stored values")
    func safeFallbacks() {
        let (name, defaults) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ModelGenerationDefaults(defaults: defaults)
        #expect(store.imageSize == "512x512")
        #expect(store.speed == 1)
        #expect(store.videoSeconds == 0)
        #expect(store.resolveVideoSize(available: []) == "")
        #expect(store.resolveVideoSeconds(available: []) == 0)
        defaults.set(9999, forKey: ModelGenerationDefaults.Key.imageResolution)
        defaults.set("unknown", forKey: ModelGenerationDefaults.Key.imageAspect)
        defaults.set(-1, forKey: ModelGenerationDefaults.Key.speed)
        #expect(store.imageSize == "512x512")
        #expect(store.speed == 1)
    }

    @Test("Every aspect and resolution remains aligned to the image engine grid")
    func supportedDimensions() {
        let (name, defaults) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ModelGenerationDefaults(defaults: defaults)
        for edge in ModelGenerationDefaults.imageResolutions {
            for aspect in ModelGenerationDefaults.imageAspects {
                defaults.set(edge, forKey: ModelGenerationDefaults.Key.imageResolution)
                defaults.set(aspect, forKey: ModelGenerationDefaults.Key.imageAspect)
                let dimensions = store.imageSize.split(separator: "x").compactMap { Int($0) }
                #expect(dimensions.count == 2)
                #expect(dimensions.max() == edge)
                #expect(dimensions.allSatisfy { $0.isMultiple(of: 16) && (256...2048).contains($0) })
            }
        }
    }

    @MainActor
    @Test("Defaults persist across instances and respect per-use overrides in open workspaces")
    func persistenceAndOverrides() {
        let (name, defaults) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = ModelGenerationSettings(defaults: defaults)
        let server = ServerManager(testingState: .idle)
        let image = ImageGenViewModel(server: server, generationSettings: settings)
        let audio = AudioViewModel(server: server, generationSettings: settings)
        audio.selectedSpeechAlias = "voice-a"
        audio.voices = ["Alice", "Bob"]
        settings.voices["voice-a"] = "Bob"
        settings.speed = 1.25
        settings.imageAspect = "portrait"
        settings.imageResolution = 1024
        #expect(image.outputSize == "768x1024")
        #expect(audio.selectedVoice == "Bob")
        #expect(audio.speed == 1.25)
        image.resolution = .compact
        audio.speed = 0.75
        audio.selectedVoice = "Alice"
        settings.speed = 1.5
        settings.imageResolution = 2048
        #expect(image.outputSize == "384x512")
        #expect(audio.speed == 0.75)
        #expect(audio.selectedVoice == "Alice")
        image.useGenerationDefaults()
        audio.useGenerationDefaults()
        #expect(image.outputSize == "1536x2048")
        #expect(audio.speed == 1.5)
        #expect(audio.selectedVoice == "Bob")
        let reloaded = ModelGenerationSettings(defaults: defaults)
        #expect(reloaded.imageResolution == 2048)
        #expect(reloaded.voices["voice-a"] == "Bob")
        #expect(reloaded.speed == 1.5)
    }

    @Test("Voices never leak between models and missing voices fall back safely")
    func voicesByModel() {
        let (name, defaults) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["a": "Alice", "b": "Bob"], forKey: ModelGenerationDefaults.Key.voices)
        let store = ModelGenerationDefaults(defaults: defaults)
        #expect(store.voice(for: "a", available: ["Bob", "Alice"]) == "Alice")
        #expect(store.voice(for: "b", available: ["Alice", "Bob"]) == "Bob")
        #expect(store.voice(for: "c", available: ["First", "Bob"]) == "First")
        #expect(store.voice(for: "a", available: ["Other"]) == "Other")
        #expect(store.voice(for: "a", available: []) == nil)
    }

    @Test("Video stored preferences are validated against the current model's capabilities")
    func videoFallbacks() {
        let (name, defaults) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("1024x576", forKey: ModelGenerationDefaults.Key.videoSize)
        defaults.set(4, forKey: ModelGenerationDefaults.Key.videoSeconds)
        let store = ModelGenerationDefaults(defaults: defaults)
        #expect(store.resolveVideoSize(available: ["512x512", "1024x576"]) == "1024x576")
        #expect(store.resolveVideoSeconds(available: [1, 2, 4]) == 4)
        #expect(store.resolveVideoSize(available: ["512x512"]) == "512x512")
        #expect(store.resolveVideoSeconds(available: [1, 2]) == 1)
    }

    @Test("Saved service port is pinned, environment overrides win, invalid values fail safe")
    func servicePort() {
        let (name, defaults) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(ModelServicePreference.candidatePorts(environment: [:], defaults: defaults) == Array(8000...8009))
        defaults.set(8123, forKey: ModelServicePreference.portKey)
        #expect(ModelServicePreference.candidatePorts(environment: [:], defaults: defaults) == [8123])
        #expect(ModelServicePreference.candidatePorts(environment: ["RAPID_DESKTOP_PORT": "8555"], defaults: defaults) == [8555])
        defaults.set(70000, forKey: ModelServicePreference.portKey)
        #expect(ModelServicePreference.port(in: defaults) == nil)
    }

    @MainActor
    @Test("Legacy deep links select Files, Chat or Video; explicit tabs are staged before opening")
    func routing() {
        let router = SettingsRouter()
        #expect(ModelSettingsTab.allCases == [.service, .files, .chat, .audio, .image, .video])
        router.route(to: .performance) { #expect(router.requestedModelTab == .chat) }
        router.route(.openModelManagement) { #expect(router.requestedModelTab == .files) }
        router.route(to: .experimentalFeatures) { #expect(router.requestedModelTab == .video) }
        router.route(toModelTab: .audio) {
            #expect(router.requestedModelTab == .audio)
            #expect(router.requestedCategory == .modelManagement)
        }
        router.route(to: .appearance) { #expect(router.requestedModelTab == nil) }
    }
}
