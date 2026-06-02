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

private struct ResolvedListItem {
    let view: WuiAnyView
    let deletable: WuiComputed<Bool>?
}

private struct ListSectionInfo {
    let label: String?
    let footer: String?
}

@MainActor
private func resolveListItem(
    from contents: WuiAnyViews,
    at index: Int,
    env: WuiEnvironment
) -> ResolvedListItem {
    guard let viewPtr = waterui_anyviews_get_view(contents.ptr, UInt(index)) else {
        fatalError("List item view pointer is null at index \(index)")
    }

    let listItem = waterui_force_as_list_item(viewPtr)
    guard let contentPtr = listItem.content else {
        fatalError("List item content pointer is null at index \(index)")
    }
    // The FFI item carries section_label / section_footer by value. We don't
    // need them here, but they own their byte buffers — wrap them so they
    // get dropped when this scope exits instead of leaking.
    _ = WuiStr(listItem.section_label)
    _ = WuiStr(listItem.section_footer)

    return ResolvedListItem(
        view: WuiAnyView(anyview: contentPtr, env: env),
        deletable: listItem.deletable.map { WuiComputed<Bool>($0) }
    )
}

@MainActor
private func resolveListItemDeletable(
    from contents: WuiAnyViews,
    at index: Int,
    defaultValue: Bool = true
) -> Bool {
    guard let viewPtr = waterui_anyviews_get_view(contents.ptr, UInt(index)) else {
        fatalError("List item view pointer is null at index \(index)")
    }

    let listItem = waterui_force_as_list_item(viewPtr)
    if let contentPtr = listItem.content {
        waterui_drop_anyview(contentPtr)
    }
    _ = WuiStr(listItem.section_label)
    _ = WuiStr(listItem.section_footer)

    guard let deletablePtr = listItem.deletable else {
        return defaultValue
    }

    let deletable = WuiComputed<Bool>(deletablePtr)
    return deletable.value
}

/// Reads only the semantic section info from a list item, dropping the
/// content/deletable references that come back through the FFI struct.
@MainActor
private func peekListItemSection(
    from contents: WuiAnyViews,
    at index: Int
) -> ListSectionInfo? {
    guard let viewPtr = waterui_anyviews_get_view(contents.ptr, UInt(index)) else {
        return nil
    }
    let listItem = waterui_force_as_list_item(viewPtr)
    if let contentPtr = listItem.content {
        waterui_drop_anyview(contentPtr)
    }
    if let deletablePtr = listItem.deletable {
        _ = WuiComputed<Bool>(deletablePtr)
    }

    let labelStr = WuiStr(listItem.section_label).toString()
    let footerStr = WuiStr(listItem.section_footer).toString()

    if labelStr.isEmpty && footerStr.isEmpty {
        return nil
    }
    return ListSectionInfo(
        label: labelStr.isEmpty ? nil : labelStr,
        footer: footerStr.isEmpty ? nil : footerStr,
    )
}

/// Computed grouping derived from the per-item section markers.
///
/// Each entry corresponds to one logical section as expressed by the Rust
/// view tree. `itemIndices` stores the row positions in the flat `itemIds`
/// array that belong to this section, in their original order.
@MainActor
private struct ListSectionGroup {
    let label: String?
    let footer: String?
    let itemIndices: [Int]
}

@MainActor
private func computeListSectionGroups(
    contents: WuiAnyViews,
    count: Int
) -> [ListSectionGroup] {
    var groups: [ListSectionGroup] = []
    var pendingLabel: String? = nil
    var pendingFooter: String? = nil
    var pendingIndices: [Int] = []

    func flush() {
        guard !pendingIndices.isEmpty else { return }
        groups.append(
            ListSectionGroup(
                label: pendingLabel,
                footer: pendingFooter,
                itemIndices: pendingIndices
            )
        )
    }

    for i in 0..<count {
        if let info = peekListItemSection(from: contents, at: i) {
            flush()
            pendingLabel = info.label
            pendingFooter = info.footer
            pendingIndices = [i]
        } else {
            pendingIndices.append(i)
        }
    }
    flush()
    return groups
}

