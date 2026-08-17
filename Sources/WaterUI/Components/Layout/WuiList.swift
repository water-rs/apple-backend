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

@MainActor
private func resolveListSectionGroups(
  contents: WuiAnyViews,
  count: Int,
  usesSections: Bool
) -> [ListSectionGroup] {
  if usesSections {
    return computeListSectionGroups(contents: contents, count: count)
  }
  return [
    ListSectionGroup(
      label: nil,
      footer: nil,
      itemIndices: Array(0..<count)
    )
  ]
}

/// Whether `groups` is exactly one plain (unlabeled, no-footer) section, i.e. the
/// flat list whose row indices map 1:1 to `itemIds` positions. Only this shape is
/// safe to update with a row-level diff; any header/footer or cross-section move
/// is reloaded instead.
private func isSinglePlainSection(_ groups: [ListSectionGroup]) -> Bool {
  guard groups.count == 1 else { return false }
  let only = groups[0]
  return only.label == nil && only.footer == nil
}

/// Row-level diff between two id orderings for a single plain section. Returns the
/// old-list indices to delete and the new-list indices to insert, or `nil` when a
/// pure insert/delete cannot express the change (duplicate ids, or the ids common
/// to both reordered) — in which case the caller falls back to a full reload.
/// Restricting to the no-reorder case keeps the batch update crash-safe (no move
/// math) while still preserving every surviving row's view, animation, and a11y.
private func singleSectionRowDiff(old: [Int32], new: [Int32])
  -> (deletes: [Int], inserts: [Int])?
{
  var oldIndex: [Int32: Int] = [:]
  for (i, id) in old.enumerated() where oldIndex.updateValue(i, forKey: id) != nil {
    return nil
  }
  var newSet = Set<Int32>()
  for id in new where !newSet.insert(id).inserted {
    return nil
  }
  let commonOld = old.filter { newSet.contains($0) }
  let commonNew = new.filter { oldIndex[$0] != nil }
  guard commonOld == commonNew else { return nil }
  let deletes = old.enumerated().compactMap { newSet.contains($0.element) ? nil : $0.offset }
  let inserts = new.enumerated().compactMap { oldIndex[$0.element] == nil ? $0.offset : nil }
  return (deletes, inserts)
}

