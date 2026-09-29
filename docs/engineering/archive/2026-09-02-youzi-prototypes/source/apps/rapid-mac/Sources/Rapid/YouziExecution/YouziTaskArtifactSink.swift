import CryptoKit
import Foundation

struct YouziTaskArtifactPersistenceRequest: Equatable, Sendable {
    let taskID: UUID
    let conversationID: UUID
    let workspaceID: UUID
    let projectID: UUID?
    let artifacts: [AssistantTurnArtifact]
}

protocol YouziTaskArtifactPersisting: AnyObject, Sendable {
    /// Persists explicit deliverables only. Implementations must not add or
    /// reconstruct conversation messages.
    func persist(_ request: YouziTaskArtifactPersistenceRequest) throws -> [YouziArtifact]
}

enum YouziTaskArtifactPersistenceError: Error, Equatable, Sendable {
    case taskNotFound(UUID)
    case ownershipMismatch(taskID: UUID)
    case invalidArtifact(stableKey: String)
    case duplicateStableKey(String)
    case unsupportedFileLocation(String)
    case sourceChanged(String)
    case identityConflict(UUID)
}

extension YouziTaskArtifactPersistenceError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .taskNotFound(let id):
            return "Task \(id) was not found while saving its results."
        case .ownershipMismatch(let id):
            return "Task \(id) no longer has the expected conversation, workspace, or project."
        case .invalidArtifact(let key):
            return "The produced artifact metadata is invalid (\(key))."
        case .duplicateStableKey(let key):
            return "Two different produced artifacts used the same stable key (\(key))."
        case .unsupportedFileLocation(let location):
            return "The produced artifact is not an absolute local file (\(location))."
        case .sourceChanged(let location):
            return "The produced artifact changed while it was being saved (\(location))."
        case .identityConflict(let id):
            return "A different artifact already owns the deterministic identity \(id)."
        }
    }
}

/// Production adapter from canonical assistant outcomes to the durable Youzi
/// task/file/artifact graph. Deterministic IDs make retries idempotent while
/// exact ownership and digest checks prevent a stable key from overwriting a
/// different result.
final class YouziTaskArtifactSink: YouziTaskArtifactPersisting, @unchecked Sendable {
    private enum Payload {
        case localFile(URL, expectedSHA256: String)
        case metadata(Data, expectedSHA256: String, displayName: String)

        var expectedSHA256: String {
            switch self {
            case .localFile(_, let digest), .metadata(_, let digest, _): digest
            }
        }
    }

    private struct Plan {
        let candidate: AssistantTurnArtifact
        let artifactID: UUID
        let fileID: UUID
        let kind: YouziArtifactKind
        let payload: Payload
        var stagedFile: YouziFile?
        var artifact: YouziArtifact?
    }

    private struct MetadataDocument: Encodable {
        let formatIdentifier = "com.rapidmlx.youzi.task-artifact-metadata"
        let version = 1
        let stableKey: String
        let title: String
        let location: String
        let contentTypeIdentifier: String?
        let previewText: String?
        let inlineContent: String?
    }

    private let store: YouziDomainStore
    private let fileStore: YouziManagedFileStore
    private let now: @Sendable () -> Date
    private let lock = NSLock()

    init(
        store: YouziDomainStore,
        fileStore: YouziManagedFileStore? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.fileStore = fileStore ?? YouziManagedFileStore()
        self.now = now
    }

