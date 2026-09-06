import SwiftUI

/// Domain records and injected media leases keep filesystem ownership outside UI.
struct YouziSimpleResultsPage: View {
    @Environment(YouziI18nConfig.self) private var i18n
    let artifacts: [YouziArtifact]
    let fileForArtifact: (YouziArtifact) -> YouziFile?
    let onPreview: (YouziArtifact) -> Void
    let onRevealInFinder: (YouziArtifact) -> Void
    let onExport: (YouziArtifact) -> Void
    var onShare: ((YouziArtifact) -> Void)? = nil
    let mediaLease: (YouziArtifact) async throws -> YouziMediaFileLease

    @State private var selectedKind: YouziArtifactKind?
    @State private var searchText = ""
    @AppStorage("youzi.results.cardSize") private var cardSize: YouziArtifactCardSize = .medium
    @State private var playback = YouziArtifactPlayback()

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                headerSection.padding(.horizontal, RapidTheme.Space.xl)
                    .padding(.top, RapidTheme.Space.xl).padding(.bottom, RapidTheme.Space.md)
                filterToolbar.padding(.horizontal, RapidTheme.Space.xl)
                    .padding(.vertical, RapidTheme.Space.sm)
                ScrollView {
                    if sortedArtifacts.isEmpty {
                        emptyState
                    } else if filteredArtifacts.isEmpty {
                        noMatchState
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: cardSize.edge), spacing: 18, alignment: .top)], spacing: 22) {
                            ForEach(filteredArtifacts) { artifact in
                                artifactCard(artifact)
                            }
                        }
                        .padding(RapidTheme.Space.xl)
                    }
                }
                if let title = playback.audioTitle {
                    HStack(spacing: 12) {
                        Image(systemName: "waveform").foregroundStyle(RapidTheme.brandPrimary)
                        Text(title).font(RapidFont.secondary).lineLimit(1)
                        Spacer()
                        Button { playback.toggleAudio() } label: {
                            Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        }
                        .help(i18n.text(zh: "播放 / 暂停", en: "Play / Pause"))
                            .accessibilityIdentifier("YouziSimpleResultsPage.Button.8fc150735a")
                        Button { playback.stop() } label: { Image(systemName: "xmark") }
                            .help(i18n.text(zh: "停止播放", en: "Stop playback"))
                            .accessibilityIdentifier("YouziSimpleResultsPage.Button.8abc841163")
                    }
                    .buttonStyle(.plain).padding(14)
                    .background(RapidTheme.surfaceSidebar)
                }
            }
            .allowsHitTesting(playback.preview == nil)
            .accessibilityHidden(playback.preview != nil)
            if let preview = playback.preview {
                YouziArtifactMediaOverlay(preview: preview, onClose: { playback.stop() })
                    .id(preview.id).zIndex(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert(i18n.text(zh: "无法预览文件", en: "Unable to preview file"), isPresented: Binding(
            get: { playback.failed }, set: { playback.failed = $0 }
        )) {
            Button(i18n.text(zh: "好", en: "OK"), role: .cancel) {}
                .accessibilityIdentifier("YouziSimpleResultsPage.Button.2a749ebe68")
        } message: {
            Text(i18n.text(zh: "文件可能已移动、无访问权限或格式不受支持。可以通过卡片菜单在 Finder 中查看。",
                           en: "The file may have moved, require access, or use an unsupported format. Use the card menu to reveal it in Finder."))
        }
        .onDisappear { playback.stop() }
        .accessibilityIdentifier("YouziSimple.Surface.results")
    }

    private var headerSection: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(i18n.text(zh: "成果", en: "Deliverables")).font(RapidFont.pageTitle)
                Text(i18n.text(zh: "集中查看本地成果，点击预览或播放。", en: "Your local deliverables. Click to preview or play."))
                    .font(RapidFont.secondary).foregroundStyle(RapidTheme.textSecondary)
            }
            Spacer(minLength: 0)
            Picker(i18n.text(zh: "卡片大小", en: "Card size"), selection: $cardSize) {
                ForEach(YouziArtifactCardSize.allCases) { size in
                    Text(size.title(isChinese: i18n.isChinese)).tag(size)
                }
            }
            .labelsHidden().pickerStyle(.segmented).frame(width: 156)
            .accessibilityLabel(i18n.text(zh: "卡片大小", en: "Card size"))
            .accessibilityIdentifier("YouziSimple.Results.CardSize")
        }
    }

    private func artifactCard(_ artifact: YouziArtifact) -> some View {
        let file = fileForArtifact(artifact)
        let canResolveFile = artifact.state == .active && (file?.availability == .available || file?.availability == .staleBookmark)
        let canPreview = canResolveFile || (artifact.previewText != nil && ![.image, .video, .audio].contains(artifact.kind))
        return VStack(alignment: .leading, spacing: 9) {
            Button {
                switch artifact.kind {
                case .image, .video, .audio:
                    Task { await playback.open(artifact, lease: { try await mediaLease(artifact) }) }
                default: onPreview(artifact)
                }
            } label: {
                YouziArtifactThumbnail(
                    artifact: artifact,
                    revision: file?.updatedAt ?? artifact.updatedAt,
                    playing: playback.audioID == artifact.id && playback.isPlaying,
                    available: canResolveFile,
                    mediaLease: { try await mediaLease(artifact) }
                )
            }
            .buttonStyle(.plain)
            .disabled(!canPreview)
            .accessibilityLabel(artifact.title)
            .accessibilityHint(i18n.text(zh: artifact.kind == .audio ? "播放或暂停音频" : "打开预览",
                                         en: artifact.kind == .audio ? "Play or pause audio" : "Open preview"))
                .accessibilityIdentifier("YouziSimpleResultsPage.Button.f3caba8ecf")
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(artifact.title).font(RapidFont.bodyEmphasis).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(artifact.title)
                    HStack(spacing: 5) {
                        Text(artifact.kind.localizedDisplayName(isChinese: i18n.isChinese))
                        if let bytes = file?.byteCount {
                            Text("· " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                        }
                    }
                    .font(RapidFont.caption).foregroundStyle(RapidTheme.textSecondary).lineLimit(1)
                }
                Menu {
                    Button(i18n.text(zh: "预览", en: "Preview")) {
                        if [.image, .video, .audio].contains(artifact.kind) {
                            Task { await playback.open(artifact, lease: { try await mediaLease(artifact) }) }
                        } else { onPreview(artifact) }
                    }.disabled(!canPreview)
                        .accessibilityIdentifier("YouziSimpleResultsPage.Button.c7db977d18")
                    Button(i18n.text(zh: "在 Finder 中显示", en: "Show in Finder")) { onRevealInFinder(artifact) }.disabled(!canResolveFile)
                        .accessibilityIdentifier("YouziSimpleResultsPage.Button.983747be89")
                    Button(i18n.text(zh: "导出…", en: "Export…")) { onExport(artifact) }.disabled(!canResolveFile)
                        .accessibilityIdentifier("YouziSimpleResultsPage.Button.e392e4adb6")
                    if let onShare {
                        Button(i18n.text(zh: "分享…", en: "Share…")) { onShare(artifact) }.disabled(!canResolveFile)
                            .accessibilityIdentifier("YouziSimpleResultsPage.Button.1662d00fd4")
                    }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel(i18n.text(zh: "文件操作", en: "File actions") + " " + artifact.title)
                    .accessibilityIdentifier("YouziSimpleResultsPage.Menu.283e51db34")
            }
        }
        .accessibilityIdentifier("YouziSimple.Result.Grid.\(artifact.id.uuidString)")
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
                    .accessibilityIdentifier("YouziSimpleResultsPage.TextField.ed33470309")
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(RapidTheme.textSecondary)
                    }
                    .buttonStyle(.plain)
                        .accessibilityIdentifier("YouziSimpleResultsPage.Button.9258733616")
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
            .accessibilityIdentifier("YouziSimpleResultsPage.Button.95cc41dabb")
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

}

extension YouziArtifactKind: CaseIterable {
    public static var allCases: [YouziArtifactKind] {
        [.document, .spreadsheet, .image, .video, .audio, .code, .archive, .other]
    }
}

extension YouziArtifactKind {
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
