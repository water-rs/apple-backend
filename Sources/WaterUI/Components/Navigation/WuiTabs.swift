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
  /// The icon as a view, when the platform does not know it as a symbol.
  ///
  /// Rendering it is asynchronous, so the tab item is created without an image
  /// and the image arrives afterwards. Holding the view here keeps it alive
  /// until then.
  let iconView: WuiAnyView?
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
    iconView: WuiAnyView?,
    contentHandle: OpaquePointer,
    content: WuiNavigationView,
    enabled: WuiComputed<Bool>,
    badge: WuiComputed<Int32>?
  ) {
    self.id = id
    self.title = title
    self.icon = icon
    self.iconView = iconView
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

/// The tab's icon as a symbol the platform already knows, if it is one.
///
/// A symbol is the better of the two sources: the platform draws it itself, so
/// it stays vector, picks up the bar's tint and selection state, and follows
/// Dynamic Type. Any other icon is a view, and a view has to be rendered into an
/// image — see `installIconViews()`, which does it asynchronously because
/// rendering one means driving a GPU surface through a frame.
@MainActor
private func tabBarSystemIcon(from tab: CWaterUI.WuiTab) -> PlatformImage? {
  guard let systemIcon = tab.system_icon else { return nil }
  let name = WuiStr(waterui_menu_item_take_icon(systemIcon).name).toString()
  guard !name.isEmpty else { return nil }
  #if canImport(UIKit)
    return UIImage(systemName: name)
  #elseif canImport(AppKit)
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)
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
    private var tabControl: NSSegmentedControl?
    private weak var windowToolbar: WuiWindowToolbar?
    private var visibleIndex = 0
    /// Set for the sidebar form; the split view owns the layout then.
    private var splitController: NSSplitViewController?
    private var sidebarTable: NSTableView?
    private var sidebarContentHost: NSView?
    private var sidebarIcons: [Int: PlatformImage] = [:]
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
        icon: tabBarSystemIcon(from: tab),
        iconView: tab.icon.map { WuiAnyView(anyview: $0, env: env) },
        contentHandle: contentHandle,
        content: WuiNavigationView(ffiNav: navigationView, env: env),
        enabled: WuiComputed<Bool>(enabledPointer),
        badge: tab.badge.map(WuiComputed<Int32>.init)
      )
    }

    super.init(frame: .zero)
    configureNativeController()
    installIconViews()
    #if canImport(AppKit)
      installSidebarIcons()
    #endif
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
      for tab in tabs {
        tab.content.translatesAutoresizingMaskIntoConstraints = true
        tab.content.isHidden = true
      }

      switch style {
      case WuiTabStyle_Automatic, WuiTabStyle_TabBar:
        configureToolbarTabs()
      case WuiTabStyle_Sidebar:
        configureSidebarTabs()
      default:
        fatalError("Unsupported Apple tab style: \(style.rawValue)")
      }
    #endif
  }

  #if canImport(AppKit)
    /// Presents the tabs as one segmented control in the window toolbar.
    ///
    /// This is what the Mac shows for a window's top-level sections, and it is a
    /// control this view owns and offers to the toolbar rather than an
    /// `NSTabViewController` in its `.toolbar` style. That style seizes the
    /// window's toolbar and becomes its delegate, leaving no room for the
    /// navigation chrome of the tab on screen — the Mac shows both at once, so
    /// both must go through one toolbar. See `WuiWindowToolbar`.
    private func configureToolbarTabs() {
      let control = NSSegmentedControl(
        labels: tabs.map(\.title),
        trackingMode: .selectOne,
        target: self,
        action: #selector(segmentedControlChanged)
      )
      control.segmentStyle = .automatic
      control.sizeToFit()
      tabControl = control

      for tab in tabs {
        addSubview(tab.content)
      }
    }

    /// Presents the tabs as a full-height sidebar beside the content.
    ///
    /// The sidebar is a real `NSSplitViewItem(sidebarWithViewController:)`, which
    /// is what gives it the inset glass panel, the collapse button in the
    /// toolbar and the system's own row chrome. Rows carry icons here, unlike
    /// the toolbar form.
    private func configureSidebarTabs() {
      let sidebarList = NSTableView()
      sidebarList.headerView = nil
      sidebarList.style = .sourceList
      sidebarList.rowSizeStyle = .default
      sidebarList.selectionHighlightStyle = .regular
      sidebarList.addTableColumn(NSTableColumn(identifier: Self.sidebarColumn))
      sidebarList.dataSource = self
      sidebarList.delegate = self
      sidebarTable = sidebarList

      let scroll = NSScrollView()
      scroll.documentView = sidebarList
      scroll.hasVerticalScroller = true
      scroll.drawsBackground = false

      let sidebarController = NSViewController()
      sidebarController.view = scroll

      let contentHost = NSView()
      for tab in tabs {
        contentHost.addSubview(tab.content)
      }
      sidebarContentHost = contentHost
      let contentController = NSViewController()
      contentController.view = contentHost

      let split = NSSplitViewController()
      let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
      sidebarItem.minimumThickness = 180
      split.addSplitViewItem(sidebarItem)
      split.addSplitViewItem(NSSplitViewItem(viewController: contentController))
      split.view.translatesAutoresizingMaskIntoConstraints = true
      splitController = split
      addSubview(split.view)
    }

    private static let sidebarColumn = NSUserInterfaceItemIdentifier("dev.waterui.tabs.sidebar")

    // The sidebar's table talks to this view through the extension below, which
    // cannot see private storage — these are its window onto it.
    var tabCount: Int { tabs.count }
    var sidebarTableView: NSTableView? { sidebarTable }

    func tabEnabled(at row: Int) -> Bool {
      tabs.indices.contains(row) && tabs[row].enabled.value
    }

    /// One sidebar row: the tab's icon beside its title, as the source list draws it.
    func sidebarRowView(at row: Int) -> NSView? {
      guard tabs.indices.contains(row) else { return nil }
      let cell = NSTableCellView()
      let title = NSTextField(labelWithString: tabs[row].displayTitle(badge: badgeValue(at: row)))
      title.translatesAutoresizingMaskIntoConstraints = false
      cell.addSubview(title)
      cell.textField = title

      var titleLeading = title.leadingAnchor.constraint(
        equalTo: cell.leadingAnchor, constant: 4)
      if let icon = sidebarIcons[row] {
        let imageView = NSImageView(image: icon)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(imageView)
        cell.imageView = imageView
        NSLayoutConstraint.activate([
          imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
          imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
          imageView.widthAnchor.constraint(equalToConstant: 18),
          imageView.heightAnchor.constraint(equalToConstant: 18),
        ])
        titleLeading = title.leadingAnchor.constraint(
          equalTo: imageView.trailingAnchor, constant: 6)
      }
      NSLayoutConstraint.activate([
        titleLeading,
        title.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        title.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
      ])
      return cell
    }

    private func badgeValue(at row: Int) -> Int32 {
      tabs.indices.contains(row) ? (tabs[row].badge?.value ?? 0) : 0
    }
  #endif

  /// Fills in the icons that are views rather than symbols.
  ///
  /// A view icon is a scene on a GPU surface, so producing an image from it
  /// means attaching it to a window and driving a frame — asynchronous work the
  /// tab item cannot wait on. The item is therefore created without an image and
  /// gains one when the render lands, which is invisible in practice: it
  /// resolves within the first frames of the bar appearing.
  ///
  /// The Mac's toolbar tab control shows titles only — the system's own tabs
  /// carry no image there — so icons are rendered for the platforms that draw
  /// them and skipped where they would not be shown.
  private func installIconViews() {
    #if canImport(UIKit)
      for (index, tab) in tabs.enumerated() {
        guard let iconView = tab.iconView else { continue }
        Task { @MainActor [weak self] in
          guard let image = await renderViewToTemplateImage(iconView, maxSide: Self.iconMaxSide)
          else { return }
          self?.applyIcon(image, at: index)
        }
      }
    #endif
  }

  #if canImport(UIKit)
    /// The size a tab icon is rendered at, matching what the platform draws.
    ///
    /// A phone's tab bar icon is roughly 25pt. The image is a bitmap, so the bar
    /// scales it rather than laying it out, and rendering at the wrong size is
    /// visible.
    private static let iconMaxSide: CGFloat = 25

    private func applyIcon(_ image: PlatformImage, at index: Int) {
      guard let controllers = tabController.viewControllers, controllers.indices.contains(index)
      else { return }
      controllers[index].tabBarItem.image = image
    }
  #endif

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
      tabControl?.setLabel(tabs[index].displayTitle(badge: count), forSegment: index)
      tabControl?.sizeToFit()
      offerTabsToToolbar()
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
      showTab(at: index)
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
      if let splitController {
        // The split view owns the layout in the sidebar form; each tab's content
        // fills the detail side.
        splitController.view.frame = bounds
        if let host = sidebarContentHost {
          for tab in tabs {
            tab.content.frame = host.bounds
          }
        }
        return
      }
      for tab in tabs {
        tab.content.frame = bounds
      }
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard let window, window.hasTitlebar else {
        windowToolbar?.setTabs(nil)
        windowToolbar = nil
        return
      }
      windowToolbar = WuiWindowToolbar.attached(to: window)
      offerTabsToToolbar()
      showTab(at: visibleIndex)
    }

    /// Hands the tab control to the window toolbar, where the Mac shows tabs.
    private func offerTabsToToolbar() {
      windowToolbar?.setTabs(tabControl)
    }

    /// Shows one tab's content, hiding the rest.
    private func showTab(at index: Int) {
      guard tabs.indices.contains(index) else { return }
      visibleIndex = index
      let contentBounds = sidebarContentHost?.bounds ?? bounds
      for (position, tab) in tabs.enumerated() {
        let isVisible = position == index
        tab.content.isHidden = !isVisible
        tab.content.frame = contentBounds
        // Every tab's content stays in the window whether or not it is showing,
        // so hiding it does not move it out of the window and nothing tells the
        // navigation stack inside it to stop contributing chrome. Say so
        // explicitly, or whichever stack published last owns the toolbar
        // regardless of which tab the user is looking at.
        tab.content.setNavigationChromeActive(isVisible)
      }
      tabControl?.selectedSegment = index
      if let sidebarTable, sidebarTable.selectedRow != index {
        sidebarTable.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
      }
    }

    @objc private func segmentedControlChanged(_ sender: NSSegmentedControl) {
      let index = sender.selectedSegment
      guard tabs.indices.contains(index) else { return }
      guard tabs[index].enabled.value else {
        // A disabled tab may not be entered; put the control back.
        sender.selectedSegment = visibleIndex
        return
      }
      selectedNativeIndex(index)
    }
  #endif

  #if canImport(AppKit)
    /// Renders the icons the sidebar form shows beside each row.
    ///
    /// The toolbar form draws no icon at all, so this is the only Mac
    /// presentation that needs them.
    private func installSidebarIcons() {
      guard splitController != nil else { return }
      for (index, tab) in tabs.enumerated() {
        if let icon = tab.icon {
          sidebarIcons[index] = icon
          sidebarTable?.reloadData()
          continue
        }
        guard let iconView = tab.iconView else { continue }
        Task { @MainActor [weak self] in
          guard let image = await renderViewToTemplateImage(iconView, maxSide: 18) else { return }
          self?.sidebarIcons[index] = image
          self?.sidebarTable?.reloadData()
        }
      }
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

#if canImport(AppKit)
  extension WuiTabs: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
      tabCount
    }

    func tableView(
      _ tableView: NSTableView,
      viewFor tableColumn: NSTableColumn?,
      row: Int
    ) -> NSView? {
      sidebarRowView(at: row)
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
      tabEnabled(at: row)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
      guard let table = notification.object as? NSTableView, table === sidebarTableView else {
        return
      }
      let row = table.selectedRow
      guard row >= 0 else { return }
      selectedNativeIndex(row)
    }
  }
#endif