    func persist(_ request: YouziTaskArtifactPersistenceRequest) throws -> [YouziArtifact] {
        lock.lock()
        defer { lock.unlock() }

        let candidates = try normalizedDeliverables(request.artifacts)
        // Grounding-only outcomes are not task deliverables. Keeping this a
        // true no-op avoids touching the domain store for ordinary web search.
        guard !candidates.isEmpty else { return [] }

        var document = try store.load()
        try validateOwnership(request, in: document)
        let date = now()
        var plans = try candidates.map {
            try makePlan($0, request: request, document: document)
        }
        var stagedFiles: [YouziFile] = []
        var committed = false
        defer {
            if !committed {
                let current = try? store.load()
                for file in stagedFiles
                where current?.files.contains(where: { $0.id == file.id }) != true {
                    try? fileStore.removeManagedCopy(for: file)
                }
            }
        }

        for index in plans.indices where plans[index].artifact == nil {
            let file = try stageFile(for: plans[index], request: request, at: date)
            guard file.sha256 == plans[index].payload.expectedSHA256 else {
                try? fileStore.removeManagedCopy(for: file)
                throw YouziTaskArtifactPersistenceError.sourceChanged(
                    plans[index].candidate.location
                )
            }
            let artifact = YouziArtifact(
                id: plans[index].artifactID,
                taskID: request.taskID,
                projectID: request.projectID,
                title: plans[index].candidate.title,
                kind: plans[index].kind,
                previewText: plans[index].candidate.previewText.map {
                    String($0.prefix(1_200))
                },
                fileID: file.id,
                createdAt: date,
                updatedAt: date
            )
            plans[index].stagedFile = file
            plans[index].artifact = artifact
            stagedFiles.append(file)
        }

        document = try store.update { current in
            try self.validateOwnership(request, in: current)
            guard let taskIndex = current.tasks.firstIndex(where: { $0.id == request.taskID })
            else { throw YouziTaskArtifactPersistenceError.taskNotFound(request.taskID) }

            for plan in plans {
                guard let proposedArtifact = plan.artifact else {
                    throw YouziTaskArtifactPersistenceError.identityConflict(plan.artifactID)
                }
                if let existing = current.artifacts.first(where: { $0.id == plan.artifactID }),
                   let existingFile = current.files.first(where: { $0.id == plan.fileID }) {
                    guard self.matches(
                        artifact: existing,
                        file: existingFile,
                        plan: plan,
                        request: request
                    ) else {
                        throw YouziTaskArtifactPersistenceError.identityConflict(plan.artifactID)
                    }
                } else {
                    guard current.artifacts.contains(where: { $0.id == plan.artifactID }) == false,
                          current.files.contains(where: { $0.id == plan.fileID }) == false,
                          let file = plan.stagedFile
                    else {
                        throw YouziTaskArtifactPersistenceError.identityConflict(plan.artifactID)
                    }
                    current.upsert(file)
                    current.upsert(proposedArtifact)
                }
                if !current.tasks[taskIndex].artifactIDs.contains(plan.artifactID) {
                    current.tasks[taskIndex].artifactIDs.append(plan.artifactID)
                }
            }
            current.tasks[taskIndex].updatedAt = date
        }
        committed = true
        return plans.compactMap { plan in
            document.artifacts.first(where: { $0.id == plan.artifactID })
        }
    }

    private func normalizedDeliverables(
        _ artifacts: [AssistantTurnArtifact]
    ) throws -> [AssistantTurnArtifact] {
        let deliverables = artifacts.filter { $0.kind != .source }
        guard deliverables.count <= 64 else {
            throw YouziTaskArtifactPersistenceError.invalidArtifact(stableKey: "too-many")
        }
        var byKey: [String: AssistantTurnArtifact] = [:]
        var result: [AssistantTurnArtifact] = []
        for artifact in deliverables {
            let key = artifact.stableKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = artifact.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let location = artifact.location.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, key.utf8.count <= 512,
                  !title.isEmpty, title.count <= 256,
                  !location.isEmpty, location.utf8.count <= 4_096,
                  artifact.inlineContent?.utf8.count ?? 0 <= 2_097_152
            else {
                throw YouziTaskArtifactPersistenceError.invalidArtifact(stableKey: key)
            }
            let normalized = AssistantTurnArtifact(
                kind: artifact.kind,
                stableKey: key,
                title: title,
                location: location,
                contentTypeIdentifier: artifact.contentTypeIdentifier,
                previewText: artifact.previewText,
                inlineContent: artifact.inlineContent
            )
            if let existing = byKey[key] {
                guard existing == normalized else {
                    throw YouziTaskArtifactPersistenceError.duplicateStableKey(key)
                }
                continue
            }
            byKey[key] = normalized
            result.append(normalized)
        }
        return result
    }

    private func validateOwnership(
        _ request: YouziTaskArtifactPersistenceRequest,
        in document: YouziDomainDocument
    ) throws {
        guard let task = document.tasks.first(where: { $0.id == request.taskID }) else {
            throw YouziTaskArtifactPersistenceError.taskNotFound(request.taskID)
        }
        let projectExists: Bool
        if let projectID = request.projectID {
            projectExists = document.projects.contains(where: { $0.id == projectID })
        } else {
            projectExists = true
        }
        guard task.conversationID == request.conversationID,
              task.workspaceID == request.workspaceID,
              task.projectID == request.projectID,
              document.workspaces.contains(where: { $0.id == request.workspaceID }),
              projectExists
        else {
            throw YouziTaskArtifactPersistenceError.ownershipMismatch(taskID: request.taskID)
        }
    }

