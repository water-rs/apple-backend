// WuiTable.swift
// Table component - displays data in a grid with column headers
//
// # Layout Behavior
// Table sizes to fit its content - headers and rows.

import CWaterUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Column Data

/// Represents a table column with a header label and rows of content
private struct TableColumnData {
    let label: PlatformView
    let rows: [WuiAnyView]
}

// MARK: - UIKit Implementation

#if canImport(UIKit)
@MainActor
final class WuiTable: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_table_id() }

    private let env: WuiEnvironment
    private var columnsPtr: OpaquePointer?
    private var columns: [TableColumnData] = []
    private var watcher: WatcherGuard?

    // Grid layout - use collection of row stacks for simple grid
    private var allViews: [PlatformView] = []

    // MARK: - WuiComponent Init

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
        let ffiTable: CWaterUI.WuiTable = waterui_force_as_table(anyview)
        self.init(ffiTable: ffiTable, env: env)
    }

    // MARK: - Designated Init

    init(ffiTable: CWaterUI.WuiTable, env: WuiEnvironment) {
        self.env = env
        self.columnsPtr = ffiTable.columns
        super.init(frame: .zero)

        loadColumns()
        startWatching()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Column Loading

    private func loadColumns() {
        guard let ptr = columnsPtr else { return }

        let array = waterui_read_computed_table_cols(ptr)
        let slice = array.vtable.slice(array.data)
        guard let head = slice.head else { return }

        columns.removeAll()

        for i in 0..<Int(slice.len) {
            let col = head.advanced(by: i).pointee
            let column = parseColumn(col)
            columns.append(column)
        }

        rebuildTable()
    }

    private func parseColumn(_ ffiCol: CWaterUI.WuiTableColumn) -> TableColumnData {
        // Parse label (WuiText)
        let labelView = WuiText(content: WuiComputed<WuiStyledStr>(ffiCol.label.content), env: env)

        // Parse rows (WuiAnyViews containing Text views)
        var rows: [WuiAnyView] = []
        if let rowsPtr = ffiCol.rows {
            let count = waterui_anyviews_len(rowsPtr)
            for i in 0..<count {
                if let viewPtr = waterui_anyviews_get_view(rowsPtr, i) {
                    let rowView = WuiAnyView(anyview: viewPtr, env: env)
                    rows.append(rowView)
                }
            }
        }

        return TableColumnData(label: labelView, rows: rows)
    }

    private func rebuildTable() {
        // Clear existing content
        allViews.forEach { $0.removeFromSuperview() }
        allViews.removeAll()

        guard !columns.isEmpty else { return }

        let numCols = columns.count
        let numRows = columns.map { $0.rows.count }.max() ?? 0

        // Calculate column widths based on content
        var columnWidths: [CGFloat] = Array(repeating: 80, count: numCols)

        // Measure headers
        for (colIdx, column) in columns.enumerated() {
            let size = column.label.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: 30))
            columnWidths[colIdx] = max(columnWidths[colIdx], size.width + 16)
        }

        // Measure data cells
        for (colIdx, column) in columns.enumerated() {
            for row in column.rows {
                let size = row.sizeThatFits(WuiProposalSize(width: nil, height: 30))
                columnWidths[colIdx] = max(columnWidths[colIdx], size.width + 16)
            }
        }

        var yOffset: CGFloat = 0
        let rowHeight: CGFloat = 28
        let rowSpacing: CGFloat = 4

        // Build header row
        var xOffset: CGFloat = 0
        for (colIdx, column) in columns.enumerated() {
            let cellWidth = columnWidths[colIdx]
            column.label.frame = CGRect(x: xOffset, y: yOffset, width: cellWidth, height: rowHeight)
            addSubview(column.label)
            allViews.append(column.label)
            xOffset += cellWidth
        }
        yOffset += rowHeight + rowSpacing

        // Build data rows
        for rowIdx in 0..<numRows {
            xOffset = 0
            for (colIdx, column) in columns.enumerated() {
                let cellWidth = columnWidths[colIdx]
                if rowIdx < column.rows.count {
                    let cell = column.rows[rowIdx]
                    cell.frame = CGRect(x: xOffset, y: yOffset, width: cellWidth, height: rowHeight)
                    addSubview(cell)
                    allViews.append(cell)
                }
                xOffset += cellWidth
            }
            yOffset += rowHeight + rowSpacing
        }

        setNeedsLayout()
        layoutIfNeeded()
    }

    // MARK: - Reactive Updates

    private func startWatching() {
        guard let ptr = columnsPtr else { return }

        let watcherPtr = waterui_new_watcher_table_cols(
            Unmanaged.passUnretained(self).toOpaque(),
            { data, array, metadata in
                guard let data = data else { return }
                let table = Unmanaged<WuiTable>.fromOpaque(data).takeUnretainedValue()
                MainActor.assumeIsolated {
                    table.loadColumns()
                }
            },
            nil
        )

        if let watcherPtr = watcherPtr {
            let guardPtr = waterui_watch_computed_table_cols(ptr, watcherPtr)
            if let guardPtr = guardPtr {
                watcher = WatcherGuard(guardPtr)
            }
        }
    }

    // MARK: - WuiComponent

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        guard !columns.isEmpty else { return .zero }

        let numRows = columns.map { $0.rows.count }.max() ?? 0
        let rowHeight: CGFloat = 28
        let rowSpacing: CGFloat = 4

        // Calculate total width
        var totalWidth: CGFloat = 0
        for column in columns {
            var colWidth: CGFloat = 80
            let headerSize = column.label.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: 30))
            colWidth = max(colWidth, headerSize.width + 16)
            for row in column.rows {
                let size = row.sizeThatFits(WuiProposalSize(width: nil, height: 30))
                colWidth = max(colWidth, size.width + 16)
            }
            totalWidth += colWidth
        }

        // Total height = header + data rows
        let totalHeight = (rowHeight + rowSpacing) * CGFloat(numRows + 1)

        return CGSize(width: totalWidth, height: totalHeight)
    }
}
#endif

