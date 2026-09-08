import SwiftUI

struct YouziModelTableView: View {
    typealias Data = YouziModelTableData
    var rows: [Data.Row]
    var hardwareDescription: String
    var download: (ModelEntry) -> Void
    var cancel: (ModelEntry) -> Void
    var load: (ModelEntry) -> Void
    var delete: (ModelEntry) -> Void
    var favorite: (ModelEntry) -> Void
    @Environment(YouziI18nConfig.self) private var i18n
    @Environment(YouziFontSizeConfig.self) private var fonts
    @Environment(\.colorScheme) private var colorScheme
    @State private var query = ""
    @State private var filter: Data.Filter = .all
    @State private var family: String? = nil
    @State private var quantization: Double? = nil
    @State private var recommendedOnly = false
    @State private var measuredOnly = false
    @State private var sorts: [Data.Sort] = [.init()]
    @State private var showMethod = false

    private func text(_ zh: String, _ en: String) -> String { i18n.text(zh: zh, en: en) }
    private var visible: [Data.Row] {
        Data.visible(rows, query: query, filter: filter, family: family,
                     quantization: quantization, recommendedOnly: recommendedOnly,
                     measuredOnly: measuredOnly, sorts: sorts)
    }
    private var hasFilters: Bool {
        !query.isEmpty || filter != .all || family != nil || quantization != nil || recommendedOnly || measuredOnly
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            toolbar
            HStack(spacing: 6) {
                Text(text("模型", "Models")).font(fonts.font(13.5, weight: .medium))
                Text("\(visible.count) / \(rows.count)").monospacedDigit()
                if rows.contains(where: { $0.recommendationRank != nil }) {
                    Label(text("推荐置顶", "Recommendations pinned"), systemImage: "pin.fill")
                        .foregroundStyle(RapidTheme.brand)
                        .help(text("根据 \(hardwareDescription) 推荐；同样参与搜索和筛选。", "Recommended for \(hardwareDescription); search and filters also apply."))
                }
                Spacer(minLength: 4)
                Button { showMethod.toggle() } label: {
                    Label(text("指标说明", "Metrics"), systemImage: "info.circle")
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showMethod) { methodology.padding(16).frame(width: 360) }
                .accessibilityIdentifier("Settings.ModelManagement.MetricsInfo")
            }
            .font(fonts.font(11.5)).foregroundStyle(RapidTheme.textSecondary)

            YouziNativeModelTable(rows: visible, chinese: i18n.isChinese, scale: fonts.size.scale, colorScheme: colorScheme,
                                  sorts: sorts, onSort: { sorts = $0 }) { row, column in
                AnyView(cell(row, column).font(fonts.font(12.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .environment(\.colorScheme, colorScheme))
            }
            .frame(height: max(360, 440 * fonts.size.scale))
            .overlay {
                if visible.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").font(.title2)
                        Text(text("没有匹配的模型", "No matching models"))
                        if hasFilters { Button(text("清除筛选", "Clear filters"), action: clearFilters) }
                    }.foregroundStyle(.secondary)
                        .padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(RapidTheme.hairlineStrong))
            Text(text("点击列头排序 · 拖动调整列宽与顺序 · 左右滚动查看全部指标", "Click headers to sort · Drag to resize/reorder columns · Scroll horizontally for all metrics"))
                .font(fonts.font(11.5)).foregroundStyle(RapidTheme.textSecondary)
        }
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(text("搜索模型、系列或仓库", "Search models, families or repos"), text: $query)
                        .textFieldStyle(.plain)
                        .accessibilityIdentifier("Settings.ModelManagement.Search")
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).accessibilityLabel(text("清除搜索", "Clear search"))
                    }
                }
                .padding(.horizontal, 10).frame(height: 32 * max(1, fonts.size.scale))
                .background(RapidTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(RapidTheme.hairlineStrong))
                Menu {
                    ForEach(Data.Column.allCases.filter { $0 != .actions }, id: \.self) { column in
                        Button(column.title(chinese: i18n.isChinese)) {
                            sorts = [.init(column: column, ascending: column == .model)]
                        }
                    }
                    Divider()
                    Button(text("反向排序", "Reverse sort")) {
                        if !sorts.isEmpty { sorts[0].ascending.toggle() }
                    }
                } label: { Label(text("排序", "Sort"), systemImage: "arrow.up.arrow.down") }
                    .fixedSize().accessibilityIdentifier("Settings.ModelManagement.SortMenu")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { filterControls }
                VStack(alignment: .leading, spacing: 8) { filterControls }
            }
        }.font(fonts.font(12.5))
    }

    @ViewBuilder private var filterControls: some View {
        Picker(text("状态", "Status"), selection: $filter) {
            ForEach(Data.Filter.allCases) { item in Text(item.title(chinese: i18n.isChinese)).tag(item) }
        }.labelsHidden().fixedSize().accessibilityIdentifier("Settings.ModelManagement.Filter")
        Menu {
            Button(text("全部系列", "All families")) { family = nil }
            ForEach(Array(Set(rows.map(\.family))).sorted(), id: \.self) { item in
                Button { family = item } label: {
                    if family == item { Label(item, systemImage: "checkmark") } else { Text(item) }
                }
            }
        } label: { Text(family ?? text("全部系列", "All families")) }
            .fixedSize().accessibilityIdentifier("Settings.ModelManagement.FamilyFilter")
        Menu {
            Button(text("全部量化", "All quantizations")) { quantization = nil }
            ForEach(Array(Set(rows.compactMap(\.quantization))).sorted(), id: \.self) { item in
                Button("\(number(item)) bit") { quantization = item }
            }
        } label: { Text(quantization.map { "\(number($0)) bit" } ?? text("全部量化", "All quantizations")) }
            .fixedSize().accessibilityIdentifier("Settings.ModelManagement.QuantizationFilter")
        Menu {
            Toggle(text("仅推荐模型", "Recommended only"), isOn: $recommendedOnly)
            Toggle(text("仅完整速质指标", "Complete quality + speed only"), isOn: $measuredOnly)
        } label: {
            Label(text("筛选", "Filter") + ((recommendedOnly || measuredOnly) ? " •" : ""), systemImage: "line.3.horizontal.decrease")
        }.fixedSize()
        if hasFilters {
            Button(text("重置", "Reset"), action: clearFilters).buttonStyle(.plain)
                .foregroundStyle(RapidTheme.brand).fixedSize()
                .accessibilityIdentifier("Settings.ModelManagement.ResetFilters")
        }
    }

    private func clearFilters() {
        query = ""; filter = .all; family = nil; quantization = nil
        recommendedOnly = false; measuredOnly = false
    }

    @ViewBuilder private func cell(_ row: Data.Row, _ column: Data.Column) -> some View {
        switch column {
        case .model:
            HStack(spacing: 7) {
                Button { favorite(row.entry) } label: {
                    Image(systemName: row.favorite ? "star.fill" : "star")
                        .foregroundStyle(row.favorite ? RapidTheme.brand : RapidTheme.textSecondary)
                }.buttonStyle(.plain)
                    .accessibilityLabel(text("收藏 \(row.id)", "Favorite \(row.id)"))
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.id).font(fonts.font(13.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 4) {
                        if let rank = row.recommendationRank {
                            Label(rank == 0 ? text("首选推荐", "Best pick") : text("速度优选", "Faster"), systemImage: "pin.fill")
                                .foregroundStyle(RapidTheme.brand)
                        } else { Text(row.family).foregroundStyle(.secondary) }
                        if row.entry.isExternal { Text(text("外部文件", "External")).foregroundStyle(.secondary) }
                    }.font(fonts.font(11.5)).lineLimit(1)
                }
            }.help([row.id, row.entry.hfRepo ?? ""].joined(separator: "\n"))
                .accessibilityIdentifier("Settings.ModelManagement.Row.\(row.id)")
        case .downloaded: status(row)
        case .actions: actions(row)
        case .size:
            if let bytes = row.sizeBytes {
                Text((row.estimatedSize ? "≈ " : "") + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
                    .monospacedDigit().lineLimit(1)
                    .help(row.estimatedSize ? text("根据参数与量化估算的权重大小，不含运行时内存。", "Estimated weight bytes from parameters and quantization, not runtime memory.") : text("磁盘文件大小", "Measured file size on disk"))
            } else { unknown }
        case .parameters: metric(row.parameters, suffix: "B")
        case .quantization: metric(row.quantization, suffix: " bit")
        case .accuracy:
            metric(row.metrics.accuracy, suffix: "%")
                .help(row.metrics.accuracySource ?? text("暂无通识与推理准确度数据", "No general/reasoning accuracy recorded"))
        case .quality:
            metric(row.metrics.quality, suffix: "%")
                .help(text("四项等权平均：通识推理、代码、工具调用、指令遵循；已有 \(row.metrics.qualityCoverage)/4 项，缺项不计算。", "Equal mean of reasoning, code, tools and instruction following; \(row.metrics.qualityCoverage)/4 recorded, incomplete rows are not scored."))
        case .speed:
            metric(row.metrics.speed, suffix: " tok/s")
                .help(row.metrics.speedSource ?? text("暂无已记录的测速；不是本机实时测速", "No recorded speed benchmark; not a live measurement"))
        case .value:
            metric(row.metrics.value, suffix: "")
                .foregroundStyle(row.metrics.value == nil ? RapidTheme.textSecondary : RapidTheme.brand)
                .help(text("速质指数 = 综合质量 ÷ 100 × tok/s。非金钱性价比；不同硬件/测试条件仅供参考。", "Q×S = quality / 100 × tok/s. Not monetary value; hardware/workload differences make this indicative only."))
        }
    }

    private var unknown: some View {
        Text("—").foregroundStyle(.secondary).accessibilityLabel(text("暂无数据", "Not recorded"))
    }
    @ViewBuilder private func metric(_ value: Double?, suffix: String) -> some View {
        if let value { Text(number(value) + suffix).monospacedDigit().lineLimit(1) }
        else { unknown }
    }
    private func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1)))
    }

    @ViewBuilder private func status(_ row: Data.Row) -> some View {
        if row.loading {
            Label(text("加载中", "Loading"), systemImage: "hourglass").foregroundStyle(.orange)
        } else if row.loaded {
            Label(text("已加载", "Loaded"), systemImage: "checkmark.circle.fill").foregroundStyle(RapidTheme.statusReady)
        } else if case .downloading(let percent) = row.badge {
            VStack(alignment: .leading, spacing: 3) {
                Text(text("下载中", "Downloading") + (percent.map { " \($0)%" } ?? ""))
                if let percent { ProgressView(value: Double(percent), total: 100) }
                else { ProgressView().controlSize(.mini) }
            }.font(fonts.font(11.5))
        } else if row.entry.cached {
            Label(text("已下载", "Downloaded"), systemImage: "internaldrive").foregroundStyle(.secondary)
        } else if row.failed {
            Label(text("下载失败", "Failed"), systemImage: "exclamationmark.circle").foregroundStyle(RapidTheme.statusError)
        } else { Text(text("未下载", "Not downloaded")).foregroundStyle(.secondary) }
    }

    private func actions(_ row: Data.Row) -> some View {
        HStack(spacing: 7) {
            if row.downloading {
                Button(text("取消", "Cancel")) { cancel(row.entry) }
            } else if row.canDownload {
                Button(text(row.failed ? "重试下载" : "下载", row.failed ? "Retry" : "Download")) { download(row.entry) }
                    .accessibilityIdentifier("Settings.ModelManagement.Download.\(row.id)")
            } else {
                Button(text(row.loading ? "加载中…" : (row.loaded ? "已加载" : "加载"), row.loading ? "Loading…" : (row.loaded ? "Loaded" : "Load"))) { load(row.entry) }
                    .disabled(!row.canLoad)
                    .accessibilityIdentifier("Settings.ModelManagement.Load.\(row.id)")
            }
            Button(role: .destructive) { delete(row.entry) } label: { Image(systemName: "trash") }
                .disabled(!row.canDelete)
                .help(text(row.entry.isExternal ? "外部模型文件不由柚子删除" : (row.loaded || row.loading ? "请先停止该模型，再删除文件" : "删除模型文件（需确认）"), row.entry.isExternal ? "External files cannot be deleted by Youzi" : (row.loaded || row.loading ? "Stop the model before deleting files" : "Delete model files (confirmation required)")))
                .accessibilityLabel(text("删除 \(row.id)", "Delete \(row.id)"))
                .accessibilityIdentifier("Settings.ModelManagement.Delete.\(row.id)")
        }.buttonStyle(.bordered).controlSize(.small).lineLimit(1)
    }

    private var methodology: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text("指标与性价比", "Metrics & value")).font(fonts.font(13.5, weight: .medium))
            Text(text("准确度：现有通识推理基准（来源随行显示）。综合质量：通识推理、代码、工具、指令遵循四项百分制得分的等权平均；缺项不计算。", "Accuracy uses the recorded reasoning benchmark. Quality is the equal mean of four 0–100 axes: reasoning, code, tools and instructions. Incomplete rows are not scored."))
            Text(text("速质指数 = 综合质量 ÷ 100 × tokens/s。越高表示质量与速度组合越好，不代表金钱或内存性价比，也不是本机性能预测。悬停速度可查看硬件和测试来源，不同条件的数据仅供参考。", "Q×S = quality / 100 × tokens/s. Higher indicates a better quality–speed combination, not financial/memory efficiency or predicted local performance. Hover speed for hardware and benchmark provenance; different conditions are indicative only."))
            Text(text("— 表示未收录或不适用；≈ 表示估算文件大小。参数和量化仅取模型标识中的明确值。图片、语音、视频不会套用聊天指标。", "— means missing or not applicable; ≈ marks estimated file size. Parameters/quantization require explicit model identifiers. Chat metrics are not assigned to image, audio or video models."))
        }.font(fonts.font(12.5)).fixedSize(horizontal: false, vertical: true)
    }
}