#if canImport(UIKit)
@MainActor
final class WuiList: UITableView, WuiComponent, UITableViewDataSource, UITableViewDelegate {
    static var rawId: CWaterUI.WuiTypeId { waterui_list_id() }

    private(set) var stretchAxis: WuiStretchAxis = .both

    private let env: WuiEnvironment
    private let contents: WuiAnyViews
    private var contentsWatcher: WatcherGuard?
    private var itemIds: [Int32] = []
    private var sectionGroups: [ListSectionGroup] = [
        ListSectionGroup(label: nil, footer: nil, itemIndices: [])
    ]

    // Edit mode state
    private var editingComputed: WuiComputed<Bool>?
    private var editingWatcher: WatcherGuard?

    // Callbacks
    private var onDeletePtr: OpaquePointer?
    private var onMovePtr: OpaquePointer?

    // MARK: - WuiComponent Init

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
        let ffiList: CWaterUI.WuiList = waterui_force_as_list(anyview)
        self.init(ffiList: ffiList, env: env)
    }

    // MARK: - Designated Init

    init(ffiList: CWaterUI.WuiList, env: WuiEnvironment) {
        self.env = env
        self.contents = WuiAnyViews(ffiList.contents)
        self.onDeletePtr = ffiList.on_delete
        self.onMovePtr = ffiList.on_move
        super.init(frame: .zero, style: .insetGrouped)

        dataSource = self
        delegate = self

        // Register a reusable cell class
        register(WuiListCell.self, forCellReuseIdentifier: WuiListCell.reuseIdentifier)

        // Drive row heights through `heightForRowAt` against the measured
        // content (Layout/SubView protocol) instead of relying on
        // `automaticDimension`. The automatic path is unreliable in
        // offscreen captures and also forces Auto Layout to chase its tail
        // when the cell content reports its height through
        // `intrinsicContentSize`. Estimated height is kept low so the table
        // doesn't pre-allocate huge content rects before the real height
        // arrives.
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

        // Initial load + watch structural changes.
        reloadFromRust(animated: false)
        installContentsWatch()
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

    private func installContentsWatch() {
        contentsWatcher = watchAnyViewsIds(contents) { [weak self] ids, metadata in
            guard let self else { return }
            self.applyRustUpdate(ids: ids, metadata: metadata)
        }
    }

    private func reloadFromRust(animated: Bool) {
        updateFromRust(ids: contents.allIds(), animated: animated)
    }

    private func applyRustUpdate(ids: [Int32], metadata: WuiWatcherMetadata) {
        updateFromRust(ids: ids, animated: false)
    }

    private func updateFromRust(ids: [Int32], animated _: Bool) {
        // Sectioned layout invalidates row-position-based diffs (rows can move
        // between sections without their id changing), so always rebuild and
        // reload. Animated reordering can be re-introduced once we track id
        // positions per-section.
        itemIds = ids
        sectionGroups = computeListSectionGroups(contents: contents, count: ids.count)
        if sectionGroups.isEmpty {
            sectionGroups = [ListSectionGroup(label: nil, footer: nil, itemIndices: [])]
        }
        reloadData()
    }

    // Translates a `(section, row)` index path back to the position in the
    // flat `itemIds` array that the Rust side knows about.
    private func flatIndex(for indexPath: IndexPath) -> Int {
        sectionGroups[indexPath.section].itemIndices[indexPath.row]
    }

    private func indexPath(forFlat flat: Int) -> IndexPath? {
        for (sectionIdx, group) in sectionGroups.enumerated() {
            if let row = group.itemIndices.firstIndex(of: flat) {
                return IndexPath(row: row, section: sectionIdx)
            }
        }
        return nil
    }

    // MARK: - WuiComponent

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        let width = proposal.width.map { CGFloat($0) } ?? UIScreen.main.bounds.width
        let height = proposal.height.map { CGFloat($0) } ?? UIScreen.main.bounds.height
        return CGSize(width: width, height: height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
    }

    // MARK: - UITableViewDataSource

    func numberOfSections(in tableView: UITableView) -> Int {
        return sectionGroups.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return sectionGroups[section].itemIndices.count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return sectionGroups[section].label
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        return sectionGroups[section].footer
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let dequeuedCell = tableView.dequeueReusableCell(withIdentifier: WuiListCell.reuseIdentifier, for: indexPath)
        guard let cell = dequeuedCell as? WuiListCell else {
            fatalError("Expected WuiListCell for reuse identifier \(WuiListCell.reuseIdentifier)")
        }
        let flat = flatIndex(for: indexPath)
        let item = resolveListItem(from: contents, at: flat, env: env)
        let itemId = itemIds[flat]
        cell.configure(with: item.view, deletable: item.deletable) { [weak self] metadata in
            guard let self else { return }
            guard let updatedFlat = self.itemIds.firstIndex(of: itemId),
                  let updatedPath = self.indexPath(forFlat: updatedFlat) else { return }
            self.reloadRows(
                at: [updatedPath],
                with: metadata.animation != nil ? .automatic : .none
            )
        }
        return cell
    }

    // MARK: - Editing Support

    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        // Can edit if we have a delete callback and the item is deletable
        guard onDeletePtr != nil else { return false }
        return resolveListItemDeletable(from: contents, at: flatIndex(for: indexPath))
    }

    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        if editingStyle == .delete {
            let flat = flatIndex(for: indexPath)
            itemIds.remove(at: flat)
            sectionGroups = computeListSectionGroups(contents: contents, count: itemIds.count)
            tableView.reloadData()

            if let deletePtr = onDeletePtr {
                waterui_call_index_action(deletePtr, env.inner, UInt(flat))
            }
        }
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard onDeletePtr != nil else { return nil }
        let flat = flatIndex(for: indexPath)
        guard resolveListItemDeletable(from: contents, at: flat) else { return nil }

        let deleteAction = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, completion in
            guard let self = self else {
                completion(false)
                return
            }

            self.itemIds.remove(at: flat)
            self.sectionGroups = computeListSectionGroups(contents: self.contents, count: self.itemIds.count)
            self.reloadData()

            if let deletePtr = self.onDeletePtr {
                waterui_call_index_action(deletePtr, self.env.inner, UInt(flat))
            }

            completion(true)
        }

        return UISwipeActionsConfiguration(actions: [deleteAction])
    }

    // MARK: - Move/Reorder Support
    //
    // Reorder is intentionally not section-aware yet: a sectioned List with
    // dynamic items would need to re-derive each item's section after the
    // move, which the current Rust API does not let us express. Disable the
    // move affordance whenever the list is showing more than one section so
    // users can't drag rows into a state the framework cannot represent.

    func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        return onMovePtr != nil && sectionGroups.count == 1
    }

    func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        let from = flatIndex(for: sourceIndexPath)
        let to = flatIndex(for: destinationIndexPath)
        let id = itemIds.remove(at: from)
        itemIds.insert(id, at: to)
        sectionGroups = computeListSectionGroups(contents: contents, count: itemIds.count)

        if let movePtr = onMovePtr {
            waterui_call_move_action(movePtr, env.inner, UInt(from), UInt(to))
        }
    }

    func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
        // Show delete button in edit mode only if item is deletable
        guard onDeletePtr != nil else { return .none }
        return resolveListItemDeletable(from: contents, at: flatIndex(for: indexPath)) ? .delete : .none
    }

    // MARK: - UITableViewDelegate

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        let flat = flatIndex(for: indexPath)
        let item = resolveListItem(from: contents, at: flat, env: env)
        let width = tableView.bounds.width
        let proposal = WuiProposalSize(
            width: width > 0 ? Float(width) : nil,
            height: nil
        )
        let size = item.view.sizeThatFits(proposal)
        // Apple's inset-grouped table style uses a 44pt minimum touch
        // target — keep that floor when the measured content is shorter
        // (single-line rows, dividers, etc).
        return max(size.height, 44)
    }
}

