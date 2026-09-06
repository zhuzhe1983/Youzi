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
        // Do not infer an env override by comparing candidate arrays: the
        // upstream allocator now appends a legacy fallback window, making
        // that comparison always unequal and silently ignoring Youzi Save.
        if let raw = environment["RAPID_DESKTOP_PORT"],
           let value = Int(raw.trimmingCharacters(in: .whitespaces)),
           (1...65535).contains(value) { return [value] }
        if let configured = port(in: defaults) { return [configured] }
        // Honor an explicit older Desktop setting, but retain Youzi's
        // existing 8000 default so this update does not break local clients.
        if let raw = defaults.string(forKey: PortAllocator.storedPortKey),
           let value = Int(raw.trimmingCharacters(in: .whitespaces)),
           (1...65535).contains(value) { return [value] }
        return PortAllocator.legacyFallbackPorts
    }
}
