import SwiftUI

/// A domain-backed list of deliverables with "My Files" layout.
/// Artifact bytes and filesystem access stay behind the product model;
/// this view only presents records and reports explicit user actions.
struct YouziSimpleResultsPage: View {
    @Environment(YouziI18nConfig.self) private var i18n
    let artifacts: [YouziArtifact]
    let fileForArtifact: (YouziArtifact) -> YouziFile?
    let onPreview: (YouziArtifact) -> Void
    let onRevealInFinder: (YouziArtifact) -> Void
    let onExport: (YouziArtifact) -> Void
    var onShare: ((YouziArtifact) -> Void)? = nil

    @State private var selectedKind: YouziArtifactKind? = nil
    @State private var searchText = ""
    @State private var viewMode: ViewMode = .list

    enum ViewMode: String, CaseIterable, Identifiable {
        case list = "list"
        case previewGrid = "previewGrid"

        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerSection
                .padding(.horizontal, RapidTheme.Space.xl)
                .padding(.top, RapidTheme.Space.xl)
                .padding(.bottom, RapidTheme.Space.md)

            Divider()

            filterToolbar
                .padding(.horizontal, RapidTheme.Space.xl)
                .padding(.vertical, RapidTheme.Space.sm)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: RapidTheme.Space.lg) {
                    if sortedArtifacts.isEmpty {
                        emptyState
                    } else if filteredArtifacts.isEmpty {
                        noMatchState
                    } else {
                        switch viewMode {
                        case .list:
                            listView
                        case .previewGrid:
                            previewGridView
                        }
                    }
                }
                .padding(RapidTheme.Space.xl)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("YouziSimple.Surface.results")
    }

    private var headerSection: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: RapidTheme.Space.xxs) {
                Text(i18n.text(zh: "成果", en: "Deliverables"))
                    .font(RapidFont.pageTitle)
                Text(i18n.text(
                    zh: "快捷查看任务成果，上传到云端网盘开启跨端同步。",
                    en: "Quickly view task deliverables and sync cross-device with cloud storage."
                ))
                .font(RapidFont.secondary)
                .foregroundStyle(RapidTheme.textSecondary)
            }
            Spacer(minLength: 0)

            Picker("View Mode", selection: $viewMode) {
                Image(systemName: "list.bullet")
                    .tag(ViewMode.list)
                    .accessibilityLabel(i18n.text(zh: "列表视图", en: "List View"))
                Image(systemName: "square.grid.2x2")
                    .tag(ViewMode.previewGrid)
                    .accessibilityLabel(i18n.text(zh: "预览网格", en: "Preview Grid"))
            }
            .pickerStyle(.segmented)
            .frame(width: 80)
        }
    }

    private var filterToolbar: some View {
        HStack(spacing: RapidTheme.Space.md) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: RapidTheme.Space.xs) {
                    categoryChip(title: i18n.text(zh: "全部", en: "All"), isSelected: selectedKind == nil) {
                        selectedKind = nil
                    }

                    ForEach(YouziArtifactKind.allCases, id: \.self) { kind in
                        categoryChip(
                            title: kind.localizedDisplayName(isChinese: i18n.isChinese),
                            icon: kind.systemImage,
                            isSelected: selectedKind == kind
                        ) {
                            selectedKind = (selectedKind == kind ? nil : kind)
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: RapidTheme.Space.xs) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(RapidTheme.textSecondary)
                TextField(i18n.text(zh: "搜索成果名称或内容…", en: "Search deliverables…"), text: $searchText)
                    .textFieldStyle(.plain)
                    .font(RapidFont.secondary)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(RapidTheme.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, RapidTheme.Space.sm)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(RapidTheme.surfaceSidebar)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(RapidTheme.hairline, lineWidth: 1)
            )
            .frame(width: 220)
        }
    }

    private func categoryChip(title: String, icon: String? = nil, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: RapidTheme.Space.xxs) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11))
                }
                Text(title)
                    .font(RapidFont.caption)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(isSelected ? RapidTheme.brandPrimaryTint : RapidTheme.surfaceSidebar)
            )
            .overlay(
                Capsule()
                    .strokeBorder(isSelected ? RapidTheme.brandPrimary.opacity(0.4) : RapidTheme.hairline, lineWidth: 1)
            )
            .foregroundStyle(isSelected ? RapidTheme.brandPrimary : RapidTheme.textPrimary)
        }
        .buttonStyle(.plain)
    }

    private var sortedArtifacts: [YouziArtifact] {
        artifacts
            .filter { $0.state != .archived }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var filteredArtifacts: [YouziArtifact] {
        sortedArtifacts.filter { artifact in
            if let kind = selectedKind, artifact.kind != kind {
                return false
            }
            if !searchText.isEmpty {
                let lower = searchText.lowercased()
                let titleMatch = artifact.title.lowercased().contains(lower)
                let previewMatch = artifact.previewText?.lowercased().contains(lower) ?? false
                return titleMatch || previewMatch
            }
            return true
        }
    }

    private var listView: some View {
        LazyVStack(spacing: RapidTheme.Space.md) {
            ForEach(filteredArtifacts) { artifact in
                artifactCard(artifact)
            }
        }
        .frame(maxWidth: 820)
    }

    private var previewGridView: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 220, maximum: 280), spacing: RapidTheme.Space.md)],
            spacing: RapidTheme.Space.md
        ) {
            ForEach(filteredArtifacts) { artifact in
                artifactPreviewCard(artifact)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: RapidTheme.Space.lg) {
            Image(systemName: "tray")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(RapidTheme.brandPrimary)
                .frame(width: 72, height: 72)
                .background(Circle().fill(RapidTheme.brandPrimaryTint))
            Text(i18n.text(zh: "还没有任务成果", en: "No Deliverables Yet"))
                .font(RapidFont.sectionTitle)
            Text(i18n.text(zh: "任务生成文档、图片或其他文件后，会集中显示在这里。", en: "Once tasks generate documents, images, or files, they will appear here."))
                .font(RapidFont.body)
                .foregroundStyle(RapidTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, RapidTheme.Space.huge)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("YouziSimple.Results.Empty")
    }

    private var noMatchState: some View {
        VStack(spacing: RapidTheme.Space.md) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(RapidTheme.textSecondary)
            Text(i18n.text(zh: "没有找到符合条件的成果", en: "No matching deliverables found"))
                .font(RapidFont.bodyEmphasis)
            Text(i18n.text(zh: "请尝试更改筛选类型或搜索关键词。", en: "Try changing the filter or search query."))
                .font(RapidFont.caption)
                .foregroundStyle(RapidTheme.textSecondary)
        }
        .padding(.vertical, RapidTheme.Space.huge)
        .frame(maxWidth: .infinity)
    }

    private func artifactCard(_ artifact: YouziArtifact) -> some View {
        let file = fileForArtifact(artifact)
        let canResolveFile = artifact.state == .active && file?.availability == .available

        return VStack(alignment: .leading, spacing: RapidTheme.Space.md) {
            HStack(alignment: .top, spacing: RapidTheme.Space.md) {
                Image(systemName: artifact.kind.systemImage)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(RapidTheme.brandPrimary)
                    .frame(width: 42, height: 42)
                    .background(
                        RoundedRectangle(cornerRadius: RapidTheme.Radius.button, style: .continuous)
                            .fill(RapidTheme.brandPrimaryTint)
                    )

                VStack(alignment: .leading, spacing: RapidTheme.Space.xs) {
                    Text(artifact.title)
                        .font(RapidFont.sectionTitle)
                        .lineLimit(2)
                    HStack(spacing: RapidTheme.Space.sm) {
                        Text(artifact.kind.localizedDisplayName(isChinese: i18n.isChinese))
                        Text(artifact.updatedAt, style: .relative)
                    }
                    .font(RapidFont.caption)
                    .foregroundStyle(RapidTheme.textSecondary)
                }

                Spacer(minLength: 0)

                if !canResolveFile {
                    Label(i18n.text(zh: "文件需要重新定位", en: "File needs relocation"), systemImage: "exclamationmark.circle")
                        .font(RapidFont.caption)
                        .foregroundStyle(RapidTheme.textSecondary)
                }
            }

            if let preview = artifact.previewText, !preview.isEmpty {
                Text(preview)
                    .font(RapidFont.secondary)
                    .foregroundStyle(RapidTheme.textSecondary)
                    .lineLimit(3)
            }

            Divider()

            HStack(spacing: RapidTheme.Space.sm) {
                Button(i18n.text(zh: "预览", en: "Preview")) {
                    onPreview(artifact)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canResolveFile && artifact.previewText?.isEmpty != false)
                .accessibilityIdentifier("YouziSimple.Results.Preview.\(artifact.id.uuidString)")

                Button(i18n.text(zh: "在 Finder 中显示", en: "Reveal in Finder")) {
                    onRevealInFinder(artifact)
                }
                .buttonStyle(.bordered)
                .disabled(!canResolveFile)
                .accessibilityIdentifier("YouziSimple.Results.Reveal.\(artifact.id.uuidString)")

                Spacer(minLength: 0)

                if let onShare {
                    Button(i18n.text(zh: "分享…", en: "Share…")) { onShare(artifact) }
                        .buttonStyle(.bordered)
                        .disabled(!canResolveFile)
                }
                Button(i18n.text(zh: "导出副本…", en: "Export Copy…")) {
                    onExport(artifact)
                }
                .buttonStyle(.bordered)
                .disabled(!canResolveFile)
                .accessibilityIdentifier("YouziSimple.Results.Export.\(artifact.id.uuidString)")
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
        .accessibilityIdentifier("YouziSimple.Result.\(artifact.id.uuidString)")
    }

    private func artifactPreviewCard(_ artifact: YouziArtifact) -> some View {
        let file = fileForArtifact(artifact)
        let canResolveFile = artifact.state == .active && file?.availability == .available

        return VStack(alignment: .leading, spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(RapidTheme.surfaceSidebar)

                if artifact.kind == .image {
                    VStack(spacing: RapidTheme.Space.xs) {
                        Image(systemName: "photo.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(RapidTheme.brandPrimary.opacity(0.8))
                        Text(i18n.text(zh: "图片成果", en: "Image Deliverable"))
                            .font(RapidFont.caption)
                            .foregroundStyle(RapidTheme.textSecondary)
                    }
                } else if artifact.kind == .video {
                    VStack(spacing: RapidTheme.Space.xs) {
                        Image(systemName: "film.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(Color.orange.opacity(0.8))
                        Text(i18n.text(zh: "视频成果", en: "Video Deliverable"))
                            .font(RapidFont.caption)
                            .foregroundStyle(RapidTheme.textSecondary)
                    }
                } else if let preview = artifact.previewText, !preview.isEmpty {
                    Text(preview)
                        .font(.system(size: 10))
                        .foregroundStyle(RapidTheme.textSecondary)
                        .padding(RapidTheme.Space.sm)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .clipped()
                } else {
                    Image(systemName: artifact.kind.systemImage)
                        .font(.system(size: 32))
                        .foregroundStyle(RapidTheme.brandPrimary.opacity(0.7))
                }
            }
            .frame(height: 120)
            .clipped()

            VStack(alignment: .leading, spacing: RapidTheme.Space.xs) {
                Text(artifact.title)
                    .font(RapidFont.bodyEmphasis)
                    .lineLimit(1)

                HStack(spacing: RapidTheme.Space.xs) {
                    Text(artifact.kind.localizedDisplayName(isChinese: i18n.isChinese))
                        .font(RapidFont.caption)
                        .foregroundStyle(RapidTheme.textSecondary)
                    Spacer()
                    Text(artifact.updatedAt, style: .relative)
                        .font(RapidFont.caption)
                        .foregroundStyle(RapidTheme.textSecondary)
                }

                Divider()
                    .padding(.vertical, 2)

                HStack(spacing: RapidTheme.Space.xs) {
                    Button(i18n.text(zh: "预览", en: "Preview")) {
                        onPreview(artifact)
                    }
                    .buttonStyle(.plain)
                    .font(RapidFont.caption)
                    .foregroundStyle(RapidTheme.brandPrimary)
                    .disabled(!canResolveFile && artifact.previewText?.isEmpty != false)

                    Spacer()

                    Button {
                        onRevealInFinder(artifact)
                    } label: {
                        Image(systemName: "folder")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canResolveFile)
                    .help(i18n.text(zh: "在 Finder 中显示", en: "Reveal in Finder"))

                    if let onShare {
                        Button { onShare(artifact) } label: {
                            Image(systemName: "person.crop.circle.badge.arrow.up")
                        }
                        .buttonStyle(.plain)
                        .disabled(!canResolveFile)
                        .help(i18n.text(zh: "分享…", en: "Share…"))
                    }
                    Button {
                        onExport(artifact)
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canResolveFile)
                    .help(i18n.text(zh: "导出副本…", en: "Export Copy…"))
                }
            }
            .padding(RapidTheme.Space.md)
        }
        .background(
            RoundedRectangle(cornerRadius: RapidTheme.Radius.card, style: .continuous)
                .fill(RapidTheme.surfaceRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RapidTheme.Radius.card, style: .continuous)
                .strokeBorder(RapidTheme.hairline, lineWidth: 1)
        )
        .accessibilityIdentifier("YouziSimple.Result.Grid.\(artifact.id.uuidString)")
    }
}

extension YouziArtifactKind: CaseIterable {
    public static var allCases: [YouziArtifactKind] {
        [.document, .spreadsheet, .image, .video, .audio, .code, .archive, .other]
    }
}

private extension YouziArtifactKind {
    func localizedDisplayName(isChinese: Bool) -> String {
        if isChinese { return displayName }
        switch self {
        case .document: return "Document"
        case .spreadsheet: return "Spreadsheet"
        case .image: return "Image"
        case .audio: return "Audio"
        case .video: return "Video"
        case .code: return "Code"
        case .archive: return "Archive"
        case .other: return "Other"
        }
    }

    var displayName: String {
        switch self {
        case .document: "文档"
        case .spreadsheet: "表格"
        case .image: "图片"
        case .audio: "音频"
        case .video: "视频"
        case .code: "代码"
        case .archive: "压缩文件"
        case .other: "其他"
        }
    }

    var systemImage: String {
        switch self {
        case .document: "doc.text"
        case .spreadsheet: "tablecells"
        case .image: "photo"
        case .audio: "waveform"
        case .video: "film"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .archive: "archivebox"
        case .other: "doc"
        }
    }
}
