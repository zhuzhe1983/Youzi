import SwiftUI

struct YouziMemoryWorkbenchView: View {
    @Bindable private var model: YouziMemoryWorkbenchModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingImport = false
    @State private var showingPrivacy = false
    @State private var confirmingForget = false

    init(model: YouziMemoryWorkbenchModel) {
        self.model = model
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let status = model.statusMessage {
                statusBar(status)
            }
            content
        }
        .background(RapidTheme.surfaceCanvas)
        .accessibilityIdentifier("YouziSimple.Surface.knowMe")
        .task {
            guard model.phase == .idle else { return }
            await model.load()
        }
        .sheet(isPresented: $showingImport) {
            YouziMemoryImportSheet(model: model)
                .frame(minWidth: 520, minHeight: 520)
        }
        .sheet(isPresented: $showingPrivacy) {
            YouziMemoryPrivacySheet()
                .frame(minWidth: 480, minHeight: 420)
        }
        .confirmationDialog(
            "删除这条记忆？",
            isPresented: $confirmingForget,
            titleVisibility: .visible
        ) {
            Button("删除记忆", role: .destructive) {
                Task { await model.forgetSelected() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会删除这条派生记忆及其关系；原始文件或对话仍由各自来源管理。")
        }
    }

    private var header: some View {
        HStack(spacing: RapidTheme.Space.md) {
            VStack(alignment: .leading, spacing: RapidTheme.Space.xxs) {
                Text("知我")
                    .font(RapidFont.pageTitle)
                Text("从已授权的依据中查看、整理和修正柚子对你的了解。")
                    .font(RapidFont.secondary)
                    .foregroundStyle(RapidTheme.textSecondary)
            }
            Spacer(minLength: RapidTheme.Space.md)
            TextField("搜索记忆", text: $model.query)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 250)
                .accessibilityIdentifier("YouziMemory.Search")
            Picker("呈现方式", selection: $model.presentation) {
                ForEach(YouziMemoryWorkbenchPresentation.allCases) { presentation in
                    Text(presentation.title).tag(presentation)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 126)
            .accessibilityIdentifier("YouziMemory.Presentation")
            Button {
                showingImport = true
            } label: {
                Label("添加资料", systemImage: "doc.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canImportFiles || model.isMutating)
            .help(model.canImportFiles ? "手动选择文件并加入分析队列" : "文件选择尚未连接")
            .accessibilityIdentifier("YouziMemory.Import")
            Button {
                showingPrivacy = true
            } label: {
                Image(systemName: "hand.raised")
            }
            .buttonStyle(.bordered)
            .help("隐私与来源说明")
            .accessibilityLabel("隐私与来源说明")
            .accessibilityIdentifier("YouziMemory.Privacy")
        }
        .padding(.horizontal, RapidTheme.Space.xl)
        .padding(.vertical, RapidTheme.Space.lg)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle, .loading:
            ProgressView("正在读取知我图谱…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            ContentUnavailableView {
                Label("知我暂时不可用", systemImage: "exclamationmark.lock")
            } description: {
                Text(message)
            } actions: {
                Button("重试") { Task { await model.load() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            if model.snapshot?.nodes.isEmpty != false {
                ContentUnavailableView {
                    Label("还没有可展示的记忆", systemImage: "point.3.connected.trianglepath.dotted")
                } description: {
                    Text("只有来自当前授权范围、带有效依据的记忆才会显示在这里。")
                } actions: {
                    Button("添加资料") { showingImport = true }
                        .disabled(!model.canImportFiles)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                workbench
            }
        }
    }

    private var workbench: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 980 {
                HStack(spacing: 0) {
                    filters
                        .frame(width: 210)
                    Divider()
                    graphOrList
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    inspector
                        .frame(width: 310)
                }
            } else {
                VStack(spacing: 0) {
                    compactFilters
                    Divider()
                    graphOrList
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    inspector
                        .frame(height: min(300, geometry.size.height * 0.42))
                }
            }
        }
    }

    private var filters: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RapidTheme.Space.lg) {
                VStack(alignment: .leading, spacing: RapidTheme.Space.xs) {
                    sectionLabel("领域")
                    ForEach(YouziMemoryWorkbenchFacet.allCases) { facet in
                        filterButton(facet)
                    }
                }
                VStack(alignment: .leading, spacing: RapidTheme.Space.xs) {
                    HStack {
                        sectionLabel("分类")
                        Spacer(minLength: 0)
                        if !model.selectedCategoryIDs.isEmpty {
                            Button("清除") { model.selectedCategoryIDs.removeAll() }
                                .buttonStyle(.plain)
                                .font(RapidFont.caption)
                        }
                    }
                    ForEach(model.categories) { category in
                        categoryFilter(category)
                    }
                }
                sourceLimitNote
            }
            .padding(RapidTheme.Space.md)
        }
        .background(RapidTheme.surfaceSidebar)
        .accessibilityIdentifier("YouziMemory.Filters")
    }

    private var compactFilters: some View {
        HStack(spacing: RapidTheme.Space.sm) {
            ScrollView(.horizontal) {
                HStack(spacing: RapidTheme.Space.xs) {
                    ForEach(YouziMemoryWorkbenchFacet.allCases) { facet in
                        filterButton(facet)
                    }
                }
            }
            Menu {
                ForEach(model.categories) { category in
                    Button {
                        toggleCategory(category.id)
                    } label: {
                        Label(
                            category.name,
                            systemImage: model.selectedCategoryIDs.contains(category.id)
                                ? "checkmark" : "circle"
                        )
                    }
                }
                if !model.selectedCategoryIDs.isEmpty {
                    Divider()
                    Button("清除分类筛选") { model.selectedCategoryIDs.removeAll() }
                }
            } label: {
                Label("分类", systemImage: "line.3.horizontal.decrease.circle")
            }
            .menuStyle(.borderlessButton)
        }
        .padding(.horizontal, RapidTheme.Space.md)
        .frame(minHeight: 48)
        .background(RapidTheme.surfaceSidebar)
        .accessibilityIdentifier("YouziMemory.CompactFilters")
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(RapidFont.groupLabel)
            .foregroundStyle(RapidTheme.textSecondary)
    }

    private func filterButton(_ facet: YouziMemoryWorkbenchFacet) -> some View {
        Button {
            model.selectedFacet = facet
        } label: {
            HStack(spacing: RapidTheme.Space.sm) {
                Image(systemName: facet.systemImage)
                    .frame(width: 18)
                Text(facet.title)
                Spacer(minLength: 0)
            }
            .font(model.selectedFacet == facet ? RapidFont.bodyEmphasis : RapidFont.body)
            .padding(.horizontal, RapidTheme.Space.sm)
            .frame(minHeight: 36)
            .background(
                RoundedRectangle(cornerRadius: RapidTheme.Radius.card, style: .continuous)
                    .fill(model.selectedFacet == facet ? RapidTheme.selectionFill : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(model.selectedFacet == facet ? .isSelected : [])
        .accessibilityIdentifier("YouziMemory.Facet.\(facet.rawValue)")
    }

    private func categoryFilter(_ category: YouziMemoryCategoryRecord) -> some View {
        Button {
            toggleCategory(category.id)
        } label: {
            HStack(spacing: RapidTheme.Space.sm) {
                Image(systemName: model.selectedCategoryIDs.contains(category.id)
                    ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(model.selectedCategoryIDs.contains(category.id)
                        ? RapidTheme.brandPrimary : RapidTheme.textSecondary)
                Text(category.name)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(RapidFont.secondary)
            .frame(minHeight: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("YouziMemory.CategoryFilter.\(category.id.uuidString)")
    }

    private var sourceLimitNote: some View {
        HStack(alignment: .top, spacing: RapidTheme.Space.xs) {
            Image(systemName: "checkmark.shield")
            Text(limitDescription)
        }
        .font(RapidFont.caption)
        .foregroundStyle(RapidTheme.textSecondary)
        .padding(.top, RapidTheme.Space.sm)
    }

    private var limitDescription: String {
        let count = model.snapshot?.nodes.count ?? 0
        return model.snapshot?.hasMoreNodes == true
            ? "已展示前 \(count) 个有权访问的节点。"
            : "显示 \(count) 个有权访问的节点。"
    }

    @ViewBuilder
    private var graphOrList: some View {
        if model.visibleNodes.isEmpty {
            ContentUnavailableView(
                "没有匹配的记忆",
                systemImage: "line.3.horizontal.decrease.circle",
                description: Text("调整领域、分类或搜索词后重试。")
            )
        } else if model.presentation == .graph {
            YouziMemoryGraphCanvas(model: model, reduceMotion: reduceMotion)
        } else {
            YouziMemoryNodeList(model: model)
        }
    }

    private var inspector: some View {
        ScrollView {
            if let node = model.selectedNode {
                VStack(alignment: .leading, spacing: RapidTheme.Space.lg) {
                    nodeSummary(node)
                    categoryEditor(node)
                    relationSection(node)
                    citationSection(node)
                    Divider()
                    Button(role: .destructive) {
                        confirmingForget = true
                    } label: {
                        Label("删除这条记忆", systemImage: "trash")
                    }
                    .disabled(model.isMutating)
                    .accessibilityIdentifier("YouziMemory.Forget")
                }
                .padding(RapidTheme.Space.lg)
            } else {
                ContentUnavailableView(
                    "选择一个节点",
                    systemImage: "cursorarrow.click",
                    description: Text("节点详情、关系与依据会显示在这里。")
                )
                .padding(RapidTheme.Space.lg)
            }
        }
        .background(RapidTheme.surfaceRaised)
        .accessibilityIdentifier("YouziMemory.Inspector")
    }

    private func nodeSummary(_ node: YouziMemoryNodeRecord) -> some View {
        VStack(alignment: .leading, spacing: RapidTheme.Space.sm) {
            HStack(alignment: .top) {
                Image(systemName: node.kind.systemImage)
                    .foregroundStyle(RapidTheme.brandPrimary)
                    .font(.system(size: 20))
                Text(node.label)
                    .font(RapidFont.sectionTitle)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            Text(node.content)
                .font(RapidFont.body)
                .textSelection(.enabled)
            HStack(spacing: RapidTheme.Space.sm) {
                metadataPill(node.kind.title)
                metadataPill(node.state.title)
                metadataPill("置信度 \(Int((node.confidence * 100).rounded()))%")
            }
            .accessibilityElement(children: .combine)
            Text("范围：\(node.scope.displayName) · 隐私：\(node.sensitivity.title)")
                .font(RapidFont.caption)
                .foregroundStyle(RapidTheme.textSecondary)
        }
    }

    private func metadataPill(_ title: String) -> some View {
        Text(title)
            .font(RapidFont.caption)
            .foregroundStyle(RapidTheme.textSecondary)
            .padding(.horizontal, RapidTheme.Space.sm)
            .frame(minHeight: 24)
            .background(
                Capsule().fill(RapidTheme.surfaceCanvas)
            )
    }

    private func categoryEditor(_ node: YouziMemoryNodeRecord) -> some View {
        let memberships = model.categoryIDs(for: node.id)
        return VStack(alignment: .leading, spacing: RapidTheme.Space.sm) {
            Text("分类")
                .font(RapidFont.bodyEmphasis)
            if model.categories.isEmpty {
                Text("暂无可用分类。")
                    .font(RapidFont.secondary)
                    .foregroundStyle(RapidTheme.textSecondary)
            } else {
                YouziMemoryFlowLayout(spacing: RapidTheme.Space.xs) {
                    ForEach(model.categories) { category in
                        Button {
                            var updated = memberships
                            if !updated.insert(category.id).inserted {
                                updated.remove(category.id)
                            }
                            Task { await model.classifySelected(categoryIDs: updated) }
                        } label: {
                            Label(
                                category.name,
                                systemImage: memberships.contains(category.id)
                                    ? "checkmark" : "plus"
                            )
                            .font(RapidFont.caption)
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.isMutating)
                        .accessibilityIdentifier(
                            "YouziMemory.Classify.\(category.id.uuidString)"
                        )
                    }
                }
            }
        }
    }

    private func relationSection(_ node: YouziMemoryNodeRecord) -> some View {
        VStack(alignment: .leading, spacing: RapidTheme.Space.sm) {
            Text("关系")
                .font(RapidFont.bodyEmphasis)
            if model.selectedRelations.isEmpty {
                Text("还没有可展示的关系。")
                    .font(RapidFont.secondary)
                    .foregroundStyle(RapidTheme.textSecondary)
            } else {
                ForEach(model.selectedRelations.prefix(6)) { relation in
                    let otherID = relation.sourceNodeID == node.id
                        ? relation.targetNodeID : relation.sourceNodeID
                    Button {
                        Task { await model.select(otherID) }
                    } label: {
                        HStack(alignment: .top, spacing: RapidTheme.Space.sm) {
                            Image(systemName: "arrow.triangle.branch")
                                .foregroundStyle(RapidTheme.textSecondary)
                            VStack(alignment: .leading, spacing: RapidTheme.Space.xxs) {
                                Text(relation.relation.title)
                                    .font(RapidFont.caption)
                                    .foregroundStyle(RapidTheme.textSecondary)
                                Text(model.node(id: otherID)?.label ?? "不可用节点")
                                    .font(RapidFont.secondary)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func citationSection(_ node: YouziMemoryNodeRecord) -> some View {
        VStack(alignment: .leading, spacing: RapidTheme.Space.sm) {
            HStack {
                Text("依据")
                    .font(RapidFont.bodyEmphasis)
                Spacer(minLength: 0)
                Text("\(model.citationCount(for: node.id)) 条")
                    .font(RapidFont.caption)
                    .foregroundStyle(RapidTheme.textSecondary)
            }
            if model.isLoadingCitations {
                ProgressView()
                    .controlSize(.small)
            } else if model.citations.isEmpty {
                Text("当前授权范围内没有可读依据。")
                    .font(RapidFont.secondary)
                    .foregroundStyle(RapidTheme.textSecondary)
            } else {
                ForEach(model.citations.prefix(5)) { citation in
                    VStack(alignment: .leading, spacing: RapidTheme.Space.xs) {
                        Label(citation.locator.displayName, systemImage: "quote.opening")
                            .font(RapidFont.caption)
                            .foregroundStyle(RapidTheme.textSecondary)
                        Text(citation.excerpt.isEmpty ? "来源已撤销，摘录不可读。" : citation.excerpt)
                            .font(RapidFont.secondary)
                            .lineLimit(4)
                            .textSelection(.enabled)
                        Text("校验：\(citation.contentChecksum.prefix(10))…")
                            .font(.caption2.monospaced())
                            .foregroundStyle(RapidTheme.textSecondary)
                    }
                    .padding(RapidTheme.Space.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: RapidTheme.Radius.card, style: .continuous)
                            .fill(RapidTheme.surfaceCanvas)
                    )
                    .accessibilityIdentifier("YouziMemory.Citation.\(citation.id.uuidString)")
                }
            }
        }
    }

    private func statusBar(_ status: String) -> some View {
        HStack(spacing: RapidTheme.Space.sm) {
            Image(systemName: "info.circle")
            Text(status)
                .font(RapidFont.secondary)
            Spacer(minLength: 0)
            Button("关闭") { model.dismissStatus() }
                .buttonStyle(.plain)
        }
        .foregroundStyle(RapidTheme.textSecondary)
        .padding(.horizontal, RapidTheme.Space.xl)
        .frame(minHeight: 36)
        .background(RapidTheme.brandPrimaryTint)
        .accessibilityIdentifier("YouziMemory.Status")
    }

    private func toggleCategory(_ id: UUID) {
        if !model.selectedCategoryIDs.insert(id).inserted {
            model.selectedCategoryIDs.remove(id)
        }
    }
}

struct YouziMemoryWorkbenchUnavailableView: View {
    var body: some View {
        ContentUnavailableView {
            Label("知我尚未连接", systemImage: "point.3.connected.trianglepath.dotted")
        } description: {
            Text("当前窗口没有获得知我服务。为保护隐私，页面不会自行创建另一份记忆库。")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("YouziSimple.Surface.knowMe")
    }
}

private struct YouziMemoryGraphCanvas: View {
    @Bindable var model: YouziMemoryWorkbenchModel
    let reduceMotion: Bool
    @State private var zoom = 1.0
    @State private var pan: CGSize = .zero
    @State private var yaw = 0.28
    @GestureState private var dragOffset: CGSize = .zero
    @GestureState private var liveMagnification = 1.0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: RapidTheme.Space.xs) {
                Text("关系图")
                    .font(RapidFont.bodyEmphasis)
                Text("\(model.visibleNodes.count) 个节点")
                    .font(RapidFont.caption)
                    .foregroundStyle(RapidTheme.textSecondary)
                Spacer(minLength: 0)
                Button { yaw -= 0.22 } label: { Image(systemName: "rotate.left") }
                    .help("向左旋转")
                Button { yaw += 0.22 } label: { Image(systemName: "rotate.right") }
                    .help("向右旋转")
                Button { zoom = max(0.6, zoom - 0.15) } label: { Image(systemName: "minus.magnifyingglass") }
                    .help("缩小")
                Button { zoom = min(2.4, zoom + 0.15) } label: { Image(systemName: "plus.magnifyingglass") }
                    .help("放大")
                Button("复位") {
                    zoom = 1
                    pan = .zero
                    yaw = 0.28
                }
                .help("复位图谱视角")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, RapidTheme.Space.md)
            .frame(minHeight: 44)
            Divider()
            GeometryReader { geometry in
                let nodes = model.visibleNodes
                let edges = model.visibleEdges
                let positions = YouziMemoryGraphLayout.positions(nodes: nodes, edges: edges)
                let currentPan = CGSize(
                    width: pan.width + dragOffset.width,
                    height: pan.height + dragOffset.height
                )
                let currentZoom = zoom * liveMagnification
                let projections = positions.mapValues {
                    YouziMemoryGraphLayout.project(
                        $0, yaw: yaw, zoom: currentZoom,
                        pan: currentPan, viewport: geometry.size
                    )
                }

                ZStack {
                    Canvas { context, _ in
                        for edge in edges {
                            guard let source = projections[edge.sourceNodeID]?.point,
                                  let target = projections[edge.targetNodeID]?.point
                            else { continue }
                            var path = Path()
                            path.move(to: source)
                            path.addLine(to: target)
                            context.stroke(path, with: .color(RapidTheme.hairline), lineWidth: 1)
                        }
                    }
                    .accessibilityHidden(true)

                    ForEach(nodes.sorted { lhs, rhs in
                        (projections[lhs.id]?.depth ?? 0) < (projections[rhs.id]?.depth ?? 0)
                    }) { node in
                        if let projection = projections[node.id] {
                            nodeButton(node, projection: projection)
                        }
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .updating($dragOffset) { value, state, _ in state = value.translation }
                        .onEnded { value in
                            pan.width += value.translation.width
                            pan.height += value.translation.height
                        }
                )
                .simultaneousGesture(
                    MagnificationGesture()
                        .updating($liveMagnification) { value, state, _ in state = value }
                        .onEnded { value in zoom = min(max(zoom * value, 0.6), 2.4) }
                )
            }
            .accessibilityLabel("知我关系图")
            .accessibilityHint("拖动平移，捏合缩放；也可切换到列表浏览。")
        }
        .accessibilityIdentifier("YouziMemory.Graph")
    }

    private func nodeButton(
        _ node: YouziMemoryNodeRecord,
        projection: YouziMemoryGraphProjection
    ) -> some View {
        let selected = model.selectedNodeID == node.id
        return Button {
            Task { await model.select(node.id) }
        } label: {
            HStack(spacing: RapidTheme.Space.xs) {
                Image(systemName: node.kind.systemImage)
                Text(node.label)
                    .lineLimit(1)
            }
            .font(selected ? RapidFont.bodyEmphasis : RapidFont.secondary)
            .foregroundStyle(RapidTheme.textPrimary)
            .padding(.horizontal, RapidTheme.Space.sm)
            .frame(minWidth: 74, minHeight: 44)
            .background(
                Capsule()
                    .fill(selected ? RapidTheme.brandPrimaryTint : RapidTheme.surfaceRaised)
            )
            .overlay(
                Capsule()
                    .stroke(selected ? RapidTheme.brandPrimary : RapidTheme.hairline, lineWidth: selected ? 1.5 : 1)
            )
            .shadow(color: RapidTheme.hairline.opacity(0.7), radius: 5, y: 3)
        }
        .buttonStyle(.plain)
        .scaleEffect(projection.scale)
        .position(projection.point)
        .zIndex(projection.depth)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: projection.point)
        .accessibilityLabel("\(node.kind.title)：\(node.label)")
        .accessibilityValue(model.selectedNodeID == node.id ? "已选择" : "")
        .accessibilityHint("显示节点详情、关系与依据")
        .accessibilityIdentifier("YouziMemory.Node.\(node.id.uuidString)")
    }
}

private struct YouziMemoryNodeList: View {
    @Bindable var model: YouziMemoryWorkbenchModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: RapidTheme.Space.sm) {
                ForEach(model.visibleNodes) { node in
                    Button {
                        Task { await model.select(node.id) }
                    } label: {
                        HStack(alignment: .top, spacing: RapidTheme.Space.md) {
                            Image(systemName: node.kind.systemImage)
                                .foregroundStyle(RapidTheme.brandPrimary)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: RapidTheme.Space.xs) {
                                Text(node.label)
                                    .font(RapidFont.bodyEmphasis)
                                Text(node.content)
                                    .font(RapidFont.secondary)
                                    .foregroundStyle(RapidTheme.textSecondary)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 0)
                            Text("\(model.citationCount(for: node.id)) 条依据")
                                .font(RapidFont.caption)
                                .foregroundStyle(RapidTheme.textSecondary)
                        }
                        .padding(RapidTheme.Space.md)
                        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: RapidTheme.Radius.card, style: .continuous)
                                .fill(model.selectedNodeID == node.id
                                    ? RapidTheme.selectionFill : RapidTheme.surfaceRaised)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("YouziMemory.ListNode.\(node.id.uuidString)")
                }
            }
            .padding(RapidTheme.Space.lg)
        }
        .accessibilityIdentifier("YouziMemory.List")
    }
}

private struct YouziMemoryImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: YouziMemoryWorkbenchModel
    @State private var mode: YouziMemoryImportMode = .managedCopy
    @State private var scope: YouziMemoryScopeRecord?
    @State private var categoryIDs: Set<UUID> = []

    init(model: YouziMemoryWorkbenchModel) {
        self.model = model
        _scope = State(initialValue: model.availableScopes.first)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RapidTheme.Space.xl) {
            VStack(alignment: .leading, spacing: RapidTheme.Space.xs) {
                Text("添加资料")
                    .font(RapidFont.pageTitle)
                Text("选择导入方式、可见范围和分类。文件内容由同一知我服务按授权读取。")
                    .font(RapidFont.body)
                    .foregroundStyle(RapidTheme.textSecondary)
            }
            Form {
                Picker("导入方式", selection: $mode) {
                    Text("导入副本").tag(YouziMemoryImportMode.managedCopy)
                    Text("保留原位置").tag(YouziMemoryImportMode.securityScopedReference)
                }
                if let scope {
                    Picker("可见范围", selection: Binding(
                        get: { scope },
                        set: { self.scope = $0 }
                    )) {
                        ForEach(model.availableScopes, id: \.self) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                } else {
                    Text("没有获准的导入范围。")
                        .foregroundStyle(RapidTheme.textSecondary)
                }
                Section("分类") {
                    ForEach(model.categories) { category in
                        Toggle(category.name, isOn: Binding(
                            get: { categoryIDs.contains(category.id) },
                            set: { enabled in
                                if enabled { categoryIDs.insert(category.id) }
                                else { categoryIDs.remove(category.id) }
                            }
                        ))
                    }
                }
            }
            Spacer(minLength: 0)
            HStack {
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer(minLength: 0)
                Button("选择文件…") {
                    guard let scope else { return }
                    dismiss()
                    Task {
                        await model.importFiles(
                            mode: mode, scope: scope, categoryIDs: categoryIDs
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(scope == nil || !model.canImportFiles)
                .accessibilityIdentifier("YouziMemory.Import.ChooseFiles")
            }
        }
        .padding(RapidTheme.Space.xl)
        .accessibilityIdentifier("YouziMemory.ImportSheet")
    }
}

private struct YouziMemoryPrivacySheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: RapidTheme.Space.xl) {
            Label("隐私与来源", systemImage: "hand.raised.fill")
                .font(RapidFont.pageTitle)
                .foregroundStyle(RapidTheme.textPrimary)
            privacyRow(
                icon: "externaldrive",
                title: "本机保存",
                detail: "知我图谱保存在本机的单一 SQLite 记忆库中。这个页面不会另建副本。"
            )
            privacyRow(
                icon: "checkmark.shield",
                title: "按授权读取",
                detail: "节点、关系与依据只在当前获准范围内展示；来源撤销后，摘录会立即不可读。"
            )
            privacyRow(
                icon: "text.quote",
                title: "有据可查",
                detail: "每条记忆都保留结构化引用和校验信息，不把未获授权的原文复制到界面状态。"
            )
            privacyRow(
                icon: "trash",
                title: "删除边界",
                detail: "删除会移除派生记忆及关系；原始文件或对话仍由其所属位置管理。"
            )
            Spacer(minLength: 0)
            HStack {
                Spacer(minLength: 0)
                Button("完成") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(RapidTheme.Space.xl)
        .accessibilityIdentifier("YouziMemory.PrivacySheet")
    }

    private func privacyRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: RapidTheme.Space.md) {
            Image(systemName: icon)
                .foregroundStyle(RapidTheme.brandPrimary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: RapidTheme.Space.xs) {
                Text(title).font(RapidFont.bodyEmphasis)
                Text(detail)
                    .font(RapidFont.body)
                    .foregroundStyle(RapidTheme.textSecondary)
            }
        }
    }
}

private extension YouziMemoryRecordKind {
    var title: String {
        switch self {
        case .user: "本人"
        case .person: "人物"
        case .organization: "组织"
        case .location: "地点"
        case .project: "项目"
        case .workspace: "工作空间"
        case .conversation: "对话"
        case .document: "文档"
        case .topic: "主题"
        case .preference: "偏好"
        case .goal: "目标"
        case .habit: "习惯"
        case .event: "事件"
        case .decision: "决定"
        case .file: "文件"
        case .artifact: "成果"
        }
    }

    var systemImage: String {
        switch self {
        case .user, .person: "person"
        case .organization: "building.2"
        case .location: "mappin"
        case .project: "square.stack.3d.up"
        case .workspace: "folder"
        case .conversation: "text.bubble"
        case .document, .file: "doc"
        case .topic: "number"
        case .preference: "heart"
        case .goal: "target"
        case .habit: "repeat"
        case .event: "calendar"
        case .decision: "checkmark.seal"
        case .artifact: "sparkles.rectangle.stack"
        }
    }
}

private extension YouziMemoryRecordState {
    var title: String {
        switch self {
        case .proposed: "建议"
        case .awaitingConfirmation: "待确认"
        case .confirmed: "已确认"
        case .superseded: "已合并"
        case .forgotten: "已删除"
        }
    }
}

private extension YouziMemorySensitivity {
    var title: String {
        switch self {
        case .ordinary: "普通"
        case .personal: "个人"
        case .sensitive: "敏感"
        case .sealed: "密封"
        }
    }
}

private extension YouziMemoryScopeRecord {
    var displayName: String {
        switch kind {
        case .personal: "个人"
        case .project: "项目 \(identifier.map { String($0.uuidString.prefix(6)) } ?? "")"
        case .workspace: "工作空间 \(identifier.map { String($0.uuidString.prefix(6)) } ?? "")"
        }
    }
}

private extension YouziMemoryRelationKind {
    var title: String {
        switch self {
        case .knows: "认识"
        case .belongsTo: "属于"
        case .likes: "喜欢"
        case .avoids: "避免"
        case .responsibleFor: "负责"
        case .participatesIn: "参与"
        case .dependsOn: "依赖"
        case .happenedAt: "发生于"
        case .sourcedFrom: "来源于"
        case .replaces: "取代"
        case .conflictsWith: "相冲突"
        }
    }
}

private extension YouziMemorySourceLocator {
    var displayName: String {
        let base: String
        switch kind {
        case .message: base = "对话消息"
        case .page: base = "页面"
        case .sheetRange: base = "表格范围"
        case .slide: base = "幻灯片"
        case .heading: base = "标题"
        case .paragraph: base = "段落"
        case .block: base = "内容块"
        case .object: base = "对象"
        case .legacy: base = "旧版记录"
        }
        if let ordinal { return "\(base) · \(ordinal + 1)" }
        if let detail, !detail.isEmpty { return "\(base) · \(detail)" }
        return base
    }
}

private struct YouziMemoryFlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let result = lines(proposal: proposal, subviews: subviews)
        return CGSize(width: proposal.width ?? result.width, height: result.height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }

    private func lines(
        proposal: ProposedViewSize,
        subviews: Subviews
    ) -> (width: CGFloat, height: CGFloat) {
        let maximumWidth = proposal.width ?? .greatestFiniteMagnitude
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maximumWidth {
                usedWidth = max(usedWidth, x - spacing)
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        usedWidth = max(usedWidth, max(0, x - spacing))
        return (usedWidth, y + lineHeight)
    }
}