// MARK: - WuiListCell

private final class WuiListCell: UITableViewCell {
    static let reuseIdentifier = "WuiListCell"

    private var contentWuiView: WuiAnyView?
    private var deletableWatcher: WatcherGuard?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        with view: WuiAnyView,
        deletable: WuiComputed<Bool>?,
        onDeletableChange: @escaping (WuiWatcherMetadata) -> Void
    ) {
        // Remove previous content
        contentWuiView?.removeFromSuperview()
        deletableWatcher = nil

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

        deletableWatcher = deletable?.watch { _, metadata in
            onDeletableChange(metadata)
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        contentWuiView?.removeFromSuperview()
        contentWuiView = nil
        deletableWatcher = nil
    }
}
#endif

#if canImport(AppKit)
private final class WuiListRowContainerView: NSView {
    private var contentWuiView: WuiAnyView?
    private var deleteButton: NSButton?
    private var deletableWatcher: WatcherGuard?

    func configure(
        with view: WuiAnyView,
        itemId: Int32,
        deletable: WuiComputed<Bool>?,
        showsDeleteControl: Bool,
        target: AnyObject?,
        action: Selector?,
        onDeletableChange: @escaping (WuiWatcherMetadata) -> Void
    ) {
        contentWuiView?.removeFromSuperview()
        deleteButton?.removeFromSuperview()
        deletableWatcher = nil

        contentWuiView = view
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)

