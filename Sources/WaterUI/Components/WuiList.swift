// WuiList.swift
// List component - scrollable collection of items with optional delete support
//
// # Layout Behavior
// List is greedy - it expands to fill all available space.
// Items are rendered as rows in a scrollable list.
// Supports swipe-to-delete when items have delete handlers.

import CWaterUI
import OSLog

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

private let logger = Logger(subsystem: "dev.waterui", category: "WuiList")

/// Data for a single list item including its content and deletable state.
private struct ListItemData {
    let id: Int
    let view: WuiAnyView
    let deletable: WuiComputed<Bool>?
    var deletableWatcher: WatcherGuard?
}

#if canImport(UIKit)
@MainActor
final class WuiList: UITableView, WuiComponent, UITableViewDataSource, UITableViewDelegate {
    static var rawId: CWaterUI.WuiTypeId { waterui_list_id() }

    private(set) var stretchAxis: WuiStretchAxis = .both

    private let env: WuiEnvironment
    private var contentsHandle: OpaquePointer?
    private var itemViews: [ListItemData] = []

    // Edit mode state
    private var editingComputed: WuiComputed<Bool>?
    private var editingWatcher: WatcherGuard?

    // Callbacks
    private var onDeletePtr: OpaquePointer?
    private var onMovePtr: OpaquePointer?

    // Track pending deletions to avoid double-animation
    private var pendingDeletions: Set<Int> = []

