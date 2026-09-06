import AppKit
import Observation

/// A copy is recorded only after the selected macOS service reports success.
/// Stages file bytes through the scoped domain export API, not a bookmark URL
/// whose access would have ended before an asynchronous sharing service reads it.
@MainActor
@Observable
final class YouziSharingCenter: NSObject, @preconcurrency NSSharingServicePickerDelegate, NSSharingServiceDelegate {
    let history: YouziShareHistory
    private(set) var isSharing = false
    var errorMessage: String?
    private var picker: NSSharingServicePicker?
    private var pending: (kind: YouziShareRecord.Kind, id: UUID, title: String)?
    private var stagingDirectory: URL?

    init(history: YouziShareHistory = YouziShareHistory()) {
        self.history = history
        super.init()
    }

    func shareTask(_ task: YouziTask, chat: ChatViewModel) {
        guard !isSharing else { return }
        let conversation = chat.conversations.first { $0.id == task.conversationID }
        let transcript = conversation?.messages.filter {
            $0.role == .user || $0.role == .assistant
        }.map { "## \($0.role == .user ? "User" : "Assistant")\n\n\($0.content)" }.joined(separator: "\n\n")
        // Deliberately excludes system instructions, tool messages and attachments.
        let text = "# \(task.title)\n\n\(transcript ?? task.request)"
        present(items: [text], kind: .task, id: task.id, title: task.title)
    }

    func shareFile(_ file: YouziFile, product: YouziProductModel) {
        guard !isSharing else { return }
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("youzi-share-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            stagingDirectory = directory
            let name = (file.displayName as NSString).lastPathComponent
            let safeName = name.isEmpty || name == "." || name == ".." ? "Shared file" : name
            let copy = directory.appendingPathComponent(safeName)
            try product.exportFile(id: file.id, to: copy)
            present(items: [copy], kind: .file, id: file.id, title: file.displayName)
        } catch {
            errorMessage = error.localizedDescription
            finish()
        }
    }

    private func present(items: [Any], kind: YouziShareRecord.Kind, id: UUID, title: String) {
        guard let view = NSApp.keyWindow?.contentView else { finish(); return }
        errorMessage = nil
        pending = (kind, id, title)
        isSharing = true
        let picker = NSSharingServicePicker(items: items)
        self.picker = picker
        picker.delegate = self
        picker.show(relativeTo: NSRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1),
                    of: view, preferredEdge: .minY)
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker,
                              delegateFor sharingService: NSSharingService) -> (any NSSharingServiceDelegate)? { self }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker,
                              didChoose service: NSSharingService?) {
        if service == nil { finish() }
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        if let pending {
            if !history.record(YouziShareRecord(kind: pending.kind, sourceID: pending.id,
                                               title: pending.title, service: sharingService.title)) {
                errorMessage = history.lastError
            }
        }
        finish()
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: any Error) {
        errorMessage = error.localizedDescription
        finish()
    }

    private func finish() {
        if let stagingDirectory { try? FileManager.default.removeItem(at: stagingDirectory) }
        stagingDirectory = nil
        pending = nil
        picker = nil
        isSharing = false
    }
}
