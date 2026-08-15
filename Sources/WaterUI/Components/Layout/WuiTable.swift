import CWaterUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

@MainActor
private final class WuiTableColumnNode {
  let id: Int32
  let label: WuiText
  let rows: WuiStableViewCollection

  init(
    id: Int32,
    consuming column: CWaterUI.WuiTableColumn,
    env: WuiEnvironment,
    onRowsChange: @escaping (WuiWatcherMetadata) -> Void,
    onContentChange: @escaping () -> Void
  ) {
    guard let rows = column.rows else {
      fatalError("Table column has no rows collection")
    }
    guard let labelContent = column.label.content else {
      fatalError("Table column label has no content signal")
    }
    guard let labelAlignment = column.label.paragraph_alignment else {
      fatalError("Table column label has no paragraph-alignment signal")
    }
    self.id = id
    self.label = WuiText(
      content: WuiComputed<WuiStyledStr>(labelContent),
      paragraphAlignment: WuiComputed<WuiHorizontalAlignment>(labelAlignment),
      env: env
    )
    self.rows = WuiStableViewCollection(
      consuming: rows,
      env: env,
      onChange: onRowsChange
    )
    self.label.onIntrinsicContentChange = onContentChange
  }
}

@MainActor
final class WuiTable: PlatformView, WuiComponent {
  static var rawId: CWaterUI.WuiTypeId { waterui_table_id() }

  private let env: WuiEnvironment
  private let source: WuiAnyViews
  private let collection = WuiStableSemanticCollection<Int32, WuiTableColumnNode>()
  private var columnsWatcher: WatcherGuard?

  private let horizontalPadding: CGFloat = 12
  private let verticalPadding: CGFloat = 6
  private let minimumColumnWidth: CGFloat = 80

  #if canImport(UIKit)
    private var attachedViews: [PlatformView] = []
  #elseif canImport(AppKit)
    private let tableView = NSTableView()
    private var nativeColumns: [Int32: NSTableColumn] = [:]
    private var appKitRowHeights: [CGFloat] = []
  #endif

  private var columns: [WuiTableColumnNode] { collection.ordered }

  convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
    let table = waterui_force_as_table(anyview)
    guard let columns = table.columns else {
      fatalError("WuiTable.columns is null")
    }
    self.init(columns: columns, env: env)
  }

  private init(columns: OpaquePointer, env: WuiEnvironment) {
    self.env = env
    self.source = WuiAnyViews(columns)
    super.init(frame: .zero)

    #if canImport(UIKit)
      clipsToBounds = true
    #elseif canImport(AppKit)
      tableView.style = .inset
      tableView.usesAlternatingRowBackgroundColors = false
      tableView.gridStyleMask = []
      tableView.intercellSpacing = NSSize(width: 0, height: 0)
      tableView.columnAutoresizingStyle = .noColumnAutoresizing
      tableView.backgroundColor = .clear
      tableView.allowsColumnReordering = false
      tableView.allowsColumnResizing = false
      tableView.allowsColumnSelection = false
      tableView.headerView = nil
      tableView.dataSource = self
      tableView.delegate = self
      addSubview(tableView)
    #endif

    columnsWatcher = watchAnyViewsIds(source) { [weak self] ids, metadata in
      guard let self else { return }
      withPlatformAnimation(metadata) {
        self.reconcileColumns(ids: ids)
      }
    }
    reconcileColumns(ids: source.allIds())
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func reconcileColumns(ids: [Int32]) {
    collection.reconcile(ids: ids) { [source, env] index, id in
      let column = waterui_force_as_table_column(source.takeRawView(at: index))
      return WuiTableColumnNode(
        id: id,
        consuming: column,
        env: env,
        onRowsChange: { [weak self] metadata in
          guard let self else { return }
          withPlatformAnimation(metadata) {
            self.reloadContent()
          }
        },
        onContentChange: { [weak self] in
          self?.reloadContent()
        }
      )
    }
    updateColumns()
  }

  private func updateColumns() {
    #if canImport(UIKit)
      updateAttachedViews()
    #elseif canImport(AppKit)
      let activeIds = Set(columns.lazy.map(\.id))
      nativeColumns = nativeColumns.filter { activeIds.contains($0.key) }
      for column in tableView.tableColumns {
        tableView.removeTableColumn(column)
      }
      for column in columns {
        let native =
          nativeColumns[column.id]
          ?? {
            let native = NSTableColumn(
              identifier: NSUserInterfaceItemIdentifier("waterui.table.\(column.id)")
            )
            native.minWidth = minimumColumnWidth
            nativeColumns[column.id] = native
            return native
          }()
        tableView.addTableColumn(native)
        if column.label.superview !== self {
          addSubview(column.label)
        }
      }
      for subview in subviews
      where subview is WuiText && !columns.contains(where: { $0.label === subview }) {
        subview.removeFromSuperview()
      }
    #endif
    reloadContent()
  }

  private func reloadContent() {
    #if canImport(UIKit)
      updateAttachedViews()
      setNeedsLayout()
    #elseif canImport(AppKit)
      appKitRowHeights = rowHeights()
      updateNativeColumnWidths(columnWidths())
      tableView.reloadData()
      needsLayout = true
    #endif
    invalidateIntrinsicContentSize()
    invalidateCapturedRendering()
  }

  #if canImport(UIKit)
    private func updateAttachedViews() {
      var desired: [PlatformView] = columns.map(\.label)
      for column in columns {
        desired.append(contentsOf: column.rows.ordered)
      }
      let desiredIds = Set(desired.lazy.map(ObjectIdentifier.init))
      for view in attachedViews where !desiredIds.contains(ObjectIdentifier(view)) {
        view.removeFromSuperview()
      }
      for view in desired where view.superview !== self {
        addSubview(view)
      }
      attachedViews = desired
    }
  #elseif canImport(AppKit)
    private func updateNativeColumnWidths(_ widths: [CGFloat]) {
      for (column, width) in zip(columns, widths) {
        nativeColumns[column.id]!.width = width
      }
    }
  #endif

  private func columnWidths() -> [CGFloat] {
    columns.map { column in
      var width = max(
        minimumColumnWidth,
        column.label.sizeThatFits(WuiProposalSize()).width + horizontalPadding * 2
      )
      for row in column.rows.ordered {
        width = max(
          width,
          row.sizeThatFits(WuiProposalSize()).width + horizontalPadding * 2
        )
      }
      return width
    }
  }

  private func headerHeight() -> CGFloat {
    guard !columns.isEmpty else { return 0 }
    return max(
      28,
      (columns.map { $0.label.sizeThatFits(WuiProposalSize()).height }.max() ?? 0)
        + verticalPadding * 2
    )
  }

  private func rowHeights() -> [CGFloat] {
    let count = columns.map { $0.rows.ordered.count }.max() ?? 0
    return (0..<count).map { rowIndex in
      max(
        28,
        (columns.compactMap { column in
          column.rows.ordered.indices.contains(rowIndex)
            ? column.rows.ordered[rowIndex].sizeThatFits(WuiProposalSize()).height
            : nil
        }.max() ?? 0) + verticalPadding * 2
      )
    }
  }

  func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
    CGSize(
      width: columnWidths().reduce(0, +),
      height: headerHeight() + rowHeights().reduce(0, +)
    )
  }

  #if canImport(UIKit)
    override func layoutSubviews() {
      super.layoutSubviews()
      let widths = columnWidths()
      let headerHeight = headerHeight()
      let rowHeights = rowHeights()
      var x: CGFloat = 0
      for (index, column) in columns.enumerated() {
        column.label.frame = CGRect(x: x, y: 0, width: widths[index], height: headerHeight)
        x += widths[index]
      }

      var y = headerHeight
      for (rowIndex, rowHeight) in rowHeights.enumerated() {
        x = 0
        for (columnIndex, column) in columns.enumerated() {
          if column.rows.ordered.indices.contains(rowIndex) {
            column.rows.ordered[rowIndex].frame = CGRect(
              x: x + horizontalPadding,
              y: y + verticalPadding,
              width: widths[columnIndex] - horizontalPadding * 2,
              height: rowHeight - verticalPadding * 2
            )
          }
          x += widths[columnIndex]
        }
        y += rowHeight
      }
    }
  #elseif canImport(AppKit)
    override var isFlipped: Bool { true }

    override func layout() {
      super.layout()
      let widths = columnWidths()
      updateNativeColumnWidths(widths)
      let headerHeight = headerHeight()
      tableView.frame = NSRect(
        x: 0,
        y: headerHeight,
        width: bounds.width,
        height: max(0, bounds.height - headerHeight)
      )
      var x: CGFloat = 0
      for (column, width) in zip(columns, widths) {
        column.label.frame = NSRect(x: x, y: 0, width: width, height: headerHeight)
        x += width
      }
    }

  #endif
}

#if canImport(AppKit)
  extension WuiTable: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
      columns.map { $0.rows.ordered.count }.max() ?? 0
    }
  }

  extension WuiTable: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
      appKitRowHeights[row]
    }

    func tableView(
      _ tableView: NSTableView,
      viewFor tableColumn: NSTableColumn?,
      row: Int
    ) -> NSView? {
      let tableColumn = tableColumn!
      let column = columns.first { nativeColumns[$0.id] === tableColumn }!
      guard column.rows.ordered.indices.contains(row) else { return nil }
      return column.rows.ordered[row]
    }
  }
#endif
