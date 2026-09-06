import AppKit
import SwiftUI

struct SettingsDataManagementPanel: View {
    @Environment(YouziProductModel.self) private var product
    @Environment(ChatViewModel.self) private var chat
    @Environment(YouziSharingCenter.self) private var sharing
    @Environment(YouziI18nConfig.self) private var i18n
    @State private var tab: Tab = .archived
    @State private var query = ""
    @State private var inspectedTask: YouziTask?
    @State private var inspectedShare: YouziShareRecord?
    @State private var removingShare: YouziShareRecord?
    @State private var fileError: String?

    enum Tab: String, CaseIterable { case archived, files, tasks }

    private var archivedTasks: [YouziTask] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return product.tasks.filter {
            $0.status == .archived && (needle.isEmpty || $0.title.localizedStandardContains(needle))
        }.sorted { $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RapidTheme.Space.lg) {
            SectionHeader(t("数据管理", "Data Management"),
                          subtitle: t("归档保留任务内容；分享记录仅保存在本机。", "Archives retain task contents; sharing history stays on this Mac."),
                          emphasis: .page)
                .accessibilityIdentifier("Settings.Data.Panel")
            Picker(t("数据类型", "Data type"), selection: $tab) {
                Text(t("归档的任务", "Archived Tasks")).tag(Tab.archived)
                Text(t("分享的文件", "Shared Files")).tag(Tab.files)
                Text(t("分享的任务", "Shared Tasks")).tag(Tab.tasks)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("Settings.Data.Tabs")
            TextField(t("搜索名称或分享方式", "Search name or sharing service"), text: $query)
                .textFieldStyle(.plain)
                .padding(RapidTheme.Space.sm)
                .background(RapidTheme.surfaceCode, in: RoundedRectangle(cornerRadius: RapidTheme.Radius.code))
                .accessibilityIdentifier("Settings.Data.Search")
            if let error = product.lastPersistenceError ?? sharing.history.lastError ?? sharing.errorMessage ?? fileError {
                Text(error).font(RapidFont.caption).foregroundStyle(RapidTheme.statusError)
            }
            if tab == .archived {
                archiveSection
            } else {
                shareSection
            }
        }
        .font(RapidFont.body)
        .sheet(item: $inspectedTask) { task in
            taskDetail(task)
        }
        .sheet(item: $inspectedShare) { record in
            shareDetail(record)
        }
        .alert(t("移除本机分享记录？", "Remove local sharing record?"),
               isPresented: Binding(get: { removingShare != nil }, set: { if !$0 { removingShare = nil } })) {
            Button(t("取消", "Cancel"), role: .cancel) { removingShare = nil }
            Button(t("移除记录", "Remove Record"), role: .destructive) {
                if let removingShare { sharing.history.removeRecord(removingShare.id) }
                removingShare = nil
            }
        } message: {
            Text(t("仅删除这条记录，不会删除原文件或任务，也无法撤回接收方已获得的副本。", "Only this history entry is removed. Original files and tasks remain, and delivered copies cannot be recalled."))
        }

    }

    private var archiveSection: some View {
        SettingsSection(t("归档的任务 · \(archivedTasks.count)", "Archived Tasks · \(archivedTasks.count)")) {
            if archivedTasks.isEmpty {
                empty(t("暂无归档任务或没有匹配结果", "No archived tasks or matching results"))
            } else {
                ForEach(archivedTasks) { task in
                    HStack(spacing: RapidTheme.Space.md) {
                        Image(systemName: "archivebox").foregroundStyle(RapidTheme.textSecondary)
                        VStack(alignment: .leading, spacing: RapidTheme.Space.xxs) {
                            Text(task.title).font(RapidFont.bodyEmphasis).lineLimit(2)
                            Text(task.updatedAt, style: .date).font(RapidFont.caption).foregroundStyle(RapidTheme.textSecondary)
                        }
                        Spacer(minLength: 0)
                        Menu {
                            Button(t("查看内容", "View Contents")) { inspectedTask = task }
                            Button(t("分享对话文本…", "Share Conversation Text…")) { sharing.shareTask(task, chat: chat) }
                                .disabled(sharing.isSharing)
                        } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        Button(t("恢复", "Restore")) { product.setTaskArchived(task.id, false, chat: chat) }
                            .buttonStyle(.rapidSecondaryCompact)
                            .accessibilityIdentifier("Settings.Data.Restore.\(task.id.uuidString)")
                    }
                    .padding(.vertical, RapidTheme.Space.sm)
                }
            }
        }
    }

