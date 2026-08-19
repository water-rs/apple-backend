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
  #if canImport(AppKit)
    private var contentViews: [Int32: WuiNavigationView] = [:]
    private var detailViews: [Int32: WuiNavigationView] = [:]
  #endif
  private var primarySelectionWatcher: WatcherGuard?
  private var secondarySelectionWatcher: WatcherGuard?
  private var visibilityWatcher: WatcherGuard?

  #if canImport(UIKit)
    private let splitController: UISplitViewController
    private let primaryController = UIViewController()
    private let supplementaryController = UIViewController()
    private let secondaryController = UIViewController()
    private var contentControllers: [Int32: WuiContentViewController] = [:]
    private var detailControllers: [Int32: WuiContentViewController] = [:]
  #elseif canImport(AppKit)
    private let splitController = NSSplitViewController()
    private let primaryController = NSViewController()
    private let supplementaryController = NSViewController()
    private let secondaryController = NSViewController()
    // A split view arranges the *view* each item's controller had when the item
    // was added. Assigning a controller's `view` afterwards therefore swaps a
    // view the split view no longer arranges, and the column goes blank — which
    // is what an empty detail column beside a populated sidebar looks like. Each
    // column is a container that stays put, and its child is what changes.
    private let supplementaryContainer = WuiSplitColumnContainer()
    private let secondaryContainer = WuiSplitColumnContainer()
    private var hasPlacedSidebar = false
    /// The window toolbar this split aligns with, when the window has one.
    private weak var windowToolbar: WuiWindowToolbar?
    /// Whether the pane containing this split is the one on screen.
    private var chromeIsActive = true
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

  #if canImport(UIKit)
    override func didMoveToWindow() {
      super.didMoveToWindow()
      wuiSyncControllerHierarchy(of: splitController)
    }
  #endif

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
      // The view is attached by `wuiSyncControllerHierarchy` at window time,
      // after the controller has a parent — see that helper for why the order
      // matters.
    #elseif canImport(AppKit)
      primaryController.view = sidebarView
      // As above: one placeholder view, so one column may hold it.
      supplementaryController.view = supplementaryContainer
      secondaryController.view = secondaryContainer
      supplementaryContainer.show(emptyColumnView)
      secondaryContainer.show(placeholderView)
      // The sidebar column's contents draw on the split view's own material
      // instead of painting a background over it.
      sidebarView.setIsSidebarContent(true)
      let sidebarItem = NSSplitViewItem(sidebarWithViewController: primaryController)
      sidebarItem.minimumThickness = CGFloat(widths.min)
      sidebarItem.maximumThickness = CGFloat(widths.max)
      // The sidebar runs the whole height of the window, with the traffic
      // lights and the collapse control inside it — the arrangement every Mac
      // application with a sidebar uses. The window supplies full-size content
      // for this to have room to happen.
      sidebarItem.allowsFullHeightLayout = true
      splitController.addSplitViewItem(sidebarItem)
      if contentHandle != nil {
        splitController.addSplitViewItem(
          NSSplitViewItem(viewController: supplementaryController)
        )
      }
      // The detail column keeps the default holding priority, which is below the
      // sidebar's: holding priority is resistance to being resized, so the low
      // one is the column that absorbs the window's width. Raising the detail's
      // instead made it hold the width it starts at — zero, since a column of
      // `WaterUI` views has no intrinsic width of its own — and the sidebar
      // swallowed the whole window while the detail column stayed empty.
      //
      // Every style therefore arranges the same way here: a Mac sidebar already
      // holds its width while the detail takes the rest, and collapses first
      // when the window runs out of room. The style is what a compact platform
      // needs in order to decide which column to show at all.
      switch style {
      case WuiNavigationSplitStyle_Automatic,
        WuiNavigationSplitStyle_Balanced,
        WuiNavigationSplitStyle_ProminentDetail:
        break
      default:
        fatalError("Unsupported navigation split style: \(style.rawValue)")
      }
      splitController.addSplitViewItem(NSSplitViewItem(viewController: secondaryController))
      splitController.view.translatesAutoresizingMaskIntoConstraints = true
      addSubview(splitController.view)
    #endif
  }

  private func showPrimarySelection(_ selected: Int32) {
    guard let contentHandle else {
      showDetailSelection(selected)
      return
    }
    if selected == 0 {
      #if canImport(UIKit)
        splitController.setViewController(supplementaryController, for: .supplementary)
        if splitController.isCollapsed { splitController.show(.primary) }
      #elseif canImport(AppKit)
        supplementaryController.view = emptyColumnView
      #endif
      return
    }

    #if canImport(UIKit)
      let controller = destinationController(
        for: selected, handle: contentHandle, cache: &contentControllers)
      splitController.setViewController(controller, for: .supplementary)
      splitController.show(.supplementary)
    #elseif canImport(AppKit)
      let content = destinationView(for: selected, handle: contentHandle, cache: &contentViews)
      content.setBackAction(nil)
      supplementaryContainer.show(content)
    #endif
  }

  private func showSecondarySelection(_ selected: Int32) {
    guard secondarySelection != nil else { return }
    showDetailSelection(selected)
  }

  private func showDetailSelection(_ selected: Int32) {
    if selected == 0 {
      #if canImport(UIKit)
        splitController.setViewController(secondaryController, for: .secondary)
        if splitController.isCollapsed {
          splitController.show(contentHandle == nil ? .primary : .supplementary)
        }
      #elseif canImport(AppKit)
        secondaryContainer.show(placeholderView)
      #endif
      return
    }

    #if canImport(UIKit)
      let controller = destinationController(
        for: selected, handle: detailHandle, cache: &detailControllers)
      splitController.setViewController(controller, for: .secondary)
      splitController.show(.secondary)
    #elseif canImport(AppKit)
      let detail = destinationView(for: selected, handle: detailHandle, cache: &detailViews)
      detail.setBackAction(nil)
      secondaryContainer.show(detail)
    #endif
  }

  #if canImport(UIKit)
    /// One destination as a column page: the platform column bar shows its
    /// chrome (title, back, large-title mode) through `navigationItem`, the
    /// way every UIKit split-view column works — including the collapsed
    /// form, where the system pushes the page and provides the back button.
    /// Popping back through that system back clears the selection via the
    /// split delegate's `willShow` callback.
    private func destinationController(
      for selected: Int32,
      handle: UnsafeMutablePointer<CWaterUI.WuiNavigationSplitDetail>,
      cache: inout [Int32: WuiContentViewController]
    ) -> WuiContentViewController {
      if let cached = cache[selected] { return cached }
      let navView = waterui_split_navigation_detail_content(
        handle,
        CWaterUI.WuiId(inner: selected),
        env.inner
      )
      let controller = WuiContentViewController(
        contentView: WuiAnyView(anyview: navView.content, env: env),
        barState: makeNavigationBarState(from: navView.bar, env: env),
        destinationState: WuiNavigationDestinationState(navView.state, env: env),
        isRoot: true,
        env: env
      )
      controller.navigationItem.largeTitleDisplayMode = wuiLargeTitleDisplayMode(
        navView.bar.display_mode)
      cache[selected] = controller
      return controller
    }
  #elseif canImport(AppKit)
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
  #endif

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

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      splitController.joinControllerHierarchy(of: window)
      guard let window, window.hasTitlebar else {
        windowToolbar?.setSidebarSplitView(nil)
        windowToolbar = nil
        return
      }
      windowToolbar = WuiWindowToolbar.attached(to: window)
      if chromeIsActive {
        windowToolbar?.setSidebarSplitView(splitController.splitView)
      }
    }

    /// Whether a container showing one child at a time lets this split align
    /// the window toolbar with its sidebar; see
    /// `NSView.setNavigationChromeActive(_:)`.
    func setChromeActive(_ active: Bool) {
      guard chromeIsActive != active else { return }
      chromeIsActive = active
      windowToolbar?.setSidebarSplitView(active ? splitController.splitView : nil)
    }

    override func layout() {
      super.layout()
      splitController.view.frame = bounds
      // A split view divides whatever width it is given, so the sidebar's ideal
      // width can only be applied once there is a width to divide. Applied once:
      // after that the divider is the reader's to move.
      if !hasPlacedSidebar, bounds.width > CGFloat(widths.ideal) {
        hasPlacedSidebar = true
        splitController.splitView.setPosition(CGFloat(widths.ideal), ofDividerAt: 0)
      }
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
      // Deferred one hop: this fires inside the split view's own layout
      // transition, and writing the binding immediately re-enters that
      // transition through the selection watcher (which shows columns).
      // The write also crosses into Rust, where a panic at this depth
      // cannot unwind. One main-actor hop runs it after the transition.
      if column == .primary, primarySelection.value != 0 {
        let selection = primarySelection
        Task { @MainActor in
          if selection.value != 0 { selection.set(0) }
        }
      } else if column == .supplementary,
        let secondarySelection,
        secondarySelection.value != 0
      {
        Task { @MainActor in
          if secondarySelection.value != 0 { secondarySelection.set(0) }
        }
      }
    }
  }
