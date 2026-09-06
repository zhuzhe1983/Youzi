import Foundation

/// Zero keeps collision-safe automatic allocation; a configured port is pinned
/// rather than silently advertising one port and listening on another.
enum ModelServicePreference {
    static let anonymousInferenceKey = "youzi.models.service.anonymousInference.v1"
    static func allowsAnonymousInference(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: anonymousInferenceKey)
    }
    static let portKey = "youzi.models.service.port.v1"
    static func port(in defaults: UserDefaults = .standard) -> Int? {
        let value = defaults.integer(forKey: portKey)
        return (1024...65535).contains(value) ? value : nil
    }
    static func candidatePorts(
        environment: [String: String], defaults: UserDefaults = .standard
    ) -> [Int] {
        let resolved = PortAllocator.resolveCandidatePorts(environment: environment)
        if resolved != PortAllocator.defaultCandidatePorts { return resolved }
        return port(in: defaults).map { [$0] } ?? resolved
    }
}