    private var shareSection: some View {
        let records = sharing.history.matching(kind: tab == .files ? .file : .task, query: query)
        return VStack(alignment: .leading, spacing: RapidTheme.Space.md) {
            Text(t("记录通过 macOS 分享服务成功交付的副本。不会自动上传；不提供在线链接、有效期或远程撤回。", "Records copies successfully handed off by macOS sharing services. No automatic uploads, hosted links, expiry, or remote recall."))
                .font(RapidFont.secondary).foregroundStyle(RapidTheme.textSecondary)
            SettingsSection(t("分享记录 · \(records.count)", "Sharing History · \(records.count)")) {
                if records.isEmpty {
                    empty(t("暂无分享记录或没有匹配结果。可从任务菜单或「我的文件」分享。", "No sharing history or matching results. Share from a task menu or My Files."))
                } else {
                    ForEach(records) { record in
                        HStack(spacing: RapidTheme.Space.md) {
                            VStack(alignment: .leading, spacing: RapidTheme.Space.xxs) {
                                Text(record.title).font(RapidFont.bodyEmphasis).lineLimit(2)
                                Text("\(record.service) · \(record.sharedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(RapidFont.caption).foregroundStyle(RapidTheme.textSecondary)
                            }
                            Spacer(minLength: 0)
                            Button(t("详情", "Details")) { inspectedShare = record }
                                .buttonStyle(.rapidSecondaryCompact)
                            Button(t("移除记录", "Remove Record")) { removingShare = record }
                                .buttonStyle(.rapidSecondaryCompact)
                        }.padding(.vertical, RapidTheme.Space.sm)
                    }
                }
            }
        }
    }

    private func taskDetail(_ task: YouziTask) -> some View {
        VStack(alignment: .leading, spacing: RapidTheme.Space.md) {
            Text(task.title).font(RapidFont.pageTitle)
            ScrollView {
                VStack(alignment: .leading, spacing: RapidTheme.Space.md) {
                    if let conversation = chat.conversations.first(where: { $0.id == task.conversationID }) {
                        ForEach(conversation.messages.filter { $0.role == .user || $0.role == .assistant }) { message in
                            VStack(alignment: .leading, spacing: RapidTheme.Space.xs) {
                                Text(message.role == .user ? t("你", "You") : t("助手", "Assistant"))
                                    .font(RapidFont.bodyEmphasis)
                                Text(message.content).font(RapidFont.body).textSelection(.enabled)
                            }
                        }
                    } else {
                        Text(task.request.isEmpty ? t("暂无对话内容", "No conversation contents") : task.request)
                            .font(RapidFont.body).textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Button(t("关闭", "Close")) { inspectedTask = nil }.buttonStyle(.rapidSecondaryCompact)
        }.padding(RapidTheme.Space.xl).frame(minWidth: 460, idealWidth: 640, minHeight: 360, idealHeight: 560)
    }

    private func shareDetail(_ record: YouziShareRecord) -> some View {
        VStack(alignment: .leading, spacing: RapidTheme.Space.lg) {
            Text(record.title).font(RapidFont.pageTitle)
            Text(record.service).font(RapidFont.body)
            Text(record.sharedAt, format: .dateTime).font(RapidFont.secondary)
            Text(t("此记录不是在线分享链接。查看原始内容可能与分享时的版本不同；已发送的副本无法从 Youzi 撤回。", "This is not an online sharing link. The current source may differ from the shared version; Youzi cannot recall delivered copies."))
                .font(RapidFont.secondary).foregroundStyle(RapidTheme.textSecondary)
            if record.kind == .task, let task = product.task(id: record.sourceID) {
                Text(task.request).font(RapidFont.body).lineLimit(6).textSelection(.enabled)
                Button(t("再次分享当前文本…", "Share Current Text Again…")) { sharing.shareTask(task, chat: chat) }
                    .buttonStyle(.rapidSecondaryCompact).disabled(sharing.isSharing)
            } else if record.kind == .file, let file = product.file(id: record.sourceID) {
                Text(file.displayName).font(RapidFont.body)
                Button(t("再次分享当前文件…", "Share Current File Again…")) { sharing.shareFile(file, product: product) }
                    .buttonStyle(.rapidSecondaryCompact).disabled(sharing.isSharing)
            } else {
                Text(t("原始内容已不存在，保留历史记录。", "The source no longer exists. This history entry is retained."))
                    .font(RapidFont.secondary)
            }
            if let error = sharing.errorMessage { Text(error).font(RapidFont.caption).foregroundStyle(RapidTheme.statusError) }
            Button(t("关闭", "Close")) { inspectedShare = nil }.buttonStyle(.rapidSecondaryCompact)
        }.padding(RapidTheme.Space.xl).frame(minWidth: 420, idealWidth: 560)
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(RapidFont.secondary).foregroundStyle(RapidTheme.textSecondary)
            .frame(maxWidth: .infinity, minHeight: 120).padding(RapidTheme.Space.md)
    }

    private func t(_ zh: String, _ en: String) -> String { i18n.text(zh: zh, en: en) }
}
