import CWaterUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

/// How many split destinations keep their rendered tree.
///
/// Caching one is what preserves a page's scroll position and half-typed input
/// when the user comes back to it, so the cache has to hold more than the
/// current destination. It must not hold *every* destination ever visited,
/// though: each is a rendered view tree and its navigation state, retained for
/// the life of the split — a gallery browsed a thousand deep retains a thousand
/// of them. Eight covers the back-and-forth people actually do; past that the
/// least recently shown one is released and rebuilt if it is wanted again,
/// losing only that page's transient state. The GTK and Android backends use
/// the same number for the same reason.
private let splitDestinationCacheCapacity = 8

/// A bounded cache keyed by destination id, evicting the least recently used.
///
/// A Swift dictionary has no order, so the order is kept alongside it: reading
/// or writing a key moves it to the young end, and an insert past capacity
/// releases the old end. Releasing is the whole teardown — ARC frees the view
/// tree, and an evicted destination is never the one on screen, because showing
/// it is what made it the youngest.
private struct DestinationCache<Value> {
  private var storage: [Int32: Value] = [:]
  private var order: [Int32] = []

  mutating func value(for key: Int32) -> Value? {
    guard let value = storage[key] else { return nil }
    touch(key)
    return value
  }

  mutating func insert(_ value: Value, for key: Int32) {
    if storage[key] == nil, storage.count >= splitDestinationCacheCapacity,
      let eldest = order.first
    {
      storage.removeValue(forKey: eldest)
      order.removeFirst()
    }
    storage[key] = value
    touch(key)
  }

