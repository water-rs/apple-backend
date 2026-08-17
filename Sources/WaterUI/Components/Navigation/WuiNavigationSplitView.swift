import CWaterUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

@MainActor
final class WuiNavigationSplitView: PlatformView, WuiComponent {
  static var rawId: CWaterUI.WuiTypeId { waterui_split_navigation_container_id() }

  private(set) var stretchAxis: WuiStretchAxis = .both

  private let sidebarView: WuiAnyView
  private let placeholderView: WuiAnyView
  /// The middle column's empty state, kept apart from [`placeholderView`].
  private let emptyColumnView = PlatformView()
  private let primarySelection: WuiBinding<Int32>
  private let contentHandle: UnsafeMutablePointer<CWaterUI.WuiNavigationSplitDetail>?
  private let secondarySelection: WuiBinding<Int32>?
  private let detailHandle: UnsafeMutablePointer<CWaterUI.WuiNavigationSplitDetail>
  private let columnVisibility: WuiComputed<Int32>
  private let env: WuiEnvironment
  private let widths: CWaterUI.WuiNavigationColumnWidth
  private let style: WuiNavigationSplitStyle
  private var contentViews: [Int32: WuiNavigationView] = [:]
  private var detailViews: [Int32: WuiNavigationView] = [:]
  private var primarySelectionWatcher: WatcherGuard?
  private var secondarySelectionWatcher: WatcherGuard?
  private var visibilityWatcher: WatcherGuard?

  #if canImport(UIKit)
    private let splitController: UISplitViewController
    private let primaryController = UIViewController()
    private let supplementaryController = UIViewController()
    private let secondaryController = UIViewController()
    private var contentControllers: [Int32: UIViewController] = [:]
    private var detailControllers: [Int32: UIViewController] = [:]
  #elseif canImport(AppKit)
    private let splitController = NSSplitViewController()
    private let primaryController = NSViewController()
    private let supplementaryController = NSViewController()
    private let secondaryController = NSViewController()
  #endif

  convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
    let split = waterui_force_as_split_navigation_container(anyview)
    guard let sidebar = split.sidebar else {
      fatalError("NavigationSplitView sidebar is null")
    }
    guard let placeholder = split.placeholder else {
      fatalError("NavigationSplitView placeholder is null")
    }
    guard let primarySelection = split.primary_selection else {
      fatalError("NavigationSplitView primary selection binding is null")
    }
    guard let detail = split.detail else {
      fatalError("NavigationSplitView detail resolver is null")
    }
    guard let visibility = split.column_visibility else {
      fatalError("NavigationSplitView column visibility signal is null")
    }
    self.init(
      sidebarView: WuiAnyView(anyview: sidebar, env: env),
      placeholderView: WuiAnyView(anyview: placeholder, env: env),
      primarySelection: WuiBinding<Int32>(primarySelection),
      contentHandle: split.content,
      secondarySelection: split.secondary_selection.map(WuiBinding<Int32>.init),
      detailHandle: detail,
      columnVisibility: WuiComputed<Int32>(visibility),
      widths: split.sidebar_width,
      style: split.style,
      env: env
    )
  }

  init(
    sidebarView: WuiAnyView,
    placeholderView: WuiAnyView,
    primarySelection: WuiBinding<Int32>,
    contentHandle: UnsafeMutablePointer<CWaterUI.WuiNavigationSplitDetail>?,
    secondarySelection: WuiBinding<Int32>?,
    detailHandle: UnsafeMutablePointer<CWaterUI.WuiNavigationSplitDetail>,
    columnVisibility: WuiComputed<Int32>,
    widths: CWaterUI.WuiNavigationColumnWidth,
    style: WuiNavigationSplitStyle,
    env: WuiEnvironment
  ) {
    guard (contentHandle == nil) == (secondarySelection == nil) else {
      fatalError("Three-column split content and secondary selection must both be present")
    }
    guard widths.min > 0, widths.min <= widths.ideal, widths.ideal <= widths.max else {
      fatalError("NavigationSplitView sidebar widths must satisfy 0 < min <= ideal <= max")
    }
    self.sidebarView = sidebarView
    self.placeholderView = placeholderView
    self.primarySelection = primarySelection
    self.contentHandle = contentHandle
    self.secondarySelection = secondarySelection
    self.detailHandle = detailHandle
    self.columnVisibility = columnVisibility
    self.widths = widths
    self.style = style
    self.env = env
    #if canImport(UIKit)
      self.splitController = UISplitViewController(
        style: contentHandle == nil ? .doubleColumn : .tripleColumn)
    #endif
    super.init(frame: .zero)

    configureNativeSplit()
    primarySelectionWatcher = primarySelection.watch { [weak self] selected, _ in
      self?.showPrimarySelection(selected)
    }
    secondarySelectionWatcher = secondarySelection?.watch { [weak self] selected, _ in
      self?.showSecondarySelection(selected)
    }
    visibilityWatcher = columnVisibility.watch { [weak self] visibility, _ in
      self?.applyColumnVisibility(visibility)
    }
    showPrimarySelection(primarySelection.value)
    if let secondarySelection {
      showSecondarySelection(secondarySelection.value)
    }
    applyColumnVisibility(columnVisibility.value)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  @MainActor deinit {
    if let contentHandle {
      waterui_drop_split_navigation_detail(contentHandle)
    }
    waterui_drop_split_navigation_detail(detailHandle)
  }

  func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
    CGSize(
      width: proposal.width.map(CGFloat.init) ?? 320,
      height: proposal.height.map(CGFloat.init) ?? 480
    )
  }

  private func configureNativeSplit() {
    #if canImport(UIKit)
      primaryController.view = sidebarView
      // The placeholder is one view, so it can be the empty state of one column
      // only: a `UIView` belongs to a single view controller and has a single
      // superview, and assigning it to a second one raises. It goes to the
      // detail column — the one Apple's own split views leave a placeholder in —
      // while the middle column gets an empty view of its own.
      supplementaryController.view = emptyColumnView
      secondaryController.view = placeholderView
      splitController.delegate = self
      switch style {
      case WuiNavigationSplitStyle_Automatic:
        splitController.preferredSplitBehavior = .automatic
      case WuiNavigationSplitStyle_Balanced:
        splitController.preferredSplitBehavior = .tile
      case WuiNavigationSplitStyle_ProminentDetail:
        splitController.preferredSplitBehavior = .overlay
      default:
        fatalError("Unsupported navigation split style: \(style.rawValue)")
      }
      splitController.preferredPrimaryColumnWidth = CGFloat(widths.ideal)
      splitController.minimumPrimaryColumnWidth = CGFloat(widths.min)
      splitController.maximumPrimaryColumnWidth = CGFloat(widths.max)
      splitController.setViewController(primaryController, for: .primary)
      if contentHandle != nil {
        splitController.setViewController(supplementaryController, for: .supplementary)
      }
      splitController.setViewController(secondaryController, for: .secondary)
      splitController.view.translatesAutoresizingMaskIntoConstraints = true
      addSubview(splitController.view)
    #elseif canImport(AppKit)
      primaryController.view = sidebarView
      // As above: one placeholder view, so one column may hold it.
      supplementaryController.view = emptyColumnView
      secondaryController.view = placeholderView
      // The sidebar column's contents draw on the split view's own material
      // instead of painting a background over it.
      sidebarView.setIsSidebarContent(true)
      let sidebarItem = NSSplitViewItem(sidebarWithViewController: primaryController)
      sidebarItem.minimumThickness = CGFloat(widths.min)
      sidebarItem.maximumThickness = CGFloat(widths.max)
      splitController.addSplitViewItem(sidebarItem)
      if contentHandle != nil {
        splitController.addSplitViewItem(
          NSSplitViewItem(viewController: supplementaryController)
        )
      }
      let detailItem = NSSplitViewItem(viewController: secondaryController)
      if style == WuiNavigationSplitStyle_ProminentDetail {
        detailItem.holdingPriority = .defaultHigh
      }
      splitController.addSplitViewItem(detailItem)
      splitController.view.translatesAutoresizingMaskIntoConstraints = true
      addSubview(splitController.view)
    #endif
  }

  private func showPrimarySelection(_ selected: Int32) {
    guard let contentHandle else {
      showDetailSelection(selected, binding: primarySelection)
      return
    }
    if selected == 0 {
      #if canImport(UIKit)
        supplementaryController.view = emptyColumnView
        if splitController.isCollapsed { splitController.show(.primary) }
      #elseif canImport(AppKit)
        supplementaryController.view = emptyColumnView
      #endif
      return
    }

    let content = destinationView(for: selected, handle: contentHandle, cache: &contentViews)
    #if canImport(UIKit)
      let controller =
        contentControllers[selected]
        ?? {
          let controller = UIViewController()
          controller.view = content
          contentControllers[selected] = controller
          return controller
        }()
      content.setBackAction(
        splitController.isCollapsed
          ? Action(callback: { [weak self] in self?.primarySelection.set(0) })
          : nil
      )
      splitController.setViewController(controller, for: .supplementary)
      splitController.show(.supplementary)
    #elseif canImport(AppKit)
      content.setBackAction(nil)
      supplementaryController.view = content
    #endif
  }

  private func showSecondarySelection(_ selected: Int32) {
    guard let secondarySelection else { return }
    showDetailSelection(selected, binding: secondarySelection)
  }

  private func showDetailSelection(_ selected: Int32, binding: WuiBinding<Int32>) {
    if selected == 0 {
      #if canImport(UIKit)
        secondaryController.view = placeholderView
        if splitController.isCollapsed {
          splitController.show(contentHandle == nil ? .primary : .supplementary)
        }
      #elseif canImport(AppKit)
        secondaryController.view = placeholderView
      #endif
      return
    }

    let detail = destinationView(for: selected, handle: detailHandle, cache: &detailViews)
    #if canImport(UIKit)
      let controller =
        detailControllers[selected]
        ?? {
          let controller = UIViewController()
          controller.view = detail
          detailControllers[selected] = controller
          return controller
        }()
      detail.setBackAction(
        splitController.isCollapsed
          ? Action(callback: { binding.set(0) })
          : nil
      )
      splitController.setViewController(controller, for: .secondary)
      splitController.show(.secondary)
    #elseif canImport(AppKit)
      detail.setBackAction(nil)
      secondaryController.view = detail
    #endif
  }

  private func destinationView(
    for selected: Int32,
    handle: UnsafeMutablePointer<CWaterUI.WuiNavigationSplitDetail>,
    cache: inout [Int32: WuiNavigationView]
  ) -> WuiNavigationView {
    if let cached = cache[selected] { return cached }
    let navigationView = waterui_split_navigation_detail_content(
      handle,
      CWaterUI.WuiId(inner: selected),
      env.inner
    )
    let destination = WuiNavigationView(ffiNav: navigationView, env: env)
    cache[selected] = destination
    return destination
  }

  private func applyColumnVisibility(_ visibility: Int32) {
    #if canImport(UIKit)
      switch visibility {
      case 0:
        splitController.preferredDisplayMode = .automatic
      case 1:
        splitController.preferredDisplayMode =
          contentHandle == nil ? .oneBesideSecondary : .twoBesideSecondary
      case 2:
        splitController.preferredDisplayMode =
          contentHandle == nil ? .oneBesideSecondary : .twoDisplaceSecondary
      case 3:
        splitController.preferredDisplayMode = .secondaryOnly
      default:
        fatalError("Unsupported navigation split column visibility: \(visibility)")
      }
    #elseif canImport(AppKit)
      guard visibility >= 0, visibility <= 3 else {
        fatalError("Unsupported navigation split column visibility: \(visibility)")
      }
      let items = splitController.splitViewItems
      switch visibility {
      case 0, 1:
        for item in items {
          item.animator().isCollapsed = false
        }
      case 2:
        items.first?.animator().isCollapsed = true
        for item in items.dropFirst() {
          item.animator().isCollapsed = false
        }
      case 3:
        for item in items.dropLast() {
          item.animator().isCollapsed = true
        }
        items.last?.animator().isCollapsed = false
      default:
        fatalError("Unsupported navigation split column visibility: \(visibility)")
      }
    #endif
  }

  #if canImport(UIKit)
    override func layoutSubviews() {
      super.layoutSubviews()
      splitController.view.frame = bounds
    }
  #elseif canImport(AppKit)
    nonisolated override var isFlipped: Bool { true }

    override func layout() {
      super.layout()
      splitController.view.frame = bounds
    }
  #endif
}