    // MARK: - WuiComponent Init

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
        let ffiList: CWaterUI.WuiList = waterui_force_as_list(anyview)
        self.init(ffiList: ffiList, env: env)
    }

    // MARK: - Designated Init

    init(ffiList: CWaterUI.WuiList, env: WuiEnvironment) {
        self.env = env
        self.contentsHandle = ffiList.contents
        self.onDeletePtr = ffiList.on_delete
        self.onMovePtr = ffiList.on_move
        super.init(frame: .zero, style: .plain)

        dataSource = self
        delegate = self

        // Register a reusable cell class
        register(WuiListCell.self, forCellReuseIdentifier: WuiListCell.reuseIdentifier)

        // Allow cells to size themselves
        rowHeight = UITableView.automaticDimension
        estimatedRowHeight = 44

        // Setup editing state if provided
        if let editingPtr = ffiList.editing {
            editingComputed = WuiComputed<Bool>(editingPtr)
            editingWatcher = editingComputed?.watch { [weak self] newValue, metadata in
                guard let self = self else { return }
                let animated = metadata.animation != nil
                self.setEditing(newValue, animated: animated)
            }
            // Apply initial editing state
            if let isEditing = editingComputed?.value {
                setEditing(isEditing, animated: false)
            }
        }

        // Load items
        loadItems()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @MainActor deinit {
        // Drop action pointers if they exist
        if let ptr = onDeletePtr {
            waterui_drop_index_action(ptr)
        }
        if let ptr = onMovePtr {
            waterui_drop_move_action(ptr)
        }
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

            // Create deletable computed if pointer exists
            var deletableComputed: WuiComputed<Bool>? = nil
            if let deletablePtr = listItem.deletable {
                deletableComputed = WuiComputed<Bool>(deletablePtr)
            }

            var itemData = ListItemData(
                id: Int(id.inner),
                view: contentView,
                deletable: deletableComputed,
                deletableWatcher: nil
            )

            // Watch for deletable changes
            let itemIndex = itemViews.count
            itemData.deletableWatcher = deletableComputed?.watch { [weak self] _, _ in
                guard let self = self else { return }
                // Reload the specific row when deletable state changes
                if itemIndex < self.itemViews.count {
                    self.reloadRows(at: [IndexPath(row: itemIndex, section: 0)], with: .automatic)
                }
            }

            itemViews.append(itemData)
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

    // MARK: - Editing Support

    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        // Can edit if we have a delete callback and the item is deletable
        guard onDeletePtr != nil else { return false }
        let item = itemViews[indexPath.row]
        return item.deletable?.value ?? true
    }

    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        if editingStyle == .delete {
            let itemId = itemViews[indexPath.row].id
            pendingDeletions.insert(itemId)

            // Remove from local array first (optimistic)
            itemViews.remove(at: indexPath.row)
            tableView.deleteRows(at: [indexPath], with: .automatic)

            // Then call Rust callback
            if let deletePtr = onDeletePtr {
                waterui_call_index_action(deletePtr, env.inner, UInt(indexPath.row))
            }
        }
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard onDeletePtr != nil else { return nil }
        let item = itemViews[indexPath.row]
        guard item.deletable?.value ?? true else { return nil }

        let deleteAction = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, completion in
            guard let self = self else {
                completion(false)
                return
            }

            let itemId = self.itemViews[indexPath.row].id
            self.pendingDeletions.insert(itemId)

            // Remove from local array first (optimistic)
            self.itemViews.remove(at: indexPath.row)
            self.deleteRows(at: [indexPath], with: .automatic)

            // Then call Rust callback
            if let deletePtr = self.onDeletePtr {
                waterui_call_index_action(deletePtr, self.env.inner, UInt(indexPath.row))
            }

            completion(true)
        }

        return UISwipeActionsConfiguration(actions: [deleteAction])
    }

    // MARK: - Move/Reorder Support

    func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        return onMovePtr != nil
    }

    func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        // Update local array
        let item = itemViews.remove(at: sourceIndexPath.row)
        itemViews.insert(item, at: destinationIndexPath.row)

        // Call Rust callback
        if let movePtr = onMovePtr {
            waterui_call_move_action(movePtr, env.inner, UInt(sourceIndexPath.row), UInt(destinationIndexPath.row))
        }
    }

    func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
        // Show delete button in edit mode only if item is deletable
        guard onDeletePtr != nil else { return .none }
        let item = itemViews[indexPath.row]
        return (item.deletable?.value ?? true) ? .delete : .none
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
    private var itemViews: [ListItemData] = []
    private let tableView: NSTableView

    // Edit mode state
    private var editingComputed: WuiComputed<Bool>?
    private var editingWatcher: WatcherGuard?
    private var isInEditMode: Bool = false

    // Callbacks
    private var onDeletePtr: OpaquePointer?
    private var onMovePtr: OpaquePointer?

    // Pasteboard type for drag-and-drop
    private static let dragType = NSPasteboard.PasteboardType("dev.waterui.listitem")

    // MARK: - WuiComponent Init

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
        let ffiList: CWaterUI.WuiList = waterui_force_as_list(anyview)
        self.init(ffiList: ffiList, env: env)
    }

    // MARK: - Designated Init

    init(ffiList: CWaterUI.WuiList, env: WuiEnvironment) {
        self.env = env
        self.contentsHandle = ffiList.contents
        self.onDeletePtr = ffiList.on_delete
        self.onMovePtr = ffiList.on_move
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

        // Enable drag-and-drop if move callback exists
        if onMovePtr != nil {
            tableView.registerForDraggedTypes([Self.dragType])
            tableView.draggingDestinationFeedbackStyle = .gap
        }

        // Configure scroll view
        documentView = tableView
        hasVerticalScroller = true
        autohidesScrollers = true
        drawsBackground = false

        // Setup editing state if provided
        if let editingPtr = ffiList.editing {
            editingComputed = WuiComputed<Bool>(editingPtr)
            editingWatcher = editingComputed?.watch { [weak self] newValue, _ in
                guard let self = self else { return }
                self.isInEditMode = newValue
                self.tableView.reloadData()
            }
            // Apply initial editing state
            if let isEditing = editingComputed?.value {
                isInEditMode = isEditing
            }
        }

        // Load items
        loadItems()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @MainActor deinit {
        // Drop action pointers if they exist
        if let ptr = onDeletePtr {
            waterui_drop_index_action(ptr)
        }
        if let ptr = onMovePtr {
            waterui_drop_move_action(ptr)
        }
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

            // Create deletable computed if pointer exists
            var deletableComputed: WuiComputed<Bool>? = nil
            if let deletablePtr = listItem.deletable {
                deletableComputed = WuiComputed<Bool>(deletablePtr)
            }

            var itemData = ListItemData(
                id: Int(id.inner),
                view: contentView,
                deletable: deletableComputed,
                deletableWatcher: nil
            )

            // Watch for deletable changes
            let itemIndex = itemViews.count
            itemData.deletableWatcher = deletableComputed?.watch { [weak self] _, _ in
                guard let self = self else { return }
                // Reload the specific row when deletable state changes
                if itemIndex < self.itemViews.count {
                    self.tableView.reloadData(forRowIndexes: IndexSet(integer: itemIndex), columnIndexes: IndexSet(integer: 0))
                }
            }

            itemViews.append(itemData)
        }

        tableView.reloadData()
    }

    // MARK: - Delete Action

    private func deleteItem(at row: Int) {
        guard row >= 0, row < itemViews.count else { return }
        guard let deletePtr = onDeletePtr else { return }
        let item = itemViews[row]
        guard item.deletable?.value ?? true else { return }

        // Remove from local array first (optimistic)
        itemViews.remove(at: row)
        tableView.removeRows(at: IndexSet(integer: row), withAnimation: .slideUp)

        // Then call Rust callback
        waterui_call_index_action(deletePtr, env.inner, UInt(row))
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

    // MARK: - Drag and Drop

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard onMovePtr != nil else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.dragType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        if dropOperation == .above {
            return .move
        }
        return []
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let items = info.draggingPasteboard.pasteboardItems,
              let item = items.first,
              let rowStr = item.string(forType: Self.dragType),
              let sourceRow = Int(rowStr) else {
            return false
        }

        var destinationRow = row
        if sourceRow < destinationRow {
            destinationRow -= 1
        }

        // Update local array
        let movedItem = itemViews.remove(at: sourceRow)
        itemViews.insert(movedItem, at: destinationRow)

        // Animate the move
        tableView.moveRow(at: sourceRow, to: destinationRow)

        // Call Rust callback
        if let movePtr = onMovePtr {
            waterui_call_move_action(movePtr, env.inner, UInt(sourceRow), UInt(destinationRow))
        }

        return true
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = itemViews[row]

        // Create container view
        let containerView = NSView()
        containerView.translatesAutoresizingMaskIntoConstraints = false

        // Add content view
        item.view.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(item.view)

        // Add delete button in edit mode
        if isInEditMode, onDeletePtr != nil, item.deletable?.value ?? true {
            let deleteButton = NSButton(title: "Delete", target: self, action: #selector(deleteButtonClicked(_:)))
            deleteButton.bezelStyle = .inline
            deleteButton.tag = row
            deleteButton.translatesAutoresizingMaskIntoConstraints = false
            containerView.addSubview(deleteButton)

            NSLayoutConstraint.activate([
                item.view.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
                item.view.topAnchor.constraint(equalTo: containerView.topAnchor),
                item.view.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),

                deleteButton.leadingAnchor.constraint(equalTo: item.view.trailingAnchor, constant: 8),
                deleteButton.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8),
                deleteButton.centerYAnchor.constraint(equalTo: containerView.centerYAnchor)
            ])
        } else {
            NSLayoutConstraint.activate([
                item.view.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
                item.view.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
                item.view.topAnchor.constraint(equalTo: containerView.topAnchor),
                item.view.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
            ])
        }

        return containerView
    }

    @objc private func deleteButtonClicked(_ sender: NSButton) {
        deleteItem(at: sender.tag)
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
