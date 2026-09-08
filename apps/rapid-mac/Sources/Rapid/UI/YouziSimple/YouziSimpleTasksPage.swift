import SwiftUI

/// The header's More action opens a collection page, not a second task store.
struct YouziTaskListQuery {
    var search = ""
    var pinnedOnly = false

    func apply(to tasks: [YouziTask]) -> [YouziTask] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return tasks.filter {
            $0.status != .archived && (!pinnedOnly || $0.isPinned)
                && (query.isEmpty || $0.title.localizedStandardContains(query))
        }.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}

struct YouziSimpleTasksPage<Row: View>: View {
    @Environment(YouziI18nConfig.self) private var i18n
    let tasks: [YouziTask]
    @ViewBuilder var row: (YouziTask) -> Row
    @State private var query = YouziTaskListQuery()

    var body: some View {
        let visible = query.apply(to: tasks)
        VStack(alignment: .leading, spacing: RapidTheme.Space.md) {
            HStack {
                Text(i18n.text(zh: "任务", en: "Tasks")).font(RapidFont.pageTitle)
                Text("\(visible.count)").font(RapidFont.secondary).foregroundStyle(RapidTheme.textSecondary)
                Spacer()
            }
            HStack(spacing: RapidTheme.Space.md) {
                TextField(i18n.text(zh: "搜索任务", en: "Search tasks"), text: $query.search)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("YouziSimple.Tasks.Search")
                Picker(i18n.text(zh: "筛选任务", en: "Filter tasks"), selection: $query.pinnedOnly) {
                    Text(i18n.text(zh: "全部", en: "All")).tag(false)
                    Text(i18n.text(zh: "置顶", en: "Pinned")).tag(true)
                }
                .pickerStyle(.segmented).frame(width: 150)
                .accessibilityIdentifier("YouziSimple.Tasks.Filter")
            }
            if visible.isEmpty {
                ContentUnavailableView(
                    i18n.text(zh: "没有匹配的任务", en: "No matching tasks"),
                    systemImage: "checklist",
                    description: Text(i18n.text(zh: "可以调整搜索或筛选，或从新任务开始。", en: "Change the search or filter, or start a new task.")))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: RapidTheme.Space.sm) {
                        ForEach(visible) { task in row(task) }
                    }
                }
                .accessibilityIdentifier("YouziSimple.Tasks.List")
            }
        }
        .padding(RapidTheme.Space.xl)
        .frame(maxWidth: 900, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityIdentifier("YouziSimple.Surface.tasks")
    }
}