#if canImport(UIKit)
  extension WuiNavigationSplitView: UISplitViewControllerDelegate {
    func splitViewController(
      _ splitViewController: UISplitViewController,
      topColumnForCollapsingToProposedTopColumn proposedTopColumn: UISplitViewController.Column
    ) -> UISplitViewController.Column {
      if let secondarySelection, secondarySelection.value != 0 { return .secondary }
      if contentHandle != nil, primarySelection.value != 0 { return .supplementary }
      return primarySelection.value == 0 ? .primary : .secondary
    }

    func splitViewControllerDidCollapse(_ splitViewController: UISplitViewController) {
      showPrimarySelection(primarySelection.value)
      if let secondarySelection { showSecondarySelection(secondarySelection.value) }
    }

    func splitViewControllerDidExpand(_ splitViewController: UISplitViewController) {
      showPrimarySelection(primarySelection.value)
      if let secondarySelection { showSecondarySelection(secondarySelection.value) }
    }

    func splitViewController(
      _ splitViewController: UISplitViewController,
      willShow column: UISplitViewController.Column
    ) {
      guard splitViewController.isCollapsed else { return }
      if column == .primary, primarySelection.value != 0 {
        primarySelection.set(0)
      } else if column == .supplementary,
        let secondarySelection,
        secondarySelection.value != 0
      {
        secondarySelection.set(0)
      }
    }
  }
#endif
