import Foundation

extension VideoClient {
    /// User-configured request presets, NOT a fabricated provider capability response.
    /// OpenAI videos has no /capabilities endpoint. The provider validates generation.
    static func configuredCapabilities(_ model: RemoteModelConfiguration) -> VideoCapabilities {
        let durations = model.durations.sorted()
        return VideoCapabilities(model: model.modelID, family: "configured_remote",
            modes: model.supportsVideoImageInput ? [.textToVideo, .imageToVideo] : [.textToVideo], limits: .init(
                size: .init(type: "fixed", values: model.sizes, width: nil, height: nil, maximumArea: nil, alsoSupported: nil),
                seconds: .init(minimum: durations.first ?? 4, maximum: durations.last ?? 4, default: durations.first ?? 4),
                fps: .init(minimum: 1, maximum: 1, default: 1, fixed: true),
                frames: .init(minimum: 1, maximum: 600, step: 1, offset: 0),
                workload: .init(metric: "pixel_frames", maximum: Int.max, dimensionRounding: "none"),
                inputReference: .init(maximumBytes: VideoClient.maxReferenceBytes, maximumPixels: 32_000_000, formats: ["png", "jpeg", "webp"], accepted: model.supportsVideoImageInput)),
            configuredRemoteDurations: durations)
    }
}
