import Foundation

/// Credential-free snapshot of the endpoint actually selected for a generation.
struct YouziGenerationSource: Codable, Hashable, Sendable {
    enum Location: String, Codable, Sendable { case local, remote, unknown }
    var location: Location
    var modelAlias: String
    var modelName: String
    var modelID: String?
    var server: String?

    static func local(_ entry: ModelEntry, port: Int? = nil) -> Self {
        .init(location: .local, modelAlias: entry.alias, modelName: entry.alias,
              modelID: entry.hfRepo ?? entry.alias, server: port.map { "http://127.0.0.1:\($0)/v1" })
    }

    /// Accept a configured API base only; credentials and query strings never persist.
    static func safeServer(_ raw: String) -> String? {
        guard var url = URLComponents(string: raw), ["http", "https"].contains(url.scheme?.lowercased()),
              url.host != nil else { return nil }
        url.user = nil; url.password = nil; url.query = nil; url.fragment = nil
        return url.string?.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    func matches(_ current: Self) -> Bool {
        guard location == current.location, modelAlias == current.modelAlias else { return false }
        if location == .local { return modelID == nil || modelID == current.modelID }
        return location == .remote && server != nil && server == current.server && modelID == current.modelID
    }
}

struct YouziArtifactGeneration: Codable, Hashable, Sendable {
    enum Operation: String, Codable, Sendable {
        case image, speech, video
        var tool: String {
            switch self { case .image: "youzi_generate_image"; case .speech: "youzi_synthesize_speech"; case .video: "youzi_generate_video" }
        }
        init?(tool: String) {
            switch tool { case "youzi_generate_image": self = .image; case "youzi_synthesize_speech": self = .speech; case "youzi_generate_video": self = .video; default: return nil }
        }
        var keys: Set<String> {
            switch self { case .image: ["size", "seed", "steps", "guidance", "negative_prompt"]
            case .speech: ["voice", "speed"]
            case .video: ["size", "seconds", "seed", "reference_image_id"] }
        }
    }
    var version = 1
    var operation: Operation
    var source: YouziGenerationSource
    var prompt: String
    var requested: [String: CodableJSON] = [:]
    var submitted: [String: CodableJSON] = [:]
    var reported: [String: CodableJSON] = [:]
    var recoveredFromHistory = false
    var parentArtifactID: UUID? = nil

    var canReroll: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !source.modelAlias.isEmpty &&
        (source.location == .local || (source.location == .remote && source.server != nil && source.modelID != nil))
    }

    /// Retain supported effective values, changing only randomness. Unknown
    /// historical defaults remain unspecified, never fabricated.
    func rerollArguments(seed: Int = Int.random(in: 0...2147483647)) -> [String: CodableJSON] {
        var values = requested.merging(submitted) { _, new in new }
        for key in operation.keys where reported[key] != nil { values[key] = reported[key] }
        values = values.filter { operation.keys.contains($0.key) }
        values["model"] = .string(source.modelAlias)
        values[operation == .speech ? "text" : "prompt"] = .string(prompt)
        if operation != .speech {
            if source.location == .local { values["seed"] = .number(values["seed"] == .number(Double(seed)) ? Double((seed + 1) % 2147483648) : Double(seed)) }
            else { values.removeValue(forKey: "seed") }
        }
        // Remote image adapters do not support diffusion controls.
        if operation == .image && source.location == .remote {
            for key in ["seed", "steps", "guidance", "negative_prompt"] { values.removeValue(forKey: key) }
        }
        return values
    }

    static func values(_ input: [String: Any], keys: Set<String>) -> [String: CodableJSON] {
        guard let data = try? JSONSerialization.data(withJSONObject: input.filter { keys.contains($0.key) }) else { return [:] }
        return (try? JSONDecoder().decode([String: CodableJSON].self, from: data)) ?? [:]
    }

    static func recover(artifact: YouziArtifact, messages: [ChatMessage]) -> Self? {
        // Exact tool/result and artifact IDs, not filename/prompt resemblance.
        for result in messages where result.role == .tool && result.status != .failed {
            guard result.content.utf8.count <= 128_000, let id = result.toolCallID,
                  let receipt = try? JSONSerialization.jsonObject(with: Data(result.content.utf8)) as? [String: Any],
                  (receipt["artifact_id"] as? String).flatMap(UUID.init(uuidString:)) == artifact.id,
                  let call = messages.flatMap({ $0.toolCalls ?? [] }).first(where: { $0.id == id }),
                  let operation = Operation(tool: call.function.name),
                  let args = try? JSONSerialization.jsonObject(with: Data(call.function.arguments.utf8)) as? [String: Any],
                  let prompt = args[operation == .speech ? "text" : "prompt"] as? String else { continue }
            let receiptValues = receipt["generation"] as? [String: Any] ?? [:]
            let alias = receiptValues["model"] as? String ?? args["model"] as? String ?? ""
            let location: YouziGenerationSource.Location = alias.isEmpty ? .unknown : RemoteModelEndpoint.isRemote(alias) ? .remote : .local
            var record = Self(operation: operation, source: .init(location: location, modelAlias: alias,
                modelName: alias, modelID: nil, server: nil), prompt: prompt,
                requested: values(args, keys: operation.keys), recoveredFromHistory: true)
            if receiptValues["parameters_reported"] as? Bool == true {
                record.reported = values(receiptValues, keys: operation.keys.union(["elapsed_ms", "negative_prompt_applied"]))
            }
            if let size = receiptValues["effective_size"] as? String { record.submitted["size"] = .string(size) }
            return record
        }
        return nil
    }
}

extension CodableJSON {
    var generationDisplay: String {
        if case .string(let text) = self { return text }
        return (try? String(decoding: JSONEncoder().encode(self), as: UTF8.self)) ?? "—"
    }
}
