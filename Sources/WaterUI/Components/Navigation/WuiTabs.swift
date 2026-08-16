import CWaterUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

@MainActor
private final class WuiNativeTab {
  let id: Int32
  let title: String
  let icon: PlatformImage?
  let contentHandle: OpaquePointer
  let content: WuiNavigationView
  let enabled: WuiComputed<Bool>
  let badge: WuiComputed<Int32>?
  var enabledWatcher: WatcherGuard?
  var badgeWatcher: WatcherGuard?

  init(
    id: Int32,
    title: String,
    icon: PlatformImage?,
    contentHandle: OpaquePointer,
    content: WuiNavigationView,
    enabled: WuiComputed<Bool>,
    badge: WuiComputed<Int32>?
  ) {
    self.id = id
    self.title = title
    self.icon = icon
    self.contentHandle = contentHandle
    self.content = content
    self.enabled = enabled
    self.badge = badge
  }

  func displayTitle(badge count: Int32) -> String {
    count > 0 ? "\(title) (\(count))" : title
  }

  @MainActor deinit {
    waterui_drop_tab_content(contentHandle)
  }
}

#if canImport(AppKit)
  @MainActor
  private final class WuiNativeTabViewController: NSTabViewController {
    var shouldSelectIndex: ((Int) -> Bool)?
    var didSelectIndex: ((Int) -> Void)?

    /// AppKit selects the first item the moment it is inserted, and asks about
    /// it before the item is registered with the tab view — so the index comes
    /// back as `NSNotFound`. Passing that on as an array index crashed the app
    /// on the first tab.
    private func knownIndex(of tabViewItem: NSTabViewItem?, in tabView: NSTabView) -> Int? {
      guard let tabViewItem else { return nil }
      let index = tabView.indexOfTabViewItem(tabViewItem)
      return index == NSNotFound ? nil : index
    }

    override func tabView(
      _ tabView: NSTabView,
      shouldSelect tabViewItem: NSTabViewItem?
    ) -> Bool {
      guard super.tabView(tabView, shouldSelect: tabViewItem) else { return false }
      guard let index = knownIndex(of: tabViewItem, in: tabView) else { return true }
      return shouldSelectIndex?(index) ?? true
    }

    override func tabView(
      _ tabView: NSTabView,
      didSelect tabViewItem: NSTabViewItem?
    ) {
      super.tabView(tabView, didSelect: tabViewItem)
      guard let index = knownIndex(of: tabViewItem, in: tabView) else { return }
      didSelectIndex?(index)
    }
  }
#endif

/// Resolves a tab's icon into an image the platform's tab bar can host.
///
/// A tab bar item is an image beside a title, not a view, so the icon cannot
/// simply be rendered in place. Two sources, in order of fidelity:
///
/// 1. A system symbol, which the platform draws itself — it stays vector, picks
///    up the bar's tint and selection state, and follows Dynamic Type.
/// 2. Any other icon view, which has to be rasterized here. It is drawn as a
///    template so the bar still tints it, but it is a bitmap fixed at the size
///    it was rendered.
@MainActor
private func tabBarIcon(from tab: CWaterUI.WuiTab, env: WuiEnvironment) -> PlatformImage? {
  if let systemIcon = tab.system_icon {
    let name = WuiStr(waterui_menu_item_take_icon(systemIcon).name).toString()
    if !name.isEmpty {
      #if canImport(UIKit)
        return UIImage(systemName: name)
      #elseif canImport(AppKit)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)
      #endif
    }
  }

  guard let iconPointer = tab.icon else { return nil }
  let view = WuiAnyView(anyview: iconPointer, env: env)
  return rasterize(view: view)
}

