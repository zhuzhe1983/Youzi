import SwiftUI

/// A domain-backed list of deliverables. Artifact bytes and filesystem access
/// stay behind the product model; this view only presents records and reports
/// explicit user actions.
struct YouziSimpleResultsPage: View {
    let artifacts: [YouziArtifact]
    let fileForArtifact: (YouziArtifact) -> YouziFile?
    let onPreview: (YouziArtifact) -> Void
    let onRevealInFinder: (YouziArtifact) -> Void
    let onExport: (YouziArtifact) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: RapidTheme.Space.xl) {
                VStack(alignment: .leading, spacing: RapidTheme.Space.xs) {
                    Text("成果")
                        .font(RapidFont.pageTitle)
                    Text("这里只显示任务产生的文件和可交付成果。")
                        .font(RapidFont.body)
                        .foregroundStyle(RapidTheme.textSecondary)
                }

                if sortedArtifacts.isEmpty {
                    emptyState
                } else {
                    ForEach(sortedArtifacts) { artifact in
                        artifactCard(artifact)
                    }
                }
            }
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(RapidTheme.Space.xl)
        }
        .accessibilityIdentifier("YouziSimple.Surface.results")
    }

    private var sortedArtifacts: [YouziArtifact] {
        artifacts
            .filter { $0.state != .archived }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var emptyState: some View {
        VStack(spacing: RapidTheme.Space.lg) {
            Image(systemName: "tray")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(RapidTheme.brandPrimary)
                .frame(width: 72, height: 72)
                .background(Circle().fill(RapidTheme.brandPrimaryTint))
            Text("还没有任务成果")
                .font(RapidFont.sectionTitle)
            Text("任务生成文档、图片或其他文件后，会集中显示在这里。")
                .font(RapidFont.body)
                .foregroundStyle(RapidTheme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, RapidTheme.Space.huge)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("YouziSimple.Results.Empty")
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
                        Text(artifact.kind.displayName)
                        Text(artifact.updatedAt, style: .relative)
                    }
                    .font(RapidFont.caption)
                    .foregroundStyle(RapidTheme.textSecondary)
                }

                Spacer(minLength: 0)

                if !canResolveFile {
                    Label("文件需要重新定位", systemImage: "exclamationmark.circle")
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
                Button("预览") {
                    onPreview(artifact)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canResolveFile && artifact.previewText?.isEmpty != false)
                .accessibilityIdentifier("YouziSimple.Results.Preview.\(artifact.id.uuidString)")

                Button("在 Finder 中显示") {
                    onRevealInFinder(artifact)
                }
                .buttonStyle(.bordered)
                .disabled(!canResolveFile)
                .accessibilityIdentifier("YouziSimple.Results.Reveal.\(artifact.id.uuidString)")

                Spacer(minLength: 0)

                Button("导出副本…") {
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
}

private extension YouziArtifactKind {
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
