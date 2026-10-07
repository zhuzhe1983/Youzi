import SwiftUI

/// Viewport budgets, not a prefix of the data: collapsed lists remain scrollable
/// through every item. Expansion removes only the list budget, never the footer.
struct YouziSidebarMetrics {
    let height: CGFloat
    let scale: CGFloat
    var brandHeight: CGFloat { max(44, ceil(24 * scale + 20)) }
    var footerHeight: CGFloat { max(48, ceil(24 * scale + 24)) }
    var gap: CGFloat { RapidTheme.Space.lg }
    var navigationRowHeight: CGFloat { max(34, ceil(18 * scale + 16)) }
    var navigationHeight: CGFloat {
        CGFloat(YouziSimpleDestination.primaryNavigation.count) * navigationRowHeight
            + CGFloat(YouziSimpleDestination.primaryNavigation.count - 1) * rowSpacing
            + RapidTheme.Space.xs * 2
    }
    var listsHeight: CGFloat { max(0, height - brandHeight - footerHeight - 1 - navigationHeight - gap) }
    var headerHeight: CGFloat { max(28, ceil(16 * scale + 12)) }
    var rowHeight: CGFloat { max(32, ceil(18 * scale + 12)) }
    var rowSpacing: CGFloat { RapidTheme.Space.xxs }
    var bodyHeight: CGFloat { max(0, (listsHeight - gap) / 2 - headerHeight) }
    var visibleRows: Int { min(5, max(1, Int((bodyHeight + rowSpacing) / (rowHeight + rowSpacing)))) }
    var listHeight: CGFloat { max(0, CGFloat(visibleRows) * (rowHeight + rowSpacing) - rowSpacing) }
    func listHeight(rowCount: Int) -> CGFloat {
        CGFloat(min(visibleRows, max(1, rowCount))) * (rowHeight + rowSpacing) - rowSpacing
    }
}

/// A sticky section header plus a independently scrolling, bounded list. When
/// expanded, the outer sidebar scroll view owns scrolling and the next section
/// moves down in normal flow. Its pinned header still gives access to Collapse.
struct YouziSidebarSection<Rows: View>: View {
    @Environment(YouziI18nConfig.self) private var i18n
    let title: String
    let id: String
    let metrics: YouziSidebarMetrics
    var rowCount: Int = 5
    @Binding var expanded: Bool
    let onMore: () -> Void
    var bottomSpacing: CGFloat = 0
    @ViewBuilder var rows: () -> Rows

    var body: some View {
        Section {
            Group {
                if expanded {
                    rows()
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    YouziSidebarScrollView { rows() }
                        .frame(height: metrics.listHeight(rowCount: rowCount))
                        .accessibilityIdentifier("\(id).List")
                }
            }
            .padding(.bottom, bottomSpacing)
            .id("\(id).Body.\(expanded)")
        } header: {
            HStack(spacing: 2) {
                Text(title)
                    .font(RapidFont.groupLabel)
                    .foregroundStyle(RapidTheme.textSecondary)
                    .lineLimit(1)
                    .help(title)
                Text("(\(rowCount))")
                    .font(RapidFont.caption)
                    .foregroundStyle(RapidTheme.textTertiary)
                    .accessibilityHidden(true)
                Button { expanded.toggle() } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .frame(width: 24, height: 28)
                }
                .help(i18n.text(zh: expanded ? "收起列表（最多显示五项）" : "展开完整列表", en: expanded ? "Limit list to five visible rows" : "Expand full list"))
                .accessibilityLabel(i18n.text(zh: expanded ? "收起\(title)列表" : "展开\(title)列表", en: expanded ? "Collapse \(title) list" : "Expand \(title) list"))
                .accessibilityValue(expanded ? i18n.text(zh: "已展开", en: "Expanded") : i18n.text(zh: "已折叠", en: "Collapsed"))
                .accessibilityIdentifier("\(id).ExpandToggle")
                Spacer(minLength: 2)
                Button(action: onMore) {
                    Image(systemName: "ellipsis").frame(width: 26, height: 28)
                }
                .help(i18n.text(zh: "查看全部\(title)", en: "View all \(title)"))
                .accessibilityLabel(i18n.text(zh: "查看全部\(title)", en: "View all \(title)"))
                .accessibilityIdentifier("\(id).More")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(RapidTheme.textSecondary)
            .padding(.horizontal, RapidTheme.Space.sm)
            .frame(height: metrics.headerHeight)
            .background(RapidTheme.surfaceSidebar)
            .accessibilityIdentifier("\(id).Header")
        }
    }
}

/// Centers the entire welcome group, including its composer, in the available
/// detail viewport. Short windows fall back to scrolling without clipping input.
struct YouziCenteredWelcome<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                content()
                    .frame(maxWidth: 960)
                    .padding(.horizontal, RapidTheme.Space.xl)
                    .padding(.vertical, RapidTheme.Space.lg)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: proxy.size.height, alignment: .center)
            }
        }
        .accessibilityIdentifier("YouziSimple.Welcome.Viewport")
    }
}
