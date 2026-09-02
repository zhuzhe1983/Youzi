import Foundation

enum YouziFileAttachmentTarget: Equatable, Sendable {
    case task(UUID)
    case project(UUID)
}

enum YouziLifecycleError: Error, Equatable, Sendable {
    case taskNotFound(UUID)
    case workspaceNotFound(UUID)
    case projectNotFound(UUID)
    case fileNotFound(UUID)
    case artifactNotFound(UUID)
    case templateNotFound(UUID)
    case artifactFileCannotBeReattached(UUID)
    case projectMismatch(taskID: UUID, projectID: UUID)
}

extension YouziLifecycleError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .taskNotFound(id): return "Task \(id) was not found."
        case let .workspaceNotFound(id): return "Workspace \(id) was not found."
        case let .projectNotFound(id): return "Project \(id) was not found."
        case let .fileNotFound(id): return "File \(id) was not found."
        case let .artifactNotFound(id): return "Artifact \(id) was not found."
        case let .templateNotFound(id): return "Template \(id) was not found."
        case let .artifactFileCannotBeReattached(id):
            return "Artifact file \(id) cannot be moved to another owner."
        case let .projectMismatch(taskID, projectID):
            return "Task \(taskID) does not belong to project \(projectID)."
        }
    }
}

/// Transactional metadata lifecycle atop the atomic domain store. Filesystem
/// mutations happen first and are compensated when the metadata commit fails;
/// external/reference bytes are never deleted as compensation.
final class YouziLifecycleRepository: @unchecked Sendable {
    private let store: YouziDomainStore
    private let workspaceAccess: YouziWorkspaceAccessCoordinator
    private let fileStore: YouziManagedFileStore

    init(
        store: YouziDomainStore = YouziDomainStore(),
        workspaceAccess: YouziWorkspaceAccessCoordinator = YouziWorkspaceAccessCoordinator(),
        fileStore: YouziManagedFileStore? = nil
    ) {
        self.store = store
        self.workspaceAccess = workspaceAccess
        self.fileStore = fileStore ?? YouziManagedFileStore(workspaceAccess: workspaceAccess)
    }

    func load() throws -> YouziDomainDocument { try store.load() }

    @discardableResult
    func createProject(
        name: String,
        summary: String = "",
        instructions: String = "",
        at date: Date = Date()
    ) throws -> (YouziProject, YouziDomainDocument) {
        let project = YouziProject(
            name: name,
            summary: summary,
            instructions: instructions,
            createdAt: date,
            updatedAt: date
        )
        let document = try store.update { $0.upsert(project) }
        return (project, document)
    }

    @discardableResult
    func createManagedWorkspace(
        name: String,
        id: UUID = UUID(),
        at date: Date = Date()
    ) throws -> (YouziWorkspace, YouziDomainDocument) {
        let workspace = try workspaceAccess.createManagedWorkspace(id: id, name: name, at: date)
        do {
            let document = try store.update { $0.upsert(workspace) }
            return (workspace, document)
        } catch {
            try? workspaceAccess.removeManagedWorkspace(workspace)
            throw error
        }
    }

    @discardableResult
    func createBookmarkedWorkspace(
        name: String,
        directoryURL: URL,
        id: UUID = UUID(),
        at date: Date = Date()
    ) throws -> (YouziWorkspace, YouziDomainDocument) {
        let workspace = try workspaceAccess.createBookmarkedWorkspace(
            id: id,
            name: name,
            directoryURL: directoryURL,
            at: date
        )
        let document = try store.update { $0.upsert(workspace) }
        return (workspace, document)
    }

    @discardableResult
    func assignWorkspace(_ workspaceID: UUID?, toTask taskID: UUID, at date: Date = Date()) throws
        -> YouziDomainDocument
    {
        try store.update { document in
            guard let taskIndex = document.tasks.firstIndex(where: { $0.id == taskID }) else {
                throw YouziLifecycleError.taskNotFound(taskID)
            }
            if let workspaceID,
               !document.workspaces.contains(where: { $0.id == workspaceID }) {
                throw YouziLifecycleError.workspaceNotFound(workspaceID)
            }
            document.tasks[taskIndex].workspaceID = workspaceID
            document.tasks[taskIndex].updatedAt = date
        }
    }

