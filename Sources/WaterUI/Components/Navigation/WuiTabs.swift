// WuiTabs.swift
// Tab container component with customizable position
//
// # Layout Behavior
// Tabs stretches to fill available space (greedy).
// Contains a tab bar and content area.
// Tab bar can be positioned at top or bottom.

import CWaterUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

@MainActor
final class WuiTabs: PlatformView, WuiComponent {
  static var rawId: CWaterUI.WuiTypeId { waterui_tabs_id() }

  private(set) var stretchAxis: WuiStretchAxis = .both

  private let env: WuiEnvironment
  private let position: WuiTabPosition

  // Tab data
  private var tabs: [(id: UInt64, label: WuiAnyView, contentPtr: OpaquePointer?)] = []
  private var currentTabIndex: Int = 0
  private var currentContentView: PlatformView?

  // Selection binding
  private var selectionBinding: WuiBinding<WuiId>?
  private var selectionWatcher: WatcherGuard?

  #if canImport(UIKit)
    private let tabBarContainer: UIView = UIView()
    private let contentContainer: UIView = UIView()
    private var tabButtons: [WuiTabButton] = []
  #elseif canImport(AppKit)
    private let tabBarContainer: NSView = NSView()
    private let contentContainer: NSView = NSView()
    private var tabButtons: [WuiTabButton] = []
  #endif

  // MARK: - WuiComponent Init

  convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
    let ffiTabs: CWaterUI.WuiTabs = waterui_force_as_tabs(anyview)
    self.init(ffiTabs: ffiTabs, env: env)
  }

  // MARK: - Designated Init

  init(ffiTabs: CWaterUI.WuiTabs, env: WuiEnvironment) {
    self.env = env
    self.position = ffiTabs.position

    super.init(frame: .zero)

    // Extract tabs from FFI array
    extractTabs(from: ffiTabs.tabs)

    // Setup selection binding
    setupSelectionBinding(ffiTabs.selection)

    // Configure views
    configureTabBar()
    configureContentContainer()

    // Show initial tab (use binding if provided)
    if !tabs.isEmpty {
      showTab(at: currentTabIndex)
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Tab Extraction

  private func extractTabs(from array: WuiArray_WuiTab) {
    let slice = array.vtable.slice(array.data)
    guard let head = slice.head else { return }

    for i in 0..<slice.len {
      let tab = head.advanced(by: Int(i)).pointee
      let labelView = WuiAnyView(anyview: tab.label, env: env)
      // tab.content is already an OpaquePointer (WuiTabContent*)
      tabs.append((id: tab.id, label: labelView, contentPtr: tab.content))
    }
  }

  // MARK: - Selection Binding

  private func setupSelectionBinding(_ bindingPtr: OpaquePointer?) {
    guard let bindingPtr = bindingPtr else { return }

    let binding = WuiBinding<WuiId>(bindingPtr)
    self.selectionBinding = binding

    selectionWatcher = binding.watch { [weak self] newId, _ in
      guard let self = self else { return }
      if let index = self.tabs.firstIndex(where: { tabIdToInner($0.id) == newId.inner }) {
        self.showTab(at: index)
      }
    }

    // WuiTab.id is u64, encoded from i32 via `as u64` (may sign-extend in Rust).
    // Compare using the low 32 bits to preserve the original i32 bit pattern.
    let selectedInner = binding.value.inner
    if let index = tabs.firstIndex(where: { tabIdToInner($0.id) == selectedInner }) {
      currentTabIndex = index
    }
  }

  // MARK: - Configuration

  private func configureTabBar() {
    #if canImport(UIKit)
      tabBarContainer.translatesAutoresizingMaskIntoConstraints = true
      addSubview(tabBarContainer)

      tabButtons = tabs.enumerated().map { index, tab in
        let button = WuiTabButton(labelView: tab.label, env: env)
        button.onTap = { [weak self] in
          self?.showTab(at: index)
        }
        tabBarContainer.addSubview(button)
        return button
      }
    #elseif canImport(AppKit)
      tabBarContainer.translatesAutoresizingMaskIntoConstraints = true
      addSubview(tabBarContainer)

      tabButtons = tabs.enumerated().map { index, tab in
        let button = WuiTabButton(labelView: tab.label, env: env)
        button.onClick = { [weak self] in
          self?.showTab(at: index)
        }
        tabBarContainer.addSubview(button)
        return button
      }
    #endif
  }

  private func configureContentContainer() {
    contentContainer.translatesAutoresizingMaskIntoConstraints = true
    addSubview(contentContainer)
  }

  // MARK: - Tab Switching

  private func showTab(at index: Int) {
    guard index >= 0 && index < tabs.count else { return }

    currentTabIndex = index

    // Remove old content
    currentContentView?.removeFromSuperview()

    // Get or create content view
    let tab = tabs[index]
    if let contentPtr = tab.contentPtr {
      // Call waterui_tab_content to build the NavigationView
      let navView = waterui_tab_content(contentPtr, env.inner)
      let contentView = WuiNavigationView(ffiNav: navView, env: env)
      currentContentView = contentView
      contentView.translatesAutoresizingMaskIntoConstraints = true
      contentContainer.addSubview(contentView)
    }

    // Update selection binding (avoid infinite loop)
    let inner = tabIdToInner(tab.id)
    if selectionBinding?.value.inner != inner {
      selectionBinding?.set(WuiId(inner: inner))
    }

    updateSelectionUI()

    #if canImport(UIKit)
      setNeedsLayout()
      layoutIfNeeded()
    #elseif canImport(AppKit)
      needsLayout = true
    #endif
  }

  private func updateSelectionUI() {
    for (idx, button) in tabButtons.enumerated() {
      button.isSelected = idx == currentTabIndex
    }
  }

  // MARK: - WuiComponent

  func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
    let width = proposal.width.map { CGFloat($0) } ?? 320
    let height = proposal.height.map { CGFloat($0) } ?? 480
    return CGSize(width: width, height: height)
  }

  #if canImport(UIKit)
    override func layoutSubviews() {
      super.layoutSubviews()
      performLayout()
    }
  #elseif canImport(AppKit)
    override var isFlipped: Bool { true }

    override func layout() {
      super.layout()
      performLayout()
    }
  #endif

  private func performLayout() {
    let isTop = position == WuiTabPosition_Top
    let barHeight = measuredTabBarHeight()

    if isTop {
      // Tab bar at top
      tabBarContainer.frame = CGRect(x: 0, y: 0, width: bounds.width, height: barHeight)
      contentContainer.frame = CGRect(
        x: 0,
        y: barHeight,
        width: bounds.width,
        height: bounds.height - barHeight
      )
    } else {
      // Tab bar at bottom
      let tabBarY = bounds.height - barHeight
      tabBarContainer.frame = CGRect(x: 0, y: tabBarY, width: bounds.width, height: barHeight)
      contentContainer.frame = CGRect(
        x: 0,
        y: 0,
        width: bounds.width,
        height: bounds.height - barHeight
      )
    }

    layoutTabButtons(in: tabBarContainer.bounds)

    // Layout content view
    currentContentView?.frame = contentContainer.bounds
  }

  private func layoutTabButtons(in bounds: CGRect) {
    guard !tabButtons.isEmpty else { return }
    let count = CGFloat(tabButtons.count)
    let buttonWidth = bounds.width / max(count, 1)
    for (index, button) in tabButtons.enumerated() {
      let x = CGFloat(index) * buttonWidth
      button.frame = CGRect(x: x, y: 0, width: buttonWidth, height: bounds.height)
    }
  }

  private func measuredTabBarHeight() -> CGFloat {
    guard !tabButtons.isEmpty else { return 0 }
    let availableWidth = bounds.width / CGFloat(tabButtons.count)
    var maxHeight: CGFloat = 0
    for button in tabButtons {
      let size = button.sizeThatFits(CGSize(width: availableWidth, height: bounds.height))
      maxHeight = max(maxHeight, size.height)
    }

    #if canImport(UIKit)
      let baseline = UITabBar().sizeThatFits(bounds.size).height
      return max(maxHeight, baseline)
    #elseif canImport(AppKit)
      let baseline = NSSegmentedControl().fittingSize.height
      return max(maxHeight, baseline)
    #endif
  }

  private func tabIdToInner(_ id: UInt64) -> Int32 {
    Int32(bitPattern: UInt32(truncatingIfNeeded: id))
  }
}
