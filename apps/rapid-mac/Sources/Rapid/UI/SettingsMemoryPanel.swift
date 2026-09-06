import SwiftUI

/// Settings → Memory panel. Users can toggle extraction on/off, browse
/// learned entries, edit or delete individual ones, and clear the store.
@MainActor
struct SettingsMemoryPanel: View {
    @Environment(MemoryStore.self) private var memoryStore
    @Environment(YouziI18nConfig.self) private var i18n
    @State private var editingEntry: MemoryEntry?
    @State private var editDraft = ""
    @State private var confirmingClear = false

    private var isZh: Bool { i18n.isChinese }

    var body: some View {
        @Bindable var store = memoryStore
        VStack(alignment: .leading, spacing: RapidTheme.Space.xl) {
            SectionHeader(
                i18n.text(zh: "记忆", en: "Memory"),
                subtitle: i18n.text(
                    zh: "助手会跨对话记住你的偏好。数据不会离开这台 Mac。",
                    en: "The assistant remembers your preferences across conversations. Data never leaves this Mac."
                ),
                emphasis: .page
            )

            Toggle(isOn: Binding(
                get: { memoryStore.isEnabled },
                set: { memoryStore.isEnabled = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(i18n.text(zh: "自动记忆", en: "Automatic memory"))
                        .font(.body)
                    Text(i18n.text(
                        zh: "回顾已完成的对话并保存长期偏好。默认关闭。",
                        en: "Review completed conversations and retain long-term preferences. Off by default."
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .accessibilityIdentifier("Settings.Memory.EnableToggle")

            if memoryStore.isEnabled && !memoryStore.entries.isEmpty {
                HStack {
                    Text(isZh
                        ? "\(memoryStore.entries.count) 条已保存记忆"
                        : "\(memoryStore.entries.count) saved memor\(memoryStore.entries.count == 1 ? "y" : "ies")")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(i18n.text(zh: "清空全部", en: "Clear All"), role: .destructive) {
                        confirmingClear = true
                    }
                    .buttonStyle(.borderless)
                    .font(.callout)
                    .accessibilityIdentifier("Settings.Memory.ClearAll")
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(memoryStore.entries) { entry in
                            memoryRow(entry)
                        }
                    }
                }
                .frame(minHeight: 200)
            } else if memoryStore.isEnabled {
                Text(i18n.text(
                    zh: "暂无记忆。助手完成对话后会在这里显示记忆项。",
                    en: "No memories yet. They appear here after the assistant completes a conversation."
                ))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding()
        .alert(
            i18n.text(zh: "清空全部记忆？", en: "Clear all memories?"),
            isPresented: $confirmingClear
        ) {
            Button(i18n.text(zh: "取消", en: "Cancel"), role: .cancel) {}
                .accessibilityIdentifier("Settings.Memory.ClearAlert.Cancel")
            Button(i18n.text(zh: "清空", en: "Clear"), role: .destructive) {
                memoryStore.removeAll()
            }
            .accessibilityIdentifier("Settings.Memory.ClearAlert.Confirm")
        } message: {
            Text(i18n.text(
                zh: "这将删除所有已学习到的偏好信息，无法撤销。",
                en: "This removes every learned fact. It cannot be undone."
            ))
        }
        .sheet(item: $editingEntry) { entry in
            editSheet(entry)
        }
    }

    private func memoryRow(_ entry: MemoryEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.content)
                    .font(.callout)
                    .textSelection(.enabled)
                Text(isZh
                    ? "\(entry.evidenceCount) 次提及 · \(entry.updatedAt, style: .relative)"
                    : "\(entry.evidenceCount)× seen · \(entry.updatedAt, style: .relative)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button(i18n.text(zh: "编辑", en: "Edit")) {
                editDraft = entry.content
                editingEntry = entry
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .accessibilityIdentifier("Settings.Memory.Row.Edit")
            Button(role: .destructive) {
                memoryStore.remove(id: entry.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .accessibilityIdentifier("Settings.Memory.Row.Delete")
        }
        .padding(.vertical, 4)
    }

    private func editSheet(_ entry: MemoryEntry) -> some View {
        NavigationStack {
            Form {
                TextField(i18n.text(zh: "记忆内容", en: "Memory"), text: $editDraft, axis: .vertical)
                    .lineLimit(3...10)
                    .accessibilityIdentifier("Settings.Memory.EditSheet.Field")
            }
            .navigationTitle(i18n.text(zh: "编辑记忆", en: "Edit Memory"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(i18n.text(zh: "取消", en: "Cancel")) { editingEntry = nil }
                        .accessibilityIdentifier("Settings.Memory.EditSheet.Cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(i18n.text(zh: "保存", en: "Save")) {
                        memoryStore.update(id: entry.id, content: editDraft)
                        editingEntry = nil
                    }
                    .accessibilityIdentifier("Settings.Memory.EditSheet.Save")
                }
            }
        }
        .frame(minWidth: 380, minHeight: 200)
    }
}
