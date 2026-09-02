import SwiftUI

/// A presentation-only catalog for starting an editable task draft.
///
/// Choosing a template reports the bundled definition to the caller. The
/// product model remains the sole owner of creating and persisting the draft;
/// this surface never starts execution by itself.
struct YouziSimpleTemplateGallery: View {
    let catalog: YouziBundledTemplateCatalog
    let onCreateDraft: (YouziBundledTemplateCatalog.Entry) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: RapidTheme.Space.xl) {
                VStack(alignment: .leading, spacing: RapidTheme.Space.xs) {
                    Text("从模板开始")
                        .font(RapidFont.pageTitle)
                    Text("选择一个起点，再按你的需要修改任务。")
                        .font(RapidFont.body)
                        .foregroundStyle(RapidTheme.textSecondary)
                }

                ForEach(groupedEntries, id: \.category) { group in
                    VStack(alignment: .leading, spacing: RapidTheme.Space.md) {
                        Text(group.category)
                            .font(RapidFont.groupLabel)
                            .foregroundStyle(RapidTheme.textSecondary)

                        ForEach(group.entries) { entry in
                            templateCard(entry)
                        }
                    }
                }
            }
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(RapidTheme.Space.xl)
        }
        .accessibilityIdentifier("YouziSimple.Templates")
    }

    private var groupedEntries: [(category: String, entries: [YouziBundledTemplateCatalog.Entry])] {
        let categories = Dictionary(grouping: catalog.templates, by: \.category)
        return categories.keys.sorted().map { category in
            (category, categories[category, default: []])
        }
    }

    private func templateCard(_ entry: YouziBundledTemplateCatalog.Entry) -> some View {
        VStack(alignment: .leading, spacing: RapidTheme.Space.md) {
            HStack(alignment: .firstTextBaseline, spacing: RapidTheme.Space.md) {
                Text(entry.name)
                    .font(RapidFont.sectionTitle)
                Spacer(minLength: 0)
                Text("模板 \(catalog.catalogVersion)")
                    .font(RapidFont.caption)
                    .foregroundStyle(RapidTheme.textSecondary)
            }

            Text(entry.summary)
                .font(RapidFont.body)
                .foregroundStyle(RapidTheme.textSecondary)

            VStack(alignment: .leading, spacing: RapidTheme.Space.xs) {
                Label("示例成果", systemImage: "doc.text.magnifyingglass")
                    .font(RapidFont.bodyEmphasis)
                Text(entry.samplePreview)
                    .font(RapidFont.secondary)
                    .foregroundStyle(RapidTheme.textSecondary)
                    .lineLimit(3)
            }
            .padding(RapidTheme.Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: RapidTheme.Radius.card, style: .continuous)
                    .fill(RapidTheme.surfaceCanvas)
            )

            HStack(alignment: .center, spacing: RapidTheme.Space.md) {
                Label(
                    "需要\(entry.requiredInputs.count)项资料",
                    systemImage: "paperclip"
                )
                .font(RapidFont.caption)
                .foregroundStyle(RapidTheme.textSecondary)

                Spacer(minLength: 0)

                Button("创建可编辑草稿") {
                    onCreateDraft(entry)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier(
                    "YouziSimple.Template.CreateDraft.\(entry.id.uuidString)"
                )
            }
        }
        .padding(RapidTheme.Space.lg)
        .background(
            RoundedRectangle(cornerRadius: RapidTheme.Radius.card, style: .continuous)
                .fill(RapidTheme.surfaceRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RapidTheme.Radius.card, style: .continuous)
                .strokeBorder(RapidTheme.hairline, lineWidth: 1)
        )
    }
}