        if showsDeleteControl, deletable?.value ?? true {
            let button = NSButton(title: "Delete", target: target, action: action)
            button.bezelStyle = .inline
            button.identifier = NSUserInterfaceItemIdentifier(String(itemId))
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
            deleteButton = button

            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),

                button.leadingAnchor.constraint(equalTo: view.trailingAnchor, constant: 8),
                button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                button.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
        } else {
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor),
                view.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }

        deletableWatcher = deletable?.watch { _, metadata in
            onDeletableChange(metadata)
        }
    }
}

@MainActor
final class WuiList: NSScrollView, WuiComponent, NSTableViewDataSource, NSTableViewDelegate {
    static var rawId: CWaterUI.WuiTypeId { waterui_list_id() }

    private(set) var stretchAxis: WuiStretchAxis = .both

    private let env: WuiEnvironment
    private let contents: WuiAnyViews
    private var contentsWatcher: WatcherGuard?
    private var itemIds: [Int32] = []
    private var sectionGroups: [ListSectionGroup] = []
    /// Linearized presentation: each entry is either a section header (group
    /// row in NSTableView terminology), a content row, or a section footer.
    /// `tableView.numberOfRows == flatLayout.count`.
    private var flatLayout: [TableLayoutEntry] = []
    private let tableView: NSTableView
    private var lastColumnWidth: CGFloat = 0

    // Edit mode state
    private var editingComputed: WuiComputed<Bool>?
    private var editingWatcher: WatcherGuard?
    private var isInEditMode: Bool = false

    // Callbacks
    private var onDeletePtr: OpaquePointer?
    private var onMovePtr: OpaquePointer?

    // Pasteboard type for drag-and-drop
    private static let dragType = NSPasteboard.PasteboardType("dev.waterui.listitem")

    private enum TableLayoutEntry {
        case header(label: String, sectionIndex: Int)
        case row(itemIndex: Int)
        case footer(label: String, sectionIndex: Int)
    }