    private func makePlan(
        _ candidate: AssistantTurnArtifact,
        request: YouziTaskArtifactPersistenceRequest,
        document: YouziDomainDocument
    ) throws -> Plan {
        let identity = "\(request.taskID.uuidString.lowercased())|"
            + "\(request.conversationID.uuidString.lowercased())|\(candidate.stableKey)"
        let artifactID = Self.deterministicUUID("artifact|\(identity)")
        let fileID = Self.deterministicUUID("file|\(identity)")
        let payload: Payload
        switch candidate.kind {
        case .source:
            throw YouziTaskArtifactPersistenceError.invalidArtifact(
                stableKey: candidate.stableKey
            )
        case .file:
            let URL = try localFileURL(candidate.location)
            payload = .localFile(URL, expectedSHA256: try sha256(of: URL))
        case .metadata:
            let metadata = MetadataDocument(
                stableKey: candidate.stableKey,
                title: candidate.title,
                location: candidate.location,
                contentTypeIdentifier: candidate.contentTypeIdentifier,
                previewText: candidate.previewText.map { String($0.prefix(1_200)) },
                inlineContent: candidate.inlineContent
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(metadata)
            payload = .metadata(
                data,
                expectedSHA256: Self.sha256(data),
                displayName: Self.metadataFileName(candidate.title)
            )
        }
        var plan = Plan(
            candidate: candidate,
            artifactID: artifactID,
            fileID: fileID,
            kind: Self.artifactKind(for: candidate),
            payload: payload,
            stagedFile: nil,
            artifact: nil
        )
        let existingArtifact = document.artifacts.first(where: { $0.id == artifactID })
        let existingFile = document.files.first(where: { $0.id == fileID })
        if let existingArtifact, let existingFile {
            guard matches(
                artifact: existingArtifact,
                file: existingFile,
                plan: plan,
                request: request
            ) else {
                throw YouziTaskArtifactPersistenceError.identityConflict(artifactID)
            }
            plan.artifact = existingArtifact
        } else if existingArtifact != nil || existingFile != nil {
            throw YouziTaskArtifactPersistenceError.identityConflict(artifactID)
        }
        return plan
    }

    private func stageFile(
        for plan: Plan,
        request: YouziTaskArtifactPersistenceRequest,
        at date: Date
    ) throws -> YouziFile {
        switch plan.payload {
        case .localFile(let URL, _):
            var file = try fileStore.importFile(
                at: URL,
                mode: .copy,
                role: .artifact,
                originTaskID: request.taskID,
                projectID: request.projectID,
                id: plan.fileID,
                at: date
            )
            if let contentType = plan.candidate.contentTypeIdentifier {
                file.contentTypeIdentifier = contentType
            }
            return file
        case .metadata(let data, _, let displayName):
            return try fileStore.write(
                data,
                named: displayName,
                contentTypeIdentifier: "public.json",
                role: .artifact,
                originTaskID: request.taskID,
                projectID: request.projectID,
                id: plan.fileID,
                at: date
            )
        }
    }

    private func matches(
        artifact: YouziArtifact,
        file: YouziFile,
        plan: Plan,
        request: YouziTaskArtifactPersistenceRequest
    ) -> Bool {
        artifact.taskID == request.taskID
            && artifact.projectID == request.projectID
            && artifact.title == plan.candidate.title
            && artifact.kind == plan.kind
            && artifact.fileID == plan.fileID
            && artifact.state == .active
            && file.role == .artifact
            && file.originTaskID == request.taskID
            && file.projectID == request.projectID
            && file.sha256 == plan.payload.expectedSHA256
            && file.availability == .available
    }

    private func localFileURL(_ location: String) throws -> URL {
        if let URL = URL(string: location), URL.isFileURL, URL.path.hasPrefix("/") {
            return URL.standardizedFileURL
        }
        if location.hasPrefix("/") {
            return URL(fileURLWithPath: location).standardizedFileURL
        }
        throw YouziTaskArtifactPersistenceError.unsupportedFileLocation(location)
    }

    private func sha256(of URL: URL) throws -> String {
        let didStart = URL.startAccessingSecurityScopedResource()
        defer { if didStart { URL.stopAccessingSecurityScopedResource() } }
        let values = try URL.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else {
            throw YouziTaskArtifactPersistenceError.unsupportedFileLocation(URL.path)
        }
        let handle = try FileHandle(forReadingFrom: URL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func deterministicUUID(_ identity: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(identity.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func metadataFileName(_ title: String) -> String {
        let safe = YouziManagedFileStore.safeName(title)
        return safe.lowercased().hasSuffix(".json") ? safe : "\(safe).json"
    }

    private static func artifactKind(
        for candidate: AssistantTurnArtifact
    ) -> YouziArtifactKind {
        let contentType = candidate.contentTypeIdentifier?.lowercased() ?? ""
        let extensionName = URL(string: candidate.location)?.pathExtension.lowercased()
            ?? URL(fileURLWithPath: candidate.location).pathExtension.lowercased()
        if contentType.contains("image") || ["png", "jpg", "jpeg", "gif", "webp", "svg"].contains(extensionName) {
            return .image
        }
        if contentType.contains("audio") || ["wav", "mp3", "m4a", "flac", "aac"].contains(extensionName) {
            return .audio
        }
        if contentType.contains("video") || ["mp4", "mov", "mkv", "webm"].contains(extensionName) {
            return .video
        }
        if contentType.contains("spreadsheet") || contentType.contains("csv")
            || ["csv", "xls", "xlsx", "numbers"].contains(extensionName) {
            return .spreadsheet
        }
        if ["swift", "py", "js", "ts", "tsx", "jsx", "html", "css", "json", "yaml", "yml", "sh"].contains(extensionName) {
            return .code
        }
        if ["zip", "tar", "gz", "7z", "rar"].contains(extensionName) {
            return .archive
        }
        if contentType.contains("text") || contentType.contains("pdf")
            || ["md", "txt", "pdf", "doc", "docx", "rtf"].contains(extensionName) {
            return .document
        }
        return candidate.kind == .metadata ? .document : .other
    }
}