/// Renders a view into a template image at the platform's tab-icon size.
///
/// The view is laid out at the size it asks for, capped to the tab-bar icon
/// size, then drawn into an image at screen scale. Template rendering hands the
/// tint back to the tab bar, which is what makes the icon respond to selection.
@MainActor
private func rasterize(view: WuiAnyView) -> PlatformImage? {
  let maxSide: CGFloat = 28
  let proposal = WuiProposalSize(width: Float(maxSide), height: Float(maxSide))
  var size = view.sizeThatFits(proposal)
  if !(size.width.isFinite && size.height.isFinite) || size.width <= 0 || size.height <= 0 {
    size = CGSize(width: maxSide, height: maxSide)
  }
  size = CGSize(width: min(size.width, maxSide), height: min(size.height, maxSide))
  view.frame = CGRect(origin: .zero, size: size)
  #if canImport(UIKit)
    view.layoutIfNeeded()
  #elseif canImport(AppKit)
    view.layoutSubtreeIfNeeded()
  #endif

  #if canImport(UIKit)
    let renderer = UIGraphicsImageRenderer(size: size)
    let image = renderer.image { context in
      view.layer.render(in: context.cgContext)
    }
    return image.withRenderingMode(.alwaysTemplate)
  #elseif canImport(AppKit)
    guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
      return nil
    }
    view.cacheDisplay(in: view.bounds, to: representation)
    let image = NSImage(size: size)
    image.addRepresentation(representation)
    image.isTemplate = true
    return image
  #endif
}

@MainActor
final class WuiTabs: PlatformView, WuiComponent {
  static var rawId: CWaterUI.WuiTypeId { waterui_tabs_id() }

  private(set) var stretchAxis: WuiStretchAxis = .both

  private let style: WuiTabStyle
  private let tabs: [WuiNativeTab]
  private let selection: WuiBinding<WuiId>
  private var selectionWatcher: WatcherGuard?
  private var synchronizingSelection = false

  #if canImport(UIKit)
    private let tabController = UITabBarController()
  #elseif canImport(AppKit)
    private let tabController = WuiNativeTabViewController()
  #endif

  convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
    self.init(ffiTabs: waterui_force_as_tabs(anyview), env: env)
  }

  init(ffiTabs: CWaterUI.WuiTabs, env: WuiEnvironment) {
    guard let selectionPointer = ffiTabs.selection else {
      fatalError("Tabs selection binding is null")
    }
    let rawTabs = WuiArray<CWaterUI.WuiTab>(ffiTabs.tabs).toArray()
    guard !rawTabs.isEmpty else {
      fatalError("Tabs requires at least one tab")
    }

    self.style = ffiTabs.style
    self.selection = WuiBinding<WuiId>(selectionPointer)
    self.tabs = rawTabs.map { tab in
      guard let labelPointer = tab.label else {
        fatalError("Tab label is null")
      }
      guard let contentHandle = tab.content else {
        fatalError("Tab content handle is null")
      }
      guard let enabledPointer = tab.enabled else {
        fatalError("Tab enabled signal is null")
      }
      let label = WuiAnyView(anyview: labelPointer, env: env)
      guard let title = extractNavigationTitleText(from: label).0, !title.isEmpty else {
        fatalError("Native Apple tabs require a semantic text label")
      }
      let navigationView = waterui_tab_content(contentHandle, env.inner)
      return WuiNativeTab(
        id: Int32(bitPattern: UInt32(truncatingIfNeeded: tab.id)),
        title: title,
        icon: tabBarIcon(from: tab, env: env),
        contentHandle: contentHandle,
        content: WuiNavigationView(ffiNav: navigationView, env: env),
        enabled: WuiComputed<Bool>(enabledPointer),
        badge: tab.badge.map(WuiComputed<Int32>.init)
      )
    }

    super.init(frame: .zero)
    configureNativeController()
    installReactiveState()
    select(id: selection.value.inner, initiatedByUser: false)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
    CGSize(
      width: proposal.width.map(CGFloat.init) ?? 320,
      height: proposal.height.map(CGFloat.init) ?? 480
    )
  }

  private func configureNativeController() {
    #if canImport(UIKit)
      tabController.delegate = self
      switch style {
      case WuiTabStyle_Automatic:
        tabController.mode = .automatic
      case WuiTabStyle_TabBar:
        tabController.mode = .tabBar
      case WuiTabStyle_Sidebar:
        tabController.mode = .tabSidebar
      default:
        fatalError("Unsupported Apple tab style: \(style.rawValue)")
      }
      tabController.viewControllers = tabs.map { tab in
        let controller = UIViewController()
        controller.view = tab.content
        controller.tabBarItem = UITabBarItem(
          title: tab.title,
          image: tab.icon,
          selectedImage: nil
        )
        return controller
      }
      tabController.view.translatesAutoresizingMaskIntoConstraints = true
      addSubview(tabController.view)

    #elseif canImport(AppKit)
      switch style {
      case WuiTabStyle_Automatic:
        // The Mac's own answer for a window's top-level sections: each tab is a
        // toolbar item with its icon above its title. `.unspecified` draws no
        // selector at all — it means "the app supplies its own" — so an
        // automatic tab container rendered with no way to change tabs.
        tabController.tabStyle = .toolbar
      case WuiTabStyle_TabBar:
        tabController.tabStyle = .segmentedControlOnTop
      case WuiTabStyle_Sidebar:
        tabController.tabStyle = .toolbar
      default:
        fatalError("Unsupported Apple tab style: \(style.rawValue)")
      }
      tabController.shouldSelectIndex = { [weak self] index in
        guard let self, self.tabs.indices.contains(index) else { return true }
        return self.tabs[index].enabled.value
      }
      tabController.didSelectIndex = { [weak self] index in
        self?.selectedNativeIndex(index)
      }
      for tab in tabs {
        let controller = NSViewController()
        controller.view = tab.content
        controller.title = tab.title
        let item = NSTabViewItem(viewController: controller)
        item.label = tab.title
        if let icon = tab.icon {
          item.image = icon
        }
        tabController.addTabViewItem(item)
      }
      tabController.view.translatesAutoresizingMaskIntoConstraints = true
      addSubview(tabController.view)
    #endif
  }

  private func installReactiveState() {
    selectionWatcher = selection.watch { [weak self] selected, _ in
      self?.select(id: selected.inner, initiatedByUser: false)
    }
    for (index, tab) in tabs.enumerated() {
      tab.enabledWatcher = tab.enabled.watch { [weak self] enabled, _ in
        self?.applyEnabled(enabled, at: index)
      }
      applyEnabled(tab.enabled.value, at: index)
      if let badge = tab.badge {
        tab.badgeWatcher = badge.watch { [weak self] count, _ in
          self?.applyBadge(count, at: index)
        }
        applyBadge(badge.value, at: index)
      }
    }
  }

  private func applyEnabled(_ enabled: Bool, at index: Int) {
    #if canImport(UIKit)
      tabController.viewControllers?[index].tabBarItem.isEnabled = enabled
    #elseif canImport(AppKit)
      _ = enabled
      _ = index
    #endif
  }

  private func applyBadge(_ count: Int32, at index: Int) {
    precondition(count >= 0, "Tab badge count cannot be negative")
    #if canImport(UIKit)
      tabController.viewControllers?[index].tabBarItem.badgeValue = count > 0 ? String(count) : nil
    #elseif canImport(AppKit)
      tabController.tabViewItems[index].label = tabs[index].displayTitle(badge: count)
    #endif
  }

  private func select(id: Int32, initiatedByUser: Bool) {
    guard let index = tabs.firstIndex(where: { $0.id == id }) else {
      fatalError("Selected tab id \(id) is not present")
    }
    if initiatedByUser && !tabs[index].enabled.value {
      return
    }

    synchronizingSelection = true
    #if canImport(UIKit)
      tabController.selectedIndex = index
    #elseif canImport(AppKit)
      tabController.selectedTabViewItemIndex = index
    #endif
    synchronizingSelection = false

    if initiatedByUser && selection.value.inner != id {
      selection.set(WuiId(inner: id))
    }
  }

  private func selectedNativeIndex(_ index: Int) {
    guard !synchronizingSelection else { return }
    guard tabs.indices.contains(index) else { return }
    select(id: tabs[index].id, initiatedByUser: true)
  }

  #if canImport(UIKit)
    override func layoutSubviews() {
      super.layoutSubviews()
      tabController.view.frame = bounds
    }
  #elseif canImport(AppKit)
    nonisolated override var isFlipped: Bool { true }

    override func layout() {
      super.layout()
      tabController.view.frame = bounds
    }
  #endif
}

#if canImport(UIKit)
  extension WuiTabs: UITabBarControllerDelegate {
    func tabBarController(
      _ tabBarController: UITabBarController,
      shouldSelect viewController: UIViewController
    ) -> Bool {
      guard let index = tabBarController.viewControllers?.firstIndex(of: viewController) else {
        fatalError("UITabBarController selected an unknown child controller")
      }
      return tabs[index].enabled.value
    }

    func tabBarController(
      _ tabBarController: UITabBarController,
      didSelect viewController: UIViewController
    ) {
      selectedNativeIndex(tabBarController.selectedIndex)
    }
  }
#endif