  private mutating func touch(_ key: Int32) {
    if let index = order.firstIndex(of: key) {
      order.remove(at: index)
    }
    order.append(key)
  }
}

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
    private var contentViews = DestinationCache<WuiNavigationView>()
    private var detailViews = DestinationCache<WuiNavigationView>()
  #endif
  private var primarySelectionWatcher: WatcherGuard?
  private var secondarySelectionWatcher: WatcherGuard?
  private var visibilityWatcher: WatcherGuard?

  #if canImport(UIKit)
    private let splitController: UISplitViewController
    private let primaryController = WuiSplitColumnPageController()
    private let supplementaryController = WuiSplitColumnPageController()
    private let secondaryController = WuiSplitColumnPageController()
    private var contentControllers = DestinationCache<WuiContentViewController>()
    private var detailControllers = DestinationCache<WuiContentViewController>()
    /// The column the collapsed split last reported showing, so `didShow`
    /// can tell a real return to a column from the show it opens with.
    private var lastShownColumn: UISplitViewController.Column?
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
    private let sidebarContainer = WuiSplitColumnContainer()
    private let supplementaryContainer = WuiSplitColumnContainer()
    private let secondaryContainer = WuiSplitColumnContainer()
    private var hasPlacedSidebar = false
    #if canImport(AppKit)
      private var sidebarItem: NSSplitViewItem?
    #endif
    /// The window toolbar this split aligns with, when the window has one.
    private weak var windowToolbar: WuiWindowToolbar?
    /// Whether the pane containing this split is the one on screen.
    private var chromeIsActive = true
    /// The sidebar's own collapse state, kept while chrome is inactive so
    /// hiding the split does not erase a collapse the user made.
    private var sidebarCollapsedByChrome = false
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
    // The first application syncs content only: presenting the selection
    // would decide the collapsed split's top column, which is the sidebar
    // whether or not a destination is selected.
    showPrimarySelection(primarySelection.value, present: false)
    if let secondarySelection {
      showSecondarySelection(secondarySelection.value, present: false)
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
      primaryController.view = sidebarContainer
      // As above: one placeholder view, so one column may hold it.
      supplementaryController.view = supplementaryContainer
      secondaryController.view = secondaryContainer
      sidebarContainer.show(sidebarView)
      supplementaryContainer.show(emptyColumnView)
      secondaryContainer.show(placeholderView)
      // The sidebar column's contents draw on the split view's own material
      // instead of painting a background over it.
      sidebarView.setIsSidebarContent(true)
      let sidebarItem = NSSplitViewItem(sidebarWithViewController: primaryController)
      // The thickness bounds are re-derived in `layout()` once the column's
      // own chrome is known; until then they bound the content itself.
      sidebarItem.minimumThickness = CGFloat(widths.min)
      sidebarItem.maximumThickness = CGFloat(widths.max)
      self.sidebarItem = sidebarItem
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

  private func showPrimarySelection(_ selected: Int32, present: Bool = true) {
    guard let contentHandle else {
      showDetailSelection(selected, present: present)
      return
    }
    if selected == 0 {
      #if canImport(UIKit)
        splitController.setViewController(supplementaryController, for: .supplementary)
        if present, splitController.isCollapsed { splitController.show(.primary) }
      #elseif canImport(AppKit)
        supplementaryController.view = emptyColumnView
      #endif
      return
    }

    #if canImport(UIKit)
      let controller = destinationController(
        for: selected, handle: contentHandle, cache: &contentControllers)
      splitController.setViewController(controller, for: .supplementary)
      if present { splitController.show(.supplementary) }
    #elseif canImport(AppKit)
      let content = destinationView(for: selected, handle: contentHandle, cache: &contentViews)
      content.setBackAction(nil)
      supplementaryContainer.show(content)
    #endif
  }

  private func showSecondarySelection(_ selected: Int32, present: Bool = true) {
    guard secondarySelection != nil else { return }
    showDetailSelection(selected, present: present)
  }

  /// Reconciles the detail column's content with a selection.
  ///
  /// `present` controls whether the destination column is also made the
  /// split's visible column. A live selection change — the user tapping a
  /// sidebar row — presents it, which on a collapsed split pushes the detail
  /// over the sidebar the way SwiftUI's NavigationSplitView pushes a chosen
  /// destination. The calls that merely keep the column's content in step
  /// with the selection — first layout, collapse and expand re-syncs — pass
  /// `false`: which column is on top at those moments is the split's own
  /// decision, and re-presenting the selection there would cover the sidebar
  /// the collapse just chose.
  private func showDetailSelection(_ selected: Int32, present: Bool) {
    if selected == 0 {
      #if canImport(UIKit)
        splitController.setViewController(secondaryController, for: .secondary)
        if present, splitController.isCollapsed {
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
      if present { splitController.show(.secondary) }
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
    /// split delegate's `didShow` callback.
    private func destinationController(
      for selected: Int32,
      handle: UnsafeMutablePointer<CWaterUI.WuiNavigationSplitDetail>,
      cache: inout DestinationCache<WuiContentViewController>
    ) -> WuiContentViewController {
      if let cached = cache.value(for: selected) { return cached }
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
        // A split detail is its own root. Nothing pushes it, so there is no
        // stack whose transition it could inherit and no motion to run.
        transitionKind: navView.transition.kind == WuiNavigationTransitionKind_Inherit
          ? WuiNavigationTransitionKind_Automatic : navView.transition.kind,
        env: env
      )
      controller.navigationItem.largeTitleDisplayMode = wuiLargeTitleDisplayMode(
        navView.bar.display_mode)
      cache.insert(controller, for: selected)
      return controller
    }
  #elseif canImport(AppKit)
    private func destinationView(
      for selected: Int32,
      handle: UnsafeMutablePointer<CWaterUI.WuiNavigationSplitDetail>,
      cache: inout DestinationCache<WuiNavigationView>
    ) -> WuiNavigationView {
      if let cached = cache.value(for: selected) { return cached }
      let navigationView = waterui_split_navigation_detail_content(
        handle,
        CWaterUI.WuiId(inner: selected),
        env.inner
      )
      let destination = WuiNavigationView(ffiNav: navigationView, env: env)
      cache.insert(destination, for: selected)
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
        windowToolbar?.setSidebarSplitView(splitController)
      } else {
        applySidebarCollapse()
      }
    }

    /// Whether a container showing one child at a time lets this split align
    /// the window toolbar with its sidebar; see
    /// `NSView.setNavigationChromeActive(_:)`.
    func setChromeActive(_ active: Bool) {
      guard chromeIsActive != active else { return }
      chromeIsActive = active
      applySidebarCollapse()
      windowToolbar?.setSidebarSplitView(active ? splitController : nil)
    }

    /// Collapses the sidebar while this split's pane is off screen and puts it
    /// back the way it was when the pane returns.
    ///
    /// A split view controller joined to the window's controller hierarchy
    /// claims toolbar space for its sidebar's divider — even while the view is
    /// hidden inside an unselected tab — which pushes every toolbar item right
    /// and keeps the tab picker off the window's midpoint. Collapsing the item
    /// is what hands the space back; hiding or detaching the view alone does
    /// not.
    private func applySidebarCollapse() {
      guard let sidebar = splitController.splitViewItems.first(where: {
        $0.behavior == .sidebar
      })
      else { return }
      if chromeIsActive {
        sidebar.isCollapsed = sidebarCollapsedByChrome
      } else {
        sidebarCollapsedByChrome = sidebar.isCollapsed
        sidebar.isCollapsed = true
      }
    }

    override func layout() {
      super.layout()
      splitController.view.frame = bounds
      // A split view divides whatever width it is given, so the sidebar's ideal
      // width can only be applied once there is a width to divide. Applied once:
      // after that the divider is the reader's to move.
      if !hasPlacedSidebar, bounds.width > CGFloat(widths.ideal) {
        hasPlacedSidebar = true
        // The declared widths are the sidebar *content's*: SwiftUI's column is
        // the content plus whatever chrome the platform wraps around it — on
        // macOS 26 the sidebar's glass container insets the content 8pt from
        // the window's edge, and a 300pt ideal makes a 308pt column. The
        // chrome is read off the laid-out column rather than assumed.
        splitController.view.layoutSubtreeIfNeeded()
        let column = splitController.splitView.arrangedSubviews[0]
        let content = sidebarContainer.convert(sidebarContainer.bounds, to: column)
        let chrome = max(column.bounds.width - content.width, 0)
        if let sidebarItem {
          sidebarItem.minimumThickness = CGFloat(widths.min) + chrome
          sidebarItem.maximumThickness = CGFloat(widths.max) + chrome
        }
        splitController.splitView.setPosition(CGFloat(widths.ideal) + chrome, ofDividerAt: 0)
      }
    }
  #endif
}

#if canImport(UIKit)
  /// A split column page that owns no navigation chrome.
  ///
  /// UIKit wraps every split column in a navigation controller, and its bar
  /// reserves height in the column's safe area even when it draws nothing —
  /// on a collapsed split the sidebar's content then starts a bar's height
  /// below where SwiftUI's NavigationSplitView puts it. A chrome-less page
  /// hides that bar while it is the stack's base page; pushed over the
  /// sidebar — the way a collapsed split presents a detail or placeholder —
  /// it keeps the bar for the back affordance.
  @MainActor
  final class WuiSplitColumnPageController: UIViewController {
    override func viewWillAppear(_ animated: Bool) {
      super.viewWillAppear(animated)
      let isBasePage = navigationController?.viewControllers.first === self
      navigationController?.setNavigationBarHidden(isBasePage, animated: animated)
    }
  }

  extension WuiNavigationSplitView: UISplitViewControllerDelegate {
    func splitViewController(
      _ splitViewController: UISplitViewController,
      topColumnForCollapsingToProposedTopColumn proposedTopColumn: UISplitViewController.Column
    ) -> UISplitViewController.Column {
      // SwiftUI collapses a NavigationSplitView onto its sidebar whatever the
      // selection — the destination's row stays highlighted and the detail is
      // where a tap goes from there, not what covers the sidebar at collapse.
      .primary
    }

    // The collapse and expand transitions re-sync each column's content with
    // the selection but never present it: the split itself just chose which
    // column is on top — the sidebar on collapse — and pushing the selected
    // destination here would cover it.
    func splitViewControllerDidCollapse(_ splitViewController: UISplitViewController) {
      showPrimarySelection(primarySelection.value, present: false)
      if let secondarySelection {
        showSecondarySelection(secondarySelection.value, present: false)
      }
    }

    func splitViewControllerDidExpand(_ splitViewController: UISplitViewController) {
      showPrimarySelection(primarySelection.value, present: false)
      if let secondarySelection {
        showSecondarySelection(secondarySelection.value, present: false)
      }
    }

    func splitViewController(
      _ splitViewController: UISplitViewController,
      didShow column: UISplitViewController.Column
    ) {
      guard splitViewController.isCollapsed else { return }
      // Selection follows the column the transition committed to, never the
      // one it attempted: `willShow` fires as the gesture starts — even a
      // one-hop deferred write then lands inside the still-running
      // interactive transition, and the selection watcher answers it by
      // calling `setViewController`/`show` on a transitioning split. That
      // swaps the outgoing page for the placeholder under the user's finger,
      // unbalances the appearance calls, and can make UIKit raise through
      // the FFI binding write, which cannot unwind. A cancelled pop never
      // reaches `didShow`, so a released-early gesture leaves the selection
      // untouched too.
      defer { lastShownColumn = column }
      // The column the split opens on arrives through this same callback, and
      // it is the split's own choice — nothing returned to it — so the
      // selection the app opened with must not be read as a pop-back. Only a
      // return to a column that was actually covered clears the selection.
      guard let lastShownColumn, lastShownColumn != column else { return }
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
        width: max(bounds.width - insets.left - insets.right, 0),
        height: max(bounds.height - insets.top - insets.bottom, 0)
      )
    }
  }
#endif

/// A split view projects into the platform's own split container, which owns
/// its columns' chrome and insets; the window hands it the full bounds.
extension WuiNavigationSplitView: WuiSafeAreaManaging {}