    /// Called at the first execution boundary, not when an editable draft is
    /// merely created. Existing and explicitly selected workspaces always win.
    @discardableResult
    func ensureManagedWorkspace(forTask taskID: UUID, at date: Date = Date()) throws
        -> (YouziWorkspace, YouziDomainDocument)
    {
        let current = try store.load()
        guard let task = current.tasks.first(where: { $0.id == taskID }) else {
            throw YouziLifecycleError.taskNotFound(taskID)
        }
        if let workspaceID = task.workspaceID {
            guard let existing = current.workspaces.first(where: { $0.id == workspaceID }) else {
                throw YouziLifecycleError.workspaceNotFound(workspaceID)
            }
            return (existing, current)
        }

        let workspace = try workspaceAccess.createManagedWorkspace(
            id: UUID(),
            name: task.title,
            at: date
        )
        let document: YouziDomainDocument
        do {
            document = try store.update { document in
                guard let index = document.tasks.firstIndex(where: { $0.id == taskID }) else {
                    throw YouziLifecycleError.taskNotFound(taskID)
                }
                // Re-check inside the transaction so a concurrently selected real
                // workspace is never overwritten by the managed fallback.
                if document.tasks[index].workspaceID == nil {
                    document.upsert(workspace)
                    document.tasks[index].workspaceID = workspace.id
                    document.tasks[index].updatedAt = date
                }
            }
        } catch {
            try? workspaceAccess.removeManagedWorkspace(workspace)
            throw error
        }
        if let selectedID = document.tasks.first(where: { $0.id == taskID })?.workspaceID,
           let selected = document.workspaces.first(where: { $0.id == selectedID }) {
            if selected.id != workspace.id {
                try? workspaceAccess.removeManagedWorkspace(workspace)
            }
            return (selected, document)
        }
        throw YouziLifecycleError.taskNotFound(taskID)
    }

    @discardableResult
    func moveTask(_ taskID: UUID, toProject projectID: UUID?, at date: Date = Date()) throws
        -> YouziDomainDocument
    {
        try store.update { document in
            guard let index = document.tasks.firstIndex(where: { $0.id == taskID }) else {
                throw YouziLifecycleError.taskNotFound(taskID)
            }
            if let projectID, !document.projects.contains(where: { $0.id == projectID }) {
                throw YouziLifecycleError.projectNotFound(projectID)
            }
            document.tasks[index].projectID = projectID
            document.tasks[index].updatedAt = date
        }
    }

    /// Execution boundary for a Simple draft: attach the canonical chat and
    /// allocate the managed fallback only now, never while browsing templates
    /// or editing the request.
    @discardableResult
    func beginExecution(
        taskID: UUID,
        conversationID: UUID,
        at date: Date = Date()
    ) throws -> (YouziWorkspace, YouziDomainDocument) {
        let (workspace, _) = try ensureManagedWorkspace(forTask: taskID, at: date)
        let document = try store.update { document in
            guard let index = document.tasks.firstIndex(where: { $0.id == taskID }) else {
                throw YouziLifecycleError.taskNotFound(taskID)
            }
            document.tasks[index].conversationID = conversationID
            document.tasks[index].status = .inProgress
            document.tasks[index].updatedAt = date
        }
        return (workspace, document)
    }

    @discardableResult
    func importFile(
        at sourceURL: URL,
        mode: YouziFileImportMode,
        attachingTo target: YouziFileAttachmentTarget,
        at date: Date = Date()
    ) throws -> (YouziFile, YouziDomainDocument) {
        let role: YouziFileRole
        let taskID: UUID?
        let projectID: UUID?
        switch target {
        case let .task(id):
            role = .taskInput
            taskID = id
            projectID = nil
        case let .project(id):
            role = .projectResource
            taskID = nil
            projectID = id
        }
        let file = try fileStore.importFile(
            at: sourceURL,
            mode: mode,
            role: role,
            originTaskID: taskID,
            projectID: projectID,
            at: date
        )
        do {
            let document = try store.update { document in
                try Self.attach(file, to: target, in: &document, at: date)
            }
            return (file, document)
        } catch {
            if mode == .copy { try? fileStore.removeManagedCopy(for: file) }
            throw error
        }
    }

    @discardableResult
    func attachFile(_ fileID: UUID, to target: YouziFileAttachmentTarget, at date: Date = Date())
        throws -> YouziDomainDocument
    {
        try store.update { document in
            guard var file = document.files.first(where: { $0.id == fileID }) else {
                throw YouziLifecycleError.fileNotFound(fileID)
            }
            guard !document.artifacts.contains(where: { $0.fileID == fileID }) else {
                throw YouziLifecycleError.artifactFileCannotBeReattached(fileID)
            }
            switch target {
            case let .task(taskID):
                file.role = .taskInput
                file.originTaskID = taskID
                file.projectID = nil
            case let .project(projectID):
                file.role = .projectResource
                file.originTaskID = nil
                file.projectID = projectID
            }
            file.updatedAt = date
            try Self.attach(file, to: target, in: &document, at: date)
        }
    }

