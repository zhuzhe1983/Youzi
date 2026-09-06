import Foundation
import Observation

/// Shared request defaults. Explicit workspace/request values always win.
/// Read at request time by clients so changing Settings also affects callers
/// that do not own a workspace view model. No model is started by this store.
// UserDefaults synchronizes its own access; this wrapper holds an immutable
// reference and does not maintain a second mutable cache across executors.
struct ModelGenerationDefaults: @unchecked Sendable {
    enum Key {
        static let voices = "youzi.models.audio.voices.v1"
        static let speed = "youzi.models.audio.speed.v1"
        static let imageAspect = "youzi.models.image.aspect.v1"
        static let imageResolution = "youzi.models.image.resolution.v1"
        static let videoSize = "youzi.models.video.size.v1"
        static let videoSeconds = "youzi.models.video.seconds.v1"
    }

    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    static let imageResolutions = [512, 768, 1024, 1280, 1536, 2048]
    static let imageAspects = ["square", "portrait", "landscape"]

    var voices: [String: String] {
        defaults.dictionary(forKey: Key.voices) as? [String: String] ?? [:]
    }
    func voice(for model: String, available: [String]) -> String? {
        guard let first = available.first else { return nil }
        return voices[model].flatMap { available.contains($0) ? $0 : nil } ?? first
    }
    var speed: Double {
        let value = defaults.object(forKey: Key.speed) as? Double ?? 1
        return value.isFinite && (0.5...2).contains(value) ? value : 1
    }
    var imageAspect: String {
        let value = defaults.string(forKey: Key.imageAspect) ?? "square"
        return Self.imageAspects.contains(value) ? value : "square"
    }
    var imageResolution: Int {
        let value = defaults.integer(forKey: Key.imageResolution)
        return Self.imageResolutions.contains(value) ? value : 512
    }
    var imageSize: String {
        let edge = imageResolution
        switch imageAspect {
        case "portrait": return "\(edge * 3 / 4)x\(edge)"
        case "landscape": return "\(edge)x\(edge * 3 / 4)"
        default: return "\(edge)x\(edge)"
        }
    }
    var videoSize: String { defaults.string(forKey: Key.videoSize) ?? "" }
    var videoSeconds: Int { max(0, defaults.integer(forKey: Key.videoSeconds)) }

    func resolveVideoSize(available: [String]) -> String {
        available.contains(videoSize) ? videoSize : available.first ?? ""
    }
    func resolveVideoSeconds(available: [Int]) -> Int {
        available.contains(videoSeconds) ? videoSeconds : available.first ?? 0
    }
}

/// Observable facade for Settings and existing workspaces. Per-use overrides
/// live in the workspace, never in this persisted application-wide store.
@MainActor
@Observable
final class ModelGenerationSettings {
    static let shared = ModelGenerationSettings()
    let store: ModelGenerationDefaults
    var voices: [String: String] { didSet { store.defaults.set(voices, forKey: ModelGenerationDefaults.Key.voices) } }
    var speed: Double { didSet { store.defaults.set(speed, forKey: ModelGenerationDefaults.Key.speed) } }
    var imageAspect: String { didSet { store.defaults.set(imageAspect, forKey: ModelGenerationDefaults.Key.imageAspect) } }
    var imageResolution: Int { didSet { store.defaults.set(imageResolution, forKey: ModelGenerationDefaults.Key.imageResolution) } }
    var videoSize: String { didSet { store.defaults.set(videoSize, forKey: ModelGenerationDefaults.Key.videoSize) } }
    var videoSeconds: Int { didSet { store.defaults.set(videoSeconds, forKey: ModelGenerationDefaults.Key.videoSeconds) } }

    init(defaults: UserDefaults = .standard) {
        let store = ModelGenerationDefaults(defaults: defaults)
        self.store = store
        voices = store.voices
        speed = store.speed
        imageAspect = store.imageAspect
        imageResolution = store.imageResolution
        videoSize = store.videoSize
        videoSeconds = store.videoSeconds
    }

    func voice(for model: String, available: [String]) -> String {
        guard let first = available.first else { return "" }
        return voices[model].flatMap { available.contains($0) ? $0 : nil } ?? first
    }
}