    // MARK: - WuiComponent Init

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
        let ffiList: CWaterUI.WuiList = waterui_force_as_list(anyview)
        self.init(ffiList: ffiList, env: env)
    }

    // MARK: - Designated Init

    init(ffiList: CWaterUI.WuiList, env: WuiEnvironment) {
        self.env = env
        self.contents = WuiAnyViews(ffiList.contents)
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
        // Drive row heights through `heightOfRow` against the measured
        // content (Layout/SubView protocol). `usesAutomaticRowHeights = true`
        // is unreliable in offscreen captures because it tries to derive
        // height from the row view's Auto Layout fitting size, which can
        // pin to a single-line intrinsic when wrapped text hasn't been
        // re-measured at the table width yet.
        tableView.rowHeight = 44
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

        // Initial load + watch structural changes.
        reloadFromRust(animated: false)
        installContentsWatch()
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

    private func installContentsWatch() {
        contentsWatcher = watchAnyViewsIds(contents) { [weak self] ids, metadata in
            guard let self else { return }
            self.applyRustUpdate(ids: ids, metadata: metadata)
        }
    }

    private func applyRustUpdate(ids: [Int32], metadata _: WuiWatcherMetadata) {
        updateFromRust(ids: ids, animated: false)
    }

    private func reloadFromRust(animated: Bool) {
        updateFromRust(ids: contents.allIds(), animated: animated)
    }

    private func updateFromRust(ids: [Int32], animated _: Bool) {
        // Sectioned layout invalidates row-position-based diffs because rows
        // can move between sections without their id changing. Always rebuild
        // and reload until id-aware section diffing is added.
        itemIds = ids
        sectionGroups = computeListSectionGroups(contents: contents, count: ids.count)
        flatLayout = Self.buildFlatLayout(from: sectionGroups)
        tableView.reloadData()
    }

    private static func buildFlatLayout(from groups: [ListSectionGroup]) -> [TableLayoutEntry] {
        var layout: [TableLayoutEntry] = []
        for (sectionIdx, group) in groups.enumerated() {
            if let label = group.label {
                layout.append(.header(label: label, sectionIndex: sectionIdx))
            }
            for itemIndex in group.itemIndices {
                layout.append(.row(itemIndex: itemIndex))
            }
            if let footer = group.footer {
                layout.append(.footer(label: footer, sectionIndex: sectionIdx))
            }
        }
        return layout
    }

    private func itemIndex(forFlatRow flatRow: Int) -> Int? {
        guard flatRow >= 0, flatRow < flatLayout.count else { return nil }
        if case let .row(itemIndex) = flatLayout[flatRow] {
            return itemIndex
        }
        return nil
    }

    private func flatRow(forItemIndex itemIndex: Int) -> Int? {
        for (flat, entry) in flatLayout.enumerated() {
            if case let .row(idx) = entry, idx == itemIndex {
                return flat
            }
        }
        return nil
    }

    // MARK: - Delete Action

    private func deleteItem(at flatRow: Int) {
        guard let itemIndex = itemIndex(forFlatRow: flatRow) else { return }
        guard let deletePtr = onDeletePtr else { return }
        guard resolveListItemDeletable(from: contents, at: itemIndex) else { return }

        itemIds.remove(at: itemIndex)
        sectionGroups = computeListSectionGroups(contents: contents, count: itemIds.count)
        flatLayout = Self.buildFlatLayout(from: sectionGroups)
        tableView.reloadData()

        waterui_call_index_action(deletePtr, env.inner, UInt(itemIndex))
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

    override func layout() {
        super.layout()

        let width = contentView.bounds.width
        guard width > 0, abs(width - lastColumnWidth) > 0.5 else { return }
        lastColumnWidth = width

        guard let column = tableView.tableColumns.first else {
            fatalError("WuiList requires one NSTableColumn")
        }
        column.width = width
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<flatLayout.count))
        tableView.reloadData()
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        return flatLayout.count
    }

    // MARK: - Drag and Drop
    //
    // Drag-to-reorder is intentionally disabled while sections are present.
    // A row dragged across a section boundary would have to acquire/lose its
    // section marker, which the current Rust API cannot express.

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard onMovePtr != nil, sectionGroups.count <= 1 else { return nil }
        guard case .row = flatLayout[row] else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.dragType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard sectionGroups.count <= 1 else { return [] }
        if dropOperation == .above {
            return .move
        }
        return []
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard sectionGroups.count <= 1 else { return false }
        guard let items = info.draggingPasteboard.pasteboardItems,
              let item = items.first,
              let rowStr = item.string(forType: Self.dragType),
              let sourceFlatRow = Int(rowStr),
              let sourceItem = itemIndex(forFlatRow: sourceFlatRow) else {
            return false
        }

        var destinationItem = row
        if sourceFlatRow < destinationItem {
            destinationItem -= 1
        }

        let movedId = itemIds.remove(at: sourceItem)
        itemIds.insert(movedId, at: destinationItem)
        sectionGroups = computeListSectionGroups(contents: contents, count: itemIds.count)
        flatLayout = Self.buildFlatLayout(from: sectionGroups)
        tableView.reloadData()

        if let movePtr = onMovePtr {
            waterui_call_move_action(movePtr, env.inner, UInt(sourceItem), UInt(destinationItem))
        }

        return true
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < flatLayout.count else { return nil }
        switch flatLayout[row] {
        case let .header(label, _):
            return WuiListSectionHeaderView(text: label, kind: .header)
        case let .footer(label, _):
            return WuiListSectionHeaderView(text: label, kind: .footer)
        case let .row(itemIndex):
            let item = resolveListItem(from: contents, at: itemIndex, env: env)
            let itemId = itemIds[itemIndex]
            let containerView = WuiListRowContainerView()
            containerView.translatesAutoresizingMaskIntoConstraints = true
            containerView.configure(
                with: item.view,
                itemId: itemId,
                deletable: item.deletable,
                showsDeleteControl: isInEditMode && onDeletePtr != nil,
                target: self,
                action: #selector(deleteButtonClicked(_:))
            ) { [weak self] _ in
                guard let self else { return }
                guard let reloadItemIndex = self.itemIds.firstIndex(of: itemId),
                      let reloadFlat = self.flatRow(forItemIndex: reloadItemIndex) else { return }
                self.tableView.reloadData(
                    forRowIndexes: IndexSet(integer: reloadFlat),
                    columnIndexes: IndexSet(integer: 0)
                )
            }
            return containerView
        }
    }

    @objc private func deleteButtonClicked(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let id = Int32(raw),
              let itemIndex = itemIds.firstIndex(of: id),
              let flat = flatRow(forItemIndex: itemIndex) else {
            return
        }
        deleteItem(at: flat)
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = NSTableRowView()
        rowView.isEmphasized = true
        return rowView
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row >= 0, row < flatLayout.count else { return 44 }
        switch flatLayout[row] {
        case .header:
            return 38
        case .footer:
            return 32
        case let .row(itemIndex):
            let item = resolveListItem(from: contents, at: itemIndex, env: env)
            let size = item.view.sizeThatFits(WuiProposalSize(width: Float(tableView.bounds.width), height: nil))
            return max(size.height, 44)
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard row >= 0, row < flatLayout.count else { return false }
        switch flatLayout[row] {
        case .header, .footer: return false
        case .row: return true
        }
    }
}

/// Bold/secondary text view used as section header or footer in the macOS
/// `NSTableView`-based list.
@MainActor
private final class WuiListSectionHeaderView: NSView {
    enum Kind { case header, footer }

    init(text: String, kind: Kind) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = true
        wantsLayer = true

        let label = NSTextField(labelWithString: text.uppercased())
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: topAnchor, constant: kind == .header ? 14 : 6),
            label.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -6),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
#endif