#if canImport(UIKit)
  @MainActor
  final class WuiList: UITableView, WuiComponent, UITableViewDataSource, UITableViewDelegate {
    static var rawId: CWaterUI.WuiTypeId { waterui_list_id() }

    private(set) var stretchAxis: WuiStretchAxis = .both

    private let env: WuiEnvironment
    private let contents: WuiAnyViews
    private let usesSections: Bool
    private var contentsWatcher: WatcherGuard?
    private var itemIds: [Int32] = []
    private var sectionGroups: [ListSectionGroup] = [
      ListSectionGroup(label: nil, footer: nil, itemIndices: [])
    ]

    // Edit mode state
    private var editingObservation: WuiComputedObservation<Bool>?
    private var targetIndexObservation: WuiComputedObservation<Int32>?
    private var scrollGenerationObservation: WuiComputedObservation<Int32>?

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
      self.usesSections = ffiList.uses_sections
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
        let observation = WuiComputedObservation(WuiComputed<Bool>(editingPtr)) {
          [weak self] newValue, metadata in
          guard let self = self else { return }
          let animated = metadata.animation != nil
          self.setEditing(newValue, animated: animated)
        }
        editingObservation = observation
        setEditing(observation.value, animated: false)
      }

      // Initial load + watch structural changes.
      installContentsWatch()
      reloadFromRust(animated: false)
      installScrollController(ffiList)
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
      updateFromRust(ids: ids, animated: metadata.animation != nil)
    }

    private func updateFromRust(ids: [Int32], animated: Bool) {
      let oldIds = itemIds
      let oldGroups = sectionGroups
      var newGroups = resolveListSectionGroups(
        contents: contents,
        count: ids.count,
        usesSections: usesSections
      )
      if newGroups.isEmpty {
        newGroups = [ListSectionGroup(label: nil, footer: nil, itemIndices: [])]
      }

      // Plain single-section membership changes diff at the row level so every
      // surviving cell (and its in-flight animation / accessibility node) is
      // preserved and the change animates. Sectioned layouts — where rows can
      // move between sections without their id changing — and reorders fall
      // back to a full reload.
      if window != nil,
        isSinglePlainSection(oldGroups),
        isSinglePlainSection(newGroups),
        let diff = singleSectionRowDiff(old: oldIds, new: ids)
      {
        itemIds = ids
        sectionGroups = newGroups
        let rowAnimation: UITableView.RowAnimation = animated ? .automatic : .none
        performBatchUpdates {
          if !diff.deletes.isEmpty {
            deleteRows(
              at: diff.deletes.map { IndexPath(row: $0, section: 0) },
              with: rowAnimation
            )
          }
          if !diff.inserts.isEmpty {
            insertRows(
              at: diff.inserts.map { IndexPath(row: $0, section: 0) },
              with: rowAnimation
            )
          }
        }
        return
      }

      itemIds = ids
      sectionGroups = newGroups
      reloadData()
    }

    // Translates a `(section, row)` index path back to the position in the
    // flat `itemIds` array that the Rust side knows about.
    private func flatIndex(for indexPath: IndexPath) -> Int {
      sectionGroups[indexPath.section].itemIndices[indexPath.row]
    }

    private func indexPath(forFlat flat: Int) -> IndexPath? {
      for (sectionIdx, group) in sectionGroups.enumerated() {
        guard
          let first = group.itemIndices.first,
          let last = group.itemIndices.last,
          flat >= first,
          flat <= last
        else { continue }
        let row = flat - first
        precondition(
          group.itemIndices[row] == flat,
          "WaterUI List section item indices must be contiguous"
        )
        return IndexPath(row: row, section: sectionIdx)
      }
      return nil
    }

    private func installScrollController(_ descriptor: CWaterUI.WuiList) {
      let pointers = [descriptor.target_index, descriptor.scroll_generation]
      let presentCount = pointers.compactMap { $0 }.count
      precondition(
        presentCount == 0 || presentCount == pointers.count,
        "WaterUI List controller pointers must be either both null or both non-null"
      )
      guard
        let targetIndex = descriptor.target_index,
        let generation = descriptor.scroll_generation
      else { return }

      targetIndexObservation = WuiComputedObservation(WuiComputed<Int32>(targetIndex)) { _, _ in }
      let generationObservation = WuiComputedObservation(WuiComputed<Int32>(generation)) {
        [weak self] request, _ in
        guard request > 0 else { return }
        self?.applyScrollControllerTarget()
      }
      scrollGenerationObservation = generationObservation
      if generationObservation.value > 0 {
        applyScrollControllerTarget()
      }
    }

    private func applyScrollControllerTarget() {
      guard let targetIndexObservation else {
        fatalError("WaterUI List target observation is missing")
      }
      let target = Int(targetIndexObservation.value)
      precondition(
        target >= 0 && target < itemIds.count,
        "List scroll target \(target) exceeds collection length \(itemIds.count)"
      )
      guard let indexPath = indexPath(forFlat: target) else {
        fatalError("WaterUI List target \(target) has no native index path")
      }
      layoutIfNeeded()
      scrollToRow(at: indexPath, at: .top, animated: false)
    }

    // MARK: - WuiComponent

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
      CGSize(
        width: proposal.width.map(CGFloat.init) ?? contentSize.width,
        height: proposal.height.map(CGFloat.init) ?? contentSize.height
      )
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
      let dequeuedCell = tableView.dequeueReusableCell(
        withIdentifier: WuiListCell.reuseIdentifier, for: indexPath)
      guard let cell = dequeuedCell as? WuiListCell else {
        fatalError("Expected WuiListCell for reuse identifier \(WuiListCell.reuseIdentifier)")
      }
      let flat = flatIndex(for: indexPath)
      let item = resolveListItem(from: contents, at: flat, env: env)
      let itemId = itemIds[flat]
      cell.configure(with: item.view, deletable: item.deletable) { [weak self] metadata in
        guard let self else { return }
        guard let updatedFlat = self.itemIds.firstIndex(of: itemId),
          let updatedPath = self.indexPath(forFlat: updatedFlat)
        else { return }
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

    func tableView(
      _ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle,
      forRowAt indexPath: IndexPath
    ) {
      if editingStyle == .delete {
        let flat = flatIndex(for: indexPath)
        itemIds.remove(at: flat)
        sectionGroups = resolveListSectionGroups(
          contents: contents,
          count: itemIds.count,
          usesSections: usesSections
        )
        tableView.reloadData()

        if let deletePtr = onDeletePtr {
          waterui_call_index_action(deletePtr, env.inner, UInt(flat))
        }
      }
    }

    func tableView(
      _ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
      guard onDeletePtr != nil else { return nil }
      let flat = flatIndex(for: indexPath)
      guard resolveListItemDeletable(from: contents, at: flat) else { return nil }

      let deleteAction = UIContextualAction(style: .destructive, title: "Delete") {
        [weak self] _, _, completion in
        guard let self = self else {
          completion(false)
          return
        }

        self.itemIds.remove(at: flat)
        self.sectionGroups = resolveListSectionGroups(
          contents: self.contents,
          count: self.itemIds.count,
          usesSections: self.usesSections
        )
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

    func tableView(
      _ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath,
      to destinationIndexPath: IndexPath
    ) {
      let from = flatIndex(for: sourceIndexPath)
      let to = flatIndex(for: destinationIndexPath)
      let id = itemIds.remove(at: from)
      itemIds.insert(id, at: to)
      sectionGroups = resolveListSectionGroups(
        contents: contents,
        count: itemIds.count,
        usesSections: usesSections
      )

      if let movePtr = onMovePtr {
        waterui_call_move_action(movePtr, env.inner, UInt(from), UInt(to))
      }
    }

    func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath)
      -> UITableViewCell.EditingStyle
    {
      // Show delete button in edit mode only if item is deletable
      guard onDeletePtr != nil else { return .none }
      return resolveListItemDeletable(from: contents, at: flatIndex(for: indexPath))
        ? .delete : .none
    }

    // MARK: - UITableViewDelegate

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
      let flat = flatIndex(for: indexPath)
      let item = resolveListItem(from: contents, at: flat, env: env)
      let insets = WuiListCell.rowInsets
      let width = tableView.bounds.width - insets.leading - insets.trailing
      let proposal = WuiProposalSize(
        width: width > 0 ? Float(width) : nil,
        height: nil
      )
      let size = item.view.sizeThatFits(proposal)
      // Apple's inset-grouped table style uses a 44pt minimum touch
      // target — keep that floor when the measured content is shorter
      // (single-line rows, dividers, etc).
      return max(size.height + insets.top + insets.bottom, 44)
    }
  }

  // MARK: - WuiListCell

  private final class WuiListCell: UITableViewCell {
    static let reuseIdentifier = "WuiListCell"

    private var contentWuiView: WuiAnyView?
    private var deletableObservation: WuiComputedObservation<Bool>?

    /// SwiftUI's default inset-grouped row insets; the height measurement in
    /// `heightForRowAt` must subtract/add exactly these values.
    static let rowInsets = NSDirectionalEdgeInsets(top: 11, leading: 20, bottom: 11, trailing: 20)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
      super.init(style: style, reuseIdentifier: reuseIdentifier)
      // SwiftUI's inset-grouped rows are opaque cards floating on the
      // grouped background; a clear cell made the rounded cards disappear.
      selectionStyle = .none
      backgroundColor = .secondarySystemGroupedBackground
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
      deletableObservation = nil

      // Add new content
      contentWuiView = view
      view.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(view)

      // Content sits inside SwiftUI's default row insets instead of running
      // flush to the card edge.
      let insets = Self.rowInsets
      NSLayoutConstraint.activate([
        view.leadingAnchor.constraint(
          equalTo: contentView.leadingAnchor, constant: insets.leading),
        view.trailingAnchor.constraint(
          equalTo: contentView.trailingAnchor, constant: -insets.trailing),
        view.topAnchor.constraint(equalTo: contentView.topAnchor, constant: insets.top),
        view.bottomAnchor.constraint(
          equalTo: contentView.bottomAnchor, constant: -insets.bottom),
      ])

      deletableObservation = deletable.map { signal in
        WuiComputedObservation(signal) { _, metadata in
          onDeletableChange(metadata)
        }
      }
    }

    override func prepareForReuse() {
      super.prepareForReuse()
      contentWuiView?.removeFromSuperview()
      contentWuiView = nil
      deletableObservation = nil
    }
  }