    /// Adds an existing project resource to a task's input set without moving
    /// ownership away from the project.
    @discardableResult
    func referenceProjectFile(_ fileID: UUID, toTask taskID: UUID, at date: Date = Date()) throws
        -> YouziDomainDocument
    {
        try store.update { document in
            guard let file = document.files.first(where: { $0.id == fileID }) else {
                throw YouziLifecycleError.fileNotFound(fileID)
            }
            guard file.role == .projectResource, let projectID = file.projectID else {
                throw YouziLifecycleError.fileNotFound(fileID)
            }
            guard let index = document.tasks.firstIndex(where: { $0.id == taskID }) else {
                throw YouziLifecycleError.taskNotFound(taskID)
            }
            guard document.tasks[index].projectID == projectID else {
                throw YouziLifecycleError.projectMismatch(taskID: taskID, projectID: projectID)
            }
            if !document.tasks[index].inputFileIDs.contains(fileID) {
                document.tasks[index].inputFileIDs.append(fileID)
            }
            document.tasks[index].updatedAt = date
        }
    }

    @discardableResult
    func createArtifact(
        data: Data,
        named name: String,
        contentTypeIdentifier: String? = nil,
        kind: YouziArtifactKind,
        taskID: UUID,
        projectID: UUID? = nil,
        previewText: String? = nil,
        at date: Date = Date()
    ) throws -> (YouziArtifact, YouziDomainDocument) {
        let file = try fileStore.write(
            data,
            named: name,
            contentTypeIdentifier: contentTypeIdentifier,
            role: .artifact,
            originTaskID: taskID,
            projectID: projectID,
            at: date
        )
        let artifact = YouziArtifact(
            taskID: taskID,
            projectID: projectID,
            title: name,
            kind: kind,
            previewText: previewText,
            fileID: file.id,
            createdAt: date,
            updatedAt: date
        )
        do {
            let document = try store.update { document in
                guard let taskIndex = document.tasks.firstIndex(where: { $0.id == taskID }) else {
                    throw YouziLifecycleError.taskNotFound(taskID)
                }
                if let projectID,
                   document.tasks[taskIndex].projectID != projectID {
                    throw YouziLifecycleError.projectMismatch(taskID: taskID, projectID: projectID)
                }
                document.upsert(file)
                document.upsert(artifact)
                if !document.tasks[taskIndex].artifactIDs.contains(artifact.id) {
                    document.tasks[taskIndex].artifactIDs.append(artifact.id)
                }
                document.tasks[taskIndex].updatedAt = date
            }
            return (artifact, document)
        } catch {
            try? fileStore.removeManagedCopy(for: file)
            throw error
        }
    }

    func withAccess<Result>(
        toFile fileID: UUID,
        _ operation: (URL) throws -> Result
    ) throws -> Result {
        let document = try store.load()
        guard let file = document.files.first(where: { $0.id == fileID }) else {
            throw YouziLifecycleError.fileNotFound(fileID)
        }
        if case let .workspace(workspaceID, relativePath) = file.location {
            guard var workspace = document.workspaces.first(where: { $0.id == workspaceID }) else {
                throw YouziLifecycleError.workspaceNotFound(workspaceID)
            }
            var refreshedWorkspaceLocation: YouziWorkspaceLocation?
            let result = try workspaceAccess.withAccess(
                to: workspace,
                relativePath: relativePath
            ) { url, refreshed in
                refreshedWorkspaceLocation = refreshed
                return try operation(url)
            }
            if let refreshedWorkspaceLocation {
                workspace.location = refreshedWorkspaceLocation
                workspace.updatedAt = Date()
                workspace.lastAccessedAt = Date()
                _ = try store.update { $0.upsert(workspace) }
            }
            return result
        }
        let workspaceMap = Dictionary(uniqueKeysWithValues: document.workspaces.map { ($0.id, $0) })
        var refreshedLocation: YouziFileLocation?
        let result = try fileStore.withAccess(to: file, workspaces: workspaceMap) { url, refreshed in
            refreshedLocation = refreshed
            return try operation(url)
        }
        if let refreshedLocation {
            _ = try store.update { document in
                guard let index = document.files.firstIndex(where: { $0.id == fileID }) else {
                    throw YouziLifecycleError.fileNotFound(fileID)
                }
                document.files[index].location = refreshedLocation
                document.files[index].updatedAt = Date()
                document.files[index].lastVerifiedAt = Date()
            }
        }
        return result
    }

    func exportFile(_ fileID: UUID, to destinationURL: URL) throws {
        try withAccess(toFile: fileID) { sourceURL in
            try fileStore.exportResolvedFile(at: sourceURL, to: destinationURL)
        }
    }

