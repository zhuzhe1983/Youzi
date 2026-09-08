import AppKit
import SwiftUI

/// A real NSTableView: native column-header sorting, resizing/reordering,
/// keyboard selection and scrolling, rather than a stack of imitation rows.
struct YouziNativeModelTable: NSViewRepresentable {
    typealias Data = YouziModelTableData
    var rows: [Data.Row]
    var chinese: Bool
    var scale: CGFloat
    var colorScheme: ColorScheme = .light
    var sorts: [Data.Sort]
    var onSort: ([Data.Sort]) -> Void
    var cell: (Data.Row, Data.Column) -> AnyView

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = false
        scroll.borderType = .noBorder
        let table = NSTableView()
        table.setAccessibilityIdentifier("Settings.ModelManagement.Table")
        table.usesAlternatingRowBackgroundColors = true
        table.style = .fullWidth
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.allowsColumnResizing = true
        table.allowsColumnReordering = true
        table.allowsMultipleSelection = false
        table.intercellSpacing = NSSize(width: 12, height: 0)
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        for key in Data.Column.allCases {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key.rawValue))
            column.title = key.title(chinese: chinese)
            column.width = Self.width(key, scale: scale)
            column.minWidth = (key == .model ? 170 : (key == .actions ? 142 : 78)) * max(1, scale)
            column.maxWidth = (key == .model ? 600 : 280) * max(1, scale)
            if key != .actions {
                column.sortDescriptorPrototype = NSSortDescriptor(key: key.rawValue, ascending: key == .model)
            }
            table.addTableColumn(column)
        }
        table.sortDescriptors = sorts.map { NSSortDescriptor(key: $0.column.rawValue, ascending: $0.ascending) }
        scroll.documentView = table
        context.coordinator.table = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? NSTableView else { return }
        let previous = context.coordinator.parent
        let selected = table.selectedRow >= 0 && table.selectedRow < previous.rows.count
            ? previous.rows[table.selectedRow].id : nil
        context.coordinator.parent = self
        table.rowHeight = max(52, 52 * scale)
        for column in table.tableColumns {
            guard let key = Data.Column(rawValue: column.identifier.rawValue) else { continue }
            column.title = key.title(chinese: chinese)
            column.headerCell.font = .systemFont(ofSize: 12 * max(1, scale), weight: .medium)
            if scale != previous.scale {
                column.minWidth = (key == .model ? 170 : (key == .actions ? 142 : 78)) * max(1, scale)
                column.maxWidth = (key == .model ? 600 : 280) * max(1, scale)
                column.width = Self.width(key, scale: scale)
            }
        }
        let descriptors = sorts.map { NSSortDescriptor(key: $0.column.rawValue, ascending: $0.ascending) }
        if table.sortDescriptors != descriptors { table.sortDescriptors = descriptors }
        // Don't tear down focused buttons or reset scrolling on the job timer.
        if rows != previous.rows || chinese != previous.chinese || scale != previous.scale
            || colorScheme != previous.colorScheme || table.numberOfRows != rows.count {
            table.reloadData()
            if let selected, let index = rows.firstIndex(where: { $0.id == selected }) {
                table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            } else { table.deselectAll(nil) }
        }
    }

    static func width(_ key: Data.Column, scale: CGFloat) -> CGFloat {
        let base: CGFloat = switch key {
        case .model: 260
        case .downloaded: 118
        case .actions: 158
        case .size: 108
        case .accuracy: 92
        case .quality: 102
        case .speed: 120
        case .parameters: 94
        case .quantization: 100
        case .value: 126
        }
        return base * max(1, scale)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: YouziNativeModelTable
        weak var table: NSTableView?
        init(_ parent: YouziNativeModelTable) { self.parent = parent }
        func numberOfRows(in tableView: NSTableView) -> Int { parent.rows.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard parent.rows.indices.contains(row), let tableColumn,
                  let key = Data.Column(rawValue: tableColumn.identifier.rawValue) else { return nil }
            let content = parent.cell(parent.rows[row], key)
            let id = tableColumn.identifier
            if let host = tableView.makeView(withIdentifier: id, owner: nil) as? NSHostingView<AnyView> {
                host.rootView = content
                return host
            }
            let host = NSHostingView(rootView: content)
            host.identifier = id
            return host
        }
        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            let sorts = tableView.sortDescriptors.compactMap { descriptor -> Data.Sort? in
                guard let key = descriptor.key, let column = Data.Column(rawValue: key) else { return nil }
                return Data.Sort(column: column, ascending: descriptor.ascending)
            }
            guard sorts != parent.sorts else { return }
            parent.onSort(sorts)
        }
    }
}