// MARK: - AppKit Implementation

#if canImport(AppKit)

/// Stores parsed column data for NSTableView - headers as strings, rows as WuiAnyViews
private struct NativeTableColumnData {
    let identifier: NSUserInterfaceItemIdentifier
    let headerTitle: String
    let rows: [WuiAnyView]
}

@MainActor
final class WuiTable: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_table_id() }

    private let env: WuiEnvironment
    private var columnsPtr: OpaquePointer?
    private var nativeColumns: [NativeTableColumnData] = []
    private var watcher: WatcherGuard?

    // Native table view
    private let scrollView: NSScrollView
    private let tableView: NSTableView

    // Keep strong references to cell views
    private var cellViews: [[WuiAnyView]] = []

    // MARK: - WuiComponent Init

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
        let ffiTable: CWaterUI.WuiTable = waterui_force_as_table(anyview)
        self.init(ffiTable: ffiTable, env: env)
    }

    // MARK: - Designated Init

    init(ffiTable: CWaterUI.WuiTable, env: WuiEnvironment) {
        self.env = env
        self.columnsPtr = ffiTable.columns

        // Create table view
        self.tableView = NSTableView()
        tableView.style = .inset
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.gridStyleMask = []  // No grid lines - inset style provides row separation
        tableView.rowHeight = 28
        tableView.intercellSpacing = NSSize(width: 12, height: 6)
        tableView.headerView = NSTableHeaderView()
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.backgroundColor = NSColor.controlBackgroundColor
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = false
        tableView.allowsColumnSelection = false

        // Wrap in scroll view (required for NSTableView header to display)
        self.scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor.controlBackgroundColor

        super.init(frame: .zero)

        addSubview(scrollView)

        // Set data source and delegate
        tableView.dataSource = self
        tableView.delegate = self

        loadColumns()
        startWatching()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Column Loading

    private func loadColumns() {
        guard let ptr = columnsPtr else { return }

        let array = waterui_read_computed_table_cols(ptr)
        let slice = array.vtable.slice(array.data)
        guard let head = slice.head else { return }

        nativeColumns.removeAll()
        cellViews.removeAll()

        for i in 0..<Int(slice.len) {
            let col = head.advanced(by: i).pointee
            let column = parseColumn(col, index: i)
            nativeColumns.append(column)
        }

        rebuildTable()
    }

    private func parseColumn(_ ffiCol: CWaterUI.WuiTableColumn, index: Int) -> NativeTableColumnData {
        // Extract header text from WuiText
        let headerText = extractTextFromLabel(ffiCol.label)

        // Parse rows (WuiAnyViews containing Text views)
        var rows: [WuiAnyView] = []
        if let rowsPtr = ffiCol.rows {
            let count = waterui_anyviews_len(rowsPtr)
            for i in 0..<count {
                if let viewPtr = waterui_anyviews_get_view(rowsPtr, i) {
                    let rowView = WuiAnyView(anyview: viewPtr, env: env)
                    rows.append(rowView)
                }
            }
        }

        let identifier = NSUserInterfaceItemIdentifier("col_\(index)")
        return NativeTableColumnData(identifier: identifier, headerTitle: headerText, rows: rows)
    }

    private func extractTextFromLabel(_ label: CWaterUI.WuiText) -> String {
        // Read styled string from computed pointer
        let computed = WuiComputed<WuiStyledStr>(label.content)
        return computed.value.toString()
    }

    private func rebuildTable() {
        // Remove existing columns
        for column in tableView.tableColumns {
            tableView.removeTableColumn(column)
        }

        guard !nativeColumns.isEmpty else { return }

        // Calculate column widths
        var columnWidths: [CGFloat] = []
        for colData in nativeColumns {
            var maxWidth: CGFloat = 80

            // Measure header
            let headerSize = (colData.headerTitle as NSString).size(withAttributes: [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize)
            ])
            maxWidth = max(maxWidth, headerSize.width + 24)

            // Measure cell content
            for row in colData.rows {
                let size = row.sizeThatFits(WuiProposalSize(width: nil, height: 24))
                maxWidth = max(maxWidth, size.width + 16)
            }

            columnWidths.append(maxWidth)
        }

        // Add columns to table view
        for (index, colData) in nativeColumns.enumerated() {
            let column = NSTableColumn(identifier: colData.identifier)
            column.title = colData.headerTitle
            column.width = columnWidths[index]
            column.minWidth = 50
            column.maxWidth = 500
            tableView.addTableColumn(column)
        }

        // Store cell views for reuse
        cellViews = nativeColumns.map { $0.rows }

        tableView.reloadData()
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        scrollView.frame = bounds
    }

    // MARK: - Reactive Updates

    private func startWatching() {
        guard let ptr = columnsPtr else { return }

        let watcherPtr = waterui_new_watcher_table_cols(
            Unmanaged.passUnretained(self).toOpaque(),
            { data, array, metadata in
                guard let data = data else { return }
                let table = Unmanaged<WuiTable>.fromOpaque(data).takeUnretainedValue()
                MainActor.assumeIsolated {
                    table.loadColumns()
                }
            },
            nil
        )

        if let watcherPtr = watcherPtr {
            let guardPtr = waterui_watch_computed_table_cols(ptr, watcherPtr)
            if let guardPtr = guardPtr {
                watcher = WatcherGuard(guardPtr)
            }
        }
    }

    // MARK: - WuiComponent

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        guard !nativeColumns.isEmpty else { return .zero }

        let numRows = nativeColumns.map { $0.rows.count }.max() ?? 0
        let headerHeight: CGFloat = 24
        let rowHeight: CGFloat = tableView.rowHeight + tableView.intercellSpacing.height

        // Calculate total width
        var totalWidth: CGFloat = 0
        for colData in nativeColumns {
            var colWidth: CGFloat = 80

            let headerSize = (colData.headerTitle as NSString).size(withAttributes: [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize)
            ])
            colWidth = max(colWidth, headerSize.width + 24)

            for row in colData.rows {
                let size = row.sizeThatFits(WuiProposalSize(width: nil, height: 24))
                colWidth = max(colWidth, size.width + 16)
            }
            totalWidth += colWidth
        }

        // Total height = header + data rows
        let totalHeight = headerHeight + rowHeight * CGFloat(numRows) + 8

        return CGSize(width: totalWidth, height: totalHeight)
    }

    override var isFlipped: Bool { true }
}

// MARK: - NSTableViewDataSource

extension WuiTable: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        nativeColumns.first?.rows.count ?? 0
    }
}

// MARK: - NSTableViewDelegate

extension WuiTable: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn = tableColumn else { return nil }

        // Find column index
        guard let colIndex = nativeColumns.firstIndex(where: { $0.identifier == tableColumn.identifier }) else {
            return nil
        }

        let colData = nativeColumns[colIndex]
        guard row < colData.rows.count else { return nil }

        // Return the WuiAnyView as the cell view
        let cellView = colData.rows[row]
        cellView.frame = NSRect(x: 0, y: 0, width: tableColumn.width, height: tableView.rowHeight)
        return cellView
    }
}
#endif
