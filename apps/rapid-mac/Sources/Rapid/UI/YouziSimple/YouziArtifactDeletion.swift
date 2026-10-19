import SwiftUI

/// Shared by result menus and previews. Merely opening this sheet has no effect.
struct YouziArtifactDeleteConfirmation: View {
    @Environment(YouziProductModel.self) private var product
    @Environment(YouziI18nConfig.self) private var i18n
    @Environment(\.dismiss) private var dismiss
    let artifact: YouziArtifact
    var onDeleted: () -> Void = {}
    @State private var errorMessage: String?

    private var isManaged: Bool {
        if case .appManaged = product.file(for: artifact)?.location { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(i18n.text(zh: "删除成果？", en: "Delete deliverable?"), systemImage: "trash")
                .font(RapidFont.sectionTitle)
            Text(artifact.title).font(RapidFont.bodyEmphasis).textSelection(.enabled)
            Text(isManaged
                 ? i18n.text(zh: "文件将移到系统废纸篓，并从成果列表中移除。任务和对话记录会保留；需要找回文件时，可在 Finder 的废纸篓中恢复。",
                             en: "The file will move to Trash and leave your deliverables list. Your task and conversation remain. Recover the file from Trash in Finder if needed.")
                 : i18n.text(zh: "这是一份外部文件的引用，只会从成果列表中移除，原文件会保留。任务和对话记录不受影响。",
                             en: "This references an external file. Only the deliverable is removed; the original file, task and conversation remain."))
                .font(RapidFont.body).foregroundStyle(RapidTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let errorMessage {
                Text(i18n.text(zh: "删除未完成，请重试：", en: "Deletion did not finish. Please retry: ") + errorMessage)
                    .font(RapidFont.secondary).foregroundStyle(.red)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("YouziSimple.Results.DeleteError")
            }
            HStack {
                Spacer()
                Button(i18n.text(zh: "取消", en: "Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("YouziSimple.Results.CancelDelete")
                Button(isManaged ? i18n.text(zh: "移到废纸篓", en: "Move to Trash") : i18n.text(zh: "移除引用", en: "Remove reference"), role: .destructive) {
                    do {
                        try product.deleteArtifact(id: artifact.id)
                        dismiss()
                        onDeleted()
                    } catch { errorMessage = error.localizedDescription }
                }
                .accessibilityIdentifier("YouziSimple.Results.ConfirmDelete")
            }
        }
        .padding(24).frame(width: 440)
        .accessibilityIdentifier("YouziSimple.Results.DeleteConfirmation")
    }
}

/// Standalone preview toolbar entry. Menu entries present the shared sheet
/// from their page because menu content disappears as soon as an item is chosen.
struct YouziArtifactDeleteButton: View {
    @Environment(YouziI18nConfig.self) private var i18n
    let artifact: YouziArtifact
    var onDeleted: () -> Void = {}
    @State private var confirmsDeletion = false

    var body: some View {
        Button(role: .destructive) { confirmsDeletion = true } label: {
            Label(i18n.text(zh: "删除…", en: "Delete…"), systemImage: "trash")
        }
        .accessibilityIdentifier("YouziSimple.Results.DeletePreview")
        .sheet(isPresented: $confirmsDeletion) {
            YouziArtifactDeleteConfirmation(artifact: artifact, onDeleted: onDeleted)
        }
    }
}