    /// Removes metadata only by default. Managed bytes require a second,
    /// explicit opt-in and external/reference bytes are never removed.
    @discardableResult
    func removeFile(_ fileID: UUID, deleteManagedCopy: Bool = false) throws
        -> YouziDomainDocument
    {
        let current = try store.load()
        guard let file = current.files.first(where: { $0.id == fileID }) else {
            throw YouziLifecycleError.fileNotFound(fileID)
        }
        if deleteManagedCopy, case .appManaged = file.location {
            // Eligible. External locations are rejected before metadata moves.
        } else if deleteManagedCopy {
            throw YouziManagedFileStoreError.refusesToDeleteExternalFile
        }

        let tombstoned = try store.update { document in
            let ownsArtifact = document.artifacts.contains { $0.fileID == fileID }
            if (ownsArtifact || deleteManagedCopy),
               let index = document.files.firstIndex(where: { $0.id == fileID }) {
                document.files[index].availability = .revoked
                document.files[index].updatedAt = Date()
            } else {
                document.files.removeAll { $0.id == fileID }
            }
            for index in document.tasks.indices {
                document.tasks[index].inputFileIDs.removeAll { $0 == fileID }
            }
            for index in document.projects.indices {
                document.projects[index].resourceFileIDs.removeAll { $0 == fileID }
            }
            // Artifacts are durable outcome metadata; losing their source marks
            // them unavailable instead of silently deleting the result row.
            for index in document.artifacts.indices
            where document.artifacts[index].fileID == fileID {
                document.artifacts[index].state = .unavailable
            }
        }
        guard deleteManagedCopy else { return tombstoned }

        // Metadata now says the source is revoked, so a failed cleanup is a
        // retryable leak rather than silent loss of an "available" record.
        try fileStore.removeManagedCopy(for: file)
        return try store.update { document in
            let ownsArtifact = document.artifacts.contains { $0.fileID == fileID }
            if ownsArtifact, let index = document.files.firstIndex(where: { $0.id == fileID }) {
                document.files[index].availability = .missing
                document.files[index].updatedAt = Date()
            } else {
                document.files.removeAll { $0.id == fileID }
            }
        }
    }

    @discardableResult
    func seedTemplates(_ templates: [YouziTemplate]) throws -> YouziDomainDocument {
        try store.update { document in
            for template in templates { document.upsert(template) }
        }
    }

    @discardableResult
    func instantiateTemplate(_ templateID: UUID, at date: Date = Date()) throws
        -> (YouziTask, YouziDomainDocument)
    {
        let current = try store.load()
        guard let template = current.templates.first(where: { $0.id == templateID }) else {
            throw YouziLifecycleError.templateNotFound(templateID)
        }
        let task = YouziTask(
            title: template.name,
            request: template.prefilledRequest,
            helperID: template.recommendedHelperID,
            skillIDs: template.recommendedSkillIDs,
            status: .draft,
            createdAt: date,
            updatedAt: date
        )
        let document = try store.update { $0.upsert(task) }
        return (task, document)
    }

    private static func attach(
        _ file: YouziFile,
        to target: YouziFileAttachmentTarget,
        in document: inout YouziDomainDocument,
        at date: Date
    ) throws {
        // `attachFile` is a move, not a second owner. New imports also pass
        // through here, so stale duplicate backlinks are repaired uniformly.
        for index in document.tasks.indices {
            if document.tasks[index].inputFileIDs.contains(file.id) {
                document.tasks[index].inputFileIDs.removeAll { $0 == file.id }
                document.tasks[index].updatedAt = date
            }
        }
        for index in document.projects.indices {
            if document.projects[index].resourceFileIDs.contains(file.id) {
                document.projects[index].resourceFileIDs.removeAll { $0 == file.id }
                document.projects[index].updatedAt = date
            }
        }
        switch target {
        case let .task(taskID):
            guard let index = document.tasks.firstIndex(where: { $0.id == taskID }) else {
                throw YouziLifecycleError.taskNotFound(taskID)
            }
            document.upsert(file)
            if !document.tasks[index].inputFileIDs.contains(file.id) {
                document.tasks[index].inputFileIDs.append(file.id)
            }
            document.tasks[index].updatedAt = date
        case let .project(projectID):
            guard let index = document.projects.firstIndex(where: { $0.id == projectID }) else {
                throw YouziLifecycleError.projectNotFound(projectID)
            }
            document.upsert(file)
            if !document.projects[index].resourceFileIDs.contains(file.id) {
                document.projects[index].resourceFileIDs.append(file.id)
            }
            document.projects[index].updatedAt = date
        }
    }
}