#endif

#if canImport(AppKit)
  /// SwiftUI's macOS List draws a hairline separator under each row except
  /// the last of its section; NSTableView has no per-row separator concept,
  /// so the row view draws it.
  private final class WuiListRowView: NSTableRowView {
    var showsSeparator = false

    /// Where the separator starts, measured from the row's leading edge.
    ///
    /// A Mac list insets it to the row content's own left edge rather than
    /// running it wall to wall, so the rule lines up with the text above and
    /// below it. Measured against a plain SwiftUI `List`.
    var separatorInset: CGFloat = 0

    override func draw(_ dirtyRect: NSRect) {
      super.draw(dirtyRect)
      guard showsSeparator else { return }
      NSColor.separatorColor.setFill()
      let hairline = 1 / (window?.backingScaleFactor ?? 1)
      let inset = min(separatorInset, bounds.width)
      NSRect(x: inset, y: 0, width: bounds.width - inset, height: hairline).fill()
    }
  }

  private final class WuiListRowContainerView: NSView {
    private var contentWuiView: WuiAnyView?
    private var deleteButton: NSButton?
    private var deletableObservation: WuiComputedObservation<Bool>?

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
      deletableObservation = nil

      let observation = deletable.map { signal in
        WuiComputedObservation(signal) { _, metadata in
          onDeletableChange(metadata)
        }
      }
      deletableObservation = observation

      contentWuiView = view
      view.translatesAutoresizingMaskIntoConstraints = false
      addSubview(view)

      if showsDeleteControl, observation?.value ?? true {
        let button = NSButton(title: "Delete", target: target, action: action)
        button.bezelStyle = .inline
        button.identifier = NSUserInterfaceItemIdentifier(String(itemId))
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        deleteButton = button

        NSLayoutConstraint.activate([
          view.leadingAnchor.constraint(
            equalTo: leadingAnchor, constant: WuiList.rowContentInset),
          view.topAnchor.constraint(equalTo: topAnchor),
          view.bottomAnchor.constraint(equalTo: bottomAnchor),

          button.leadingAnchor.constraint(equalTo: view.trailingAnchor, constant: 8),
          button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
          button.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
      } else {
        // The same inset the separator and the section headers use, so a row's
        // content, the rule under it and the name of its section all start at
        // one edge. Without it the text sat flush against the window while the
        // header appeared indented, which is what made the two look reversed.
        NSLayoutConstraint.activate([
          view.leadingAnchor.constraint(
            equalTo: leadingAnchor, constant: WuiList.rowContentInset),
          view.trailingAnchor.constraint(
            equalTo: trailingAnchor, constant: -WuiList.rowContentInset),
          view.topAnchor.constraint(equalTo: topAnchor),
          view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
      }

    }
  }

  @MainActor
  final class WuiList: NSScrollView, WuiComponent, NSTableViewDataSource, NSTableViewDelegate {
    static var rawId: CWaterUI.WuiTypeId { waterui_list_id() }

    private(set) var stretchAxis: WuiStretchAxis = .both

    private let env: WuiEnvironment
    private let contents: WuiAnyViews
    private let usesSections: Bool
    private var contentsWatcher: WatcherGuard?
    private var itemIds: [Int32] = []
    private var sectionGroups: [ListSectionGroup] = []
    /// Linearized presentation: each entry is either a section header (group
    /// row in NSTableView terminology), a content row, or a section footer.
    /// `tableView.numberOfRows == flatLayout.count`.
    private var flatLayout: [TableLayoutEntry] = []
    private var flatRowByItemIndex: [Int] = []
    private let tableView: NSTableView
    private var lastColumnWidth: CGFloat = 0

    // Edit mode state
    private var editingObservation: WuiComputedObservation<Bool>?
    private var targetIndexObservation: WuiComputedObservation<Int32>?
    private var scrollGenerationObservation: WuiComputedObservation<Int32>?
    private var isInEditMode: Bool = false

    // Callbacks
    private var onDeletePtr: OpaquePointer?
    private var onMovePtr: OpaquePointer?

    // Pasteboard type for drag-and-drop
    private static let dragType = NSPasteboard.PasteboardType("dev.waterui.listitem")

    /// How far a row's content sits in from the list's leading edge.
    ///
    /// The separator is inset to match, so the rule lines up with the text above
    /// and below it rather than running wall to wall.
    static let rowContentInset: CGFloat = 20

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
      self.usesSections = ffiList.uses_sections
      self.onDeletePtr = ffiList.on_delete
      self.onMovePtr = ffiList.on_move
      self.tableView = NSTableView()

      super.init(frame: .zero)

      // Configure table view to look like SwiftUI List. The column's real
      // width is driven from the content width on every layout pass.
      let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("content"))
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
      // `.inset` gives every row a rounded, inset background of its own, which a
      // Mac list does not have. Measured against a plain SwiftUI `List`: rows
      // abut, carry no card of their own, and sit directly on the content
      // background — the separator is what divides them.
      tableView.style = .fullWidth
      tableView.intercellSpacing = NSSize(width: 0, height: 0)
      // SwiftUI's macOS List draws its content on the text background
      // (white in light mode), not the window background — verified against
      // an NSHostingView reference render of a real SwiftUI List.
      //
      // Except in a sidebar, where the split view supplies a translucent
      // material and anything opaque painted over it reads as a white card
      // floating on the panel instead of the panel itself. The check happens
      // once the view is in its window, since that is when its ancestry is
      // known.
      tableView.backgroundColor = .textBackgroundColor
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
        let observation = WuiComputedObservation(WuiComputed<Bool>(editingPtr)) {
          [weak self] newValue, _ in
          guard let self = self else { return }
          self.isInEditMode = newValue
          self.tableView.reloadData()
        }
        editingObservation = observation
        isInEditMode = observation.value
      }

      // Initial load + watch structural changes.
      installContentsWatch()
      reloadFromRust(animated: false)
      installScrollController(ffiList)
    }

    /// Draws this list as a sidebar's contents.
    ///
    /// A sidebar's split view supplies a translucent material, and an opaque
    /// background painted over it reads as a white card floating on the panel
    /// rather than as the panel itself. A sidebar list also takes the
    /// source-list row chrome, which is what draws the rounded selection.
    ///
    /// The split view says so rather than the list inferring it: whether AppKit
    /// has inserted its material view by the time the list is in the window is
    /// not something to depend on, and guessing wrong leaves a white panel.
    func applySidebarPresentation(_ isSidebar: Bool) {
      tableView.backgroundColor = isSidebar ? .clear : .textBackgroundColor
      tableView.style = isSidebar ? .sourceList : .fullWidth
      drawsBackground = false
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

    private func applyRustUpdate(ids: [Int32], metadata: WuiWatcherMetadata) {
      updateFromRust(ids: ids, animated: metadata.animation != nil)
    }

    private func reloadFromRust(animated: Bool) {
      updateFromRust(ids: contents.allIds(), animated: animated)
    }

    private func updateFromRust(ids: [Int32], animated: Bool) {
      let oldIds = itemIds
      let oldGroups = sectionGroups
      var newGroups = resolveListSectionGroups(
        contents: contents,
        count: ids.count,
        usesSections: usesSections
      )
      if newGroups.isEmpty {
        newGroups = [ListSectionGroup(label: nil, footer: nil, itemIndices: [])]
      }

      // Plain single-section membership changes diff at the row level (flat row
      // index == id position when there are no headers/footers) so surviving row
      // views, their animations, and accessibility survive. Sectioned layouts
      // and reorders fall back to a full reload.
      if tableView.window != nil,
        isSinglePlainSection(oldGroups),
        isSinglePlainSection(newGroups),
        let diff = singleSectionRowDiff(old: oldIds, new: ids)
      {
        itemIds = ids
        sectionGroups = newGroups
        rebuildFlatLayout()
        let animation: NSTableView.AnimationOptions = animated ? .effectFade : []
        tableView.beginUpdates()
        if !diff.deletes.isEmpty {
          tableView.removeRows(at: IndexSet(diff.deletes), withAnimation: animation)
        }
        if !diff.inserts.isEmpty {
          tableView.insertRows(at: IndexSet(diff.inserts), withAnimation: animation)
        }
        tableView.endUpdates()
        return
      }

      itemIds = ids
      sectionGroups = newGroups
      rebuildFlatLayout()
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

    private func rebuildFlatLayout() {
      flatLayout = Self.buildFlatLayout(from: sectionGroups)
      flatRowByItemIndex = Array(repeating: -1, count: itemIds.count)
      for (flatRow, entry) in flatLayout.enumerated() {
        if case .row(let itemIndex) = entry {
          flatRowByItemIndex[itemIndex] = flatRow
        }
      }
      precondition(
        !flatRowByItemIndex.contains(-1),
        "WaterUI List flat layout must contain every item exactly once"
      )
    }

    private func itemIndex(forFlatRow flatRow: Int) -> Int? {
      guard flatRow >= 0, flatRow < flatLayout.count else { return nil }
      if case .row(let itemIndex) = flatLayout[flatRow] {
        return itemIndex
      }
      return nil
    }

    private func flatRow(forItemIndex itemIndex: Int) -> Int? {
      guard itemIndex >= 0, itemIndex < flatRowByItemIndex.count else { return nil }
      return flatRowByItemIndex[itemIndex]
    }

    private func installScrollController(_ descriptor: CWaterUI.WuiList) {
      let pointers = [descriptor.target_index, descriptor.scroll_generation]
      let presentCount = pointers.compactMap { $0 }.count
      precondition(
        presentCount == 0 || presentCount == pointers.count,
        "WaterUI List controller pointers must be either both null or both non-null"
      )
      guard
        let targetIndex = descriptor.target_index,
        let generation = descriptor.scroll_generation
      else { return }

      targetIndexObservation = WuiComputedObservation(WuiComputed<Int32>(targetIndex)) { _, _ in }
      let generationObservation = WuiComputedObservation(WuiComputed<Int32>(generation)) {
        [weak self] request, _ in
        guard request > 0 else { return }
        self?.applyScrollControllerTarget()
      }
      scrollGenerationObservation = generationObservation
      if generationObservation.value > 0 {
        applyScrollControllerTarget()
      }
    }

    private func applyScrollControllerTarget() {
      guard let targetIndexObservation else {
        fatalError("WaterUI List target observation is missing")
      }
      let target = Int(targetIndexObservation.value)
      precondition(
        target >= 0 && target < itemIds.count,
        "List scroll target \(target) exceeds collection length \(itemIds.count)"
      )
      guard let row = flatRow(forItemIndex: target) else {
        fatalError("WaterUI List target \(target) has no native table row")
      }
      layoutSubtreeIfNeeded()
      contentView.scroll(to: NSPoint(x: 0, y: tableView.rect(ofRow: row).minY))
      reflectScrolledClipView(contentView)
    }

    // MARK: - Delete Action

    private func deleteItem(at flatRow: Int) {
      guard let itemIndex = itemIndex(forFlatRow: flatRow) else { return }
      guard let deletePtr = onDeletePtr else { return }
      guard resolveListItemDeletable(from: contents, at: itemIndex) else { return }

      itemIds.remove(at: itemIndex)
      sectionGroups = resolveListSectionGroups(
        contents: contents,
        count: itemIds.count,
        usesSections: usesSections
      )
      rebuildFlatLayout()
      tableView.reloadData()

      waterui_call_index_action(deletePtr, env.inner, UInt(itemIndex))
    }

    // MARK: - WuiComponent

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
      let intrinsicSize = tableView.fittingSize
      return CGSize(
        width: proposal.width.map(CGFloat.init) ?? intrinsicSize.width,
        height: proposal.height.map(CGFloat.init) ?? intrinsicSize.height
      )
    }

    nonisolated override var isFlipped: Bool { true }

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

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (
      any NSPasteboardWriting
    )? {
      guard onMovePtr != nil, sectionGroups.count <= 1 else { return nil }
      guard case .row = flatLayout[row] else { return nil }
      let item = NSPasteboardItem()
      item.setString(String(row), forType: Self.dragType)
      return item
    }

    func tableView(
      _ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
      proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
      guard sectionGroups.count <= 1 else { return [] }
      if dropOperation == .above {
        return .move
      }
      return []
    }

    func tableView(
      _ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
      dropOperation: NSTableView.DropOperation
    ) -> Bool {
      guard sectionGroups.count <= 1 else { return false }
      guard let items = info.draggingPasteboard.pasteboardItems,
        let item = items.first,
        let rowStr = item.string(forType: Self.dragType),
        let sourceFlatRow = Int(rowStr),
        let sourceItem = itemIndex(forFlatRow: sourceFlatRow)
      else {
        return false
      }

      var destinationItem = row
      if sourceFlatRow < destinationItem {
        destinationItem -= 1
      }

      let movedId = itemIds.remove(at: sourceItem)
      itemIds.insert(movedId, at: destinationItem)
      sectionGroups = resolveListSectionGroups(
        contents: contents,
        count: itemIds.count,
        usesSections: usesSections
      )
      rebuildFlatLayout()
      tableView.reloadData()

      if let movePtr = onMovePtr {
        waterui_call_move_action(movePtr, env.inner, UInt(sourceItem), UInt(destinationItem))
      }

      return true
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
      -> NSView?
    {
      guard row >= 0, row < flatLayout.count else { return nil }
      switch flatLayout[row] {
      case .header(let label, _):
        return WuiListSectionHeaderView(text: label, kind: .header, env: env)
      case .footer(let label, _):
        return WuiListSectionHeaderView(text: label, kind: .footer, env: env)
      case .row(let itemIndex):
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
            let reloadFlat = self.flatRow(forItemIndex: reloadItemIndex)
          else { return }
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
        let flat = flatRow(forItemIndex: itemIndex)
      else {
        return
      }
      deleteItem(at: flat)
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
      let rowView = WuiListRowView()
      rowView.isEmphasized = true
      rowView.separatorInset = Self.rowContentInset
      // SwiftUI separates row–row boundaries only; the last row of a
      // section (followed by a footer, header, or nothing) has none.
      if case .row = flatLayout[row], row + 1 < flatLayout.count,
        case .row = flatLayout[row + 1]
      {
        rowView.showsSeparator = true
      }
      return rowView
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
      // AppKit can probe rows transiently during insert/remove animations
      // before `flatLayout` catches up; answer with the minimum row height.
      guard row >= 0, row < flatLayout.count else { return Self.minimumRowHeight }
      switch flatLayout[row] {
      case .header:
        return 38
      case .footer:
        return 32
      case .row(let itemIndex):
        let item = resolveListItem(from: contents, at: itemIndex, env: env)
        let size = item.view.sizeThatFits(
          WuiProposalSize(width: Float(tableView.bounds.width), height: nil))
        return max(size.height, Self.minimumRowHeight)
      }
    }

    /// macOS list rows follow the pointer metric (~24pt like SwiftUI's List),
    /// not the 44pt iOS touch-target floor.
    private static let minimumRowHeight: CGFloat = 24

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
      guard row >= 0, row < flatLayout.count else { return false }
      switch flatLayout[row] {
      case .header, .footer: return false
      case .row: return true
      }
    }
  }

  /// Theme-aware section header or footer in the macOS `NSTableView`-based list.
  @MainActor
  private final class WuiListSectionHeaderView: NSView {
    enum Kind { case header, footer }

    private let label: NSTextField
    private var foregroundObservation: WuiComputedObservation<WuiResolvedColor>?
    private var fontObservation: WuiComputedObservation<WuiResolvedFontValue>?

    init(text: String, kind: Kind, env: WuiEnvironment) {
      // SwiftUI section headers render the string as written; the legacy
      // grouped-table uppercasing is not a macOS List behavior.
      self.label = NSTextField(labelWithString: text)
      super.init(frame: .zero)
      translatesAutoresizingMaskIntoConstraints = true
      wantsLayer = true

      label.translatesAutoresizingMaskIntoConstraints = false
      addSubview(label)
      NSLayoutConstraint.activate([
        // The same inset the rows use, so a section's name lines up with the
        // content it names rather than sitting proud of it.
        label.leadingAnchor.constraint(
          equalTo: leadingAnchor, constant: WuiList.rowContentInset),
        label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
        label.topAnchor.constraint(equalTo: topAnchor, constant: kind == .header ? 14 : 6),
        label.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -6),
      ])

      let foreground = WuiComputedObservation(
        themeColor: WuiColorSlot_MutedForeground,
        env: env
      ) { [weak self] color, _ in
        self?.applyForeground(color)
      }
      let fontSlot: WuiFontSlot
      switch kind {
      case .header:
        fontSlot = WuiFontSlot_Caption
      case .footer:
        fontSlot = WuiFontSlot_Footnote
      }
      let font = WuiComputedObservation(themeFont: fontSlot, env: env) {
        [weak self] font, _ in self?.applyFont(font)
      }
      foregroundObservation = foreground
      fontObservation = font
      applyForeground(foreground.value)
      applyFont(font.value)
    }

    private func applyForeground(_ color: WuiResolvedColor) {
      label.textColor = color.toNSColor()
    }

    private func applyFont(_ font: WuiResolvedFontValue) {
      label.font = NSFont.systemFont(
        ofSize: CGFloat(font.size),
        weight: font.weight.toNSFontWeight()
      )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }
  }
#endif