#endif

#if canImport(AppKit)
  extension NSSplitViewController {
    /// Joins the window's view-controller hierarchy.
    ///
    /// A split view controller that belongs to no parent never receives the
    /// appearance callbacks AppKit drives its columns from, and its sidebar
    /// item is not treated as a window's sidebar at all. The view stays exactly
    /// where the layout engine put it; only the controller relationship is
    /// added.
    func joinControllerHierarchy(of window: NSWindow?) {
      guard let window, let root = window.contentViewController, parent !== root else {
        return
      }
      root.addChild(self)
    }
  }

  /// One split-view column, whose contents change while the column does not.
  ///
  /// A split view arranges the view each item's controller had at the moment the
  /// item was added, so replacing a controller's `view` later swaps a view the
  /// split view is no longer arranging: the column keeps showing the old one, or
  /// nothing. The column is this container from the start, and selecting a
  /// destination changes the child inside it.
  @MainActor
  final class WuiSplitColumnContainer: NSView {
    nonisolated override var isFlipped: Bool { true }

    /// Makes `view` the column's only content.
    func show(_ view: NSView) {
      guard view.superview !== self else { return }
      for existing in subviews {
        existing.removeFromSuperview()
      }
      view.removeFromSuperview()
      view.frame = contentFrame
      view.autoresizingMask = [.width, .height]
      addSubview(view)
      needsLayout = true
    }

    override func layout() {
      super.layout()
      for subview in subviews {
        subview.frame = contentFrame
      }
    }

    /// The column's bounds less its safe area: with a full-height sidebar the
    /// window toolbar floats over the non-sidebar columns, and their contents
    /// belong below it.
    private var contentFrame: CGRect {
      let insets = safeAreaInsets
      return CGRect(
        x: insets.left,
        y: insets.top,
        width: bounds.width - insets.left - insets.right,
        height: bounds.height - insets.top - insets.bottom
      )
    }
  }
#endif

/// A split view projects into the platform's own split container, which owns
/// its columns' chrome and insets; the window hands it the full bounds.
extension WuiNavigationSplitView: WuiSafeAreaManaging {}
