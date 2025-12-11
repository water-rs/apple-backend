// WuiList.swift
// List component - scrollable collection of items with optional delete support
//
// # Layout Behavior
// List is greedy - it expands to fill all available space.
// Items are rendered as rows in a scrollable list.
// Supports swipe-to-delete when items have delete handlers.

import CWaterUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit)
@MainActor
final class WuiList: UITableView, WuiComponent, UITableViewDataSource, UITableViewDelegate {
    static var rawId: CWaterUI.WuiTypeId { waterui_list_id() }

    private(set) var stretchAxis: WuiStretchAxis = .both

    private let env: WuiEnvironment
    private var contentsHandle: OpaquePointer?
    private var itemViews: [(id: Int, view: WuiAnyView)] = []

    // MARK: - WuiComponent Init

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
        let ffiList: CWaterUI.WuiList = waterui_force_as_list(anyview)
        self.init(ffiList: ffiList, env: env)
    }

    // MARK: - Designated Init

    init(ffiList: CWaterUI.WuiList, env: WuiEnvironment) {
        self.env = env
        self.contentsHandle = ffiList.contents
        super.init(frame: .zero, style: .plain)

        dataSource = self
        delegate = self

        // Register a reusable cell class
        register(WuiListCell.self, forCellReuseIdentifier: WuiListCell.reuseIdentifier)

        // Allow cells to size themselves
        rowHeight = UITableView.automaticDimension
        estimatedRowHeight = 44

        // Load items
        loadItems()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Item Loading

    private func loadItems() {
        guard let handle = contentsHandle else { return }

        let count = waterui_anyviews_len(handle)
        itemViews.removeAll()

        for i in 0..<count {
            let id = waterui_anyviews_get_id(handle, i)
            guard let viewPtr = waterui_anyviews_get_view(handle, i) else { continue }

            // Get the ListItem and extract its content
            let listItem = waterui_force_as_list_item(viewPtr)
            guard let contentPtr = listItem.content else { continue }

            let contentView = WuiAnyView(anyview: contentPtr, env: env)
            itemViews.append((id: Int(id.inner), view: contentView))
        }

        reloadData()
    }

    // MARK: - WuiComponent

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        let width = proposal.width.map { CGFloat($0) } ?? UIScreen.main.bounds.width
        let height = proposal.height.map { CGFloat($0) } ?? UIScreen.main.bounds.height
        return CGSize(width: width, height: height)
    }

    // MARK: - UITableViewDataSource

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return itemViews.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: WuiListCell.reuseIdentifier, for: indexPath) as! WuiListCell
        let item = itemViews[indexPath.row]
        cell.configure(with: item.view)
        return cell
    }

    // MARK: - UITableViewDelegate

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return UITableView.automaticDimension
    }
}

// MARK: - WuiListCell

private final class WuiListCell: UITableViewCell {
    static let reuseIdentifier = "WuiListCell"

    private var contentWuiView: WuiAnyView?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with view: WuiAnyView) {
        // Remove previous content
        contentWuiView?.removeFromSuperview()

        // Add new content
        contentWuiView = view
        view.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(view)

        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            view.topAnchor.constraint(equalTo: contentView.topAnchor),
            view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        contentWuiView?.removeFromSuperview()
        contentWuiView = nil
    }
}
#endif

#if canImport(AppKit)
@MainActor
final class WuiList: NSScrollView, WuiComponent, NSTableViewDataSource, NSTableViewDelegate {
    static var rawId: CWaterUI.WuiTypeId { waterui_list_id() }

    private(set) var stretchAxis: WuiStretchAxis = .both

    private let env: WuiEnvironment
    private var contentsHandle: OpaquePointer?
    private var itemViews: [(id: Int, view: WuiAnyView)] = []
    private let tableView: NSTableView

    // MARK: - WuiComponent Init

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
        let ffiList: CWaterUI.WuiList = waterui_force_as_list(anyview)
        self.init(ffiList: ffiList, env: env)
    }

    // MARK: - Designated Init

    init(ffiList: CWaterUI.WuiList, env: WuiEnvironment) {
        self.env = env
        self.contentsHandle = ffiList.contents
        self.tableView = NSTableView()

        super.init(frame: .zero)

        // Configure table view to look like SwiftUI List
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("content"))
        column.width = 200
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 44
        tableView.usesAutomaticRowHeights = true
        tableView.style = .inset
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular

        // Configure scroll view
        documentView = tableView
        hasVerticalScroller = true
        autohidesScrollers = true
        drawsBackground = false

        // Load items
        loadItems()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Item Loading

    private func loadItems() {
        guard let handle = contentsHandle else { return }

        let count = waterui_anyviews_len(handle)
        itemViews.removeAll()

        for i in 0..<count {
            let id = waterui_anyviews_get_id(handle, i)
            guard let viewPtr = waterui_anyviews_get_view(handle, i) else { continue }

            // Get the ListItem and extract its content
            let listItem = waterui_force_as_list_item(viewPtr)
            guard let contentPtr = listItem.content else { continue }

            let contentView = WuiAnyView(anyview: contentPtr, env: env)
            itemViews.append((id: Int(id.inner), view: contentView))
        }

        tableView.reloadData()
    }

    // MARK: - WuiComponent

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let screenSize = screen?.frame.size ?? CGSize(width: 800, height: 600)
        let width = proposal.width.map { CGFloat($0) } ?? screenSize.width
        let height = proposal.height.map { CGFloat($0) } ?? screenSize.height
        return CGSize(width: width, height: height)
    }

    override var isFlipped: Bool { true }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        return itemViews.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = itemViews[row]
        let cellView = NSTableCellView()

        item.view.translatesAutoresizingMaskIntoConstraints = false
        cellView.addSubview(item.view)

        NSLayoutConstraint.activate([
            item.view.leadingAnchor.constraint(equalTo: cellView.leadingAnchor),
            item.view.trailingAnchor.constraint(equalTo: cellView.trailingAnchor),
            item.view.topAnchor.constraint(equalTo: cellView.topAnchor),
            item.view.bottomAnchor.constraint(equalTo: cellView.bottomAnchor)
        ])

        return cellView
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = NSTableRowView()
        rowView.isEmphasized = true
        return rowView
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let item = itemViews[row]
        let size = item.view.sizeThatFits(WuiProposalSize(width: Float(tableView.bounds.width), height: nil))
        return max(size.height, 44)
    }
}
#endif
