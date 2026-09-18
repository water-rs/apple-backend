//
//  WuiWindowToolbar.swift
//
//  Bridges WaterUI navigation chrome onto the Mac's own window toolbar.
//

#if canImport(AppKit)
  import AppKit
  import CWaterUI

  /// One window's toolbar, shared by everything that contributes chrome to it.
  ///
  /// A window has exactly one toolbar, and more than one thing wants to put
  /// something in it: an app-level tab container offers its tabs, while whichever
  /// navigation stack is on screen offers that page's back button, title, actions
  /// and search field. AppKit models this as a single `NSToolbar` with one
  /// delegate, so a coordinator owns it and each contributor hands over what it
  /// wants shown.
  ///
  /// Going through `NSToolbarItem` rather than a titlebar accessory view is what
  /// gives the chrome its system appearance — the Liquid Glass capsule around a
  /// toolbar button, the spacing between items and the overflow menu when the
  /// window is too narrow. None of that can be painted by hand, and a bare view
  /// in a titlebar accessory gets none of it. The one exception is the search
  /// field: SwiftUI's `.searchable` draws it in a titlebar accessory row below
  /// the toolbar, so the search field lives there rather than between the
  /// items.
  @MainActor
  final class WuiWindowToolbar: NSObject, NSToolbarDelegate {
    /// The toolbar contribution of one navigation stack.
    struct Content {
      var showsBack = false
      var title: String?
      var titleView: NSView?
      var leading: WuiNavigationToolbarItem?
      var trailing: WuiNavigationToolbarItem?
      /// The page's status item: informational, and centred on a Mac the way
      /// SwiftUI centres a `.status` toolbar item, beside the tabs when there
      /// are any.
      var status: WuiNavigationToolbarItem?
      var search: WuiNavigationSearch?
      var onBack: (() -> Void)?
    }

    private static let backIdentifier = NSToolbarItem.Identifier("dev.waterui.navigation.back")
    private static let titleIdentifier = NSToolbarItem.Identifier("dev.waterui.navigation.title")
    private static let leadingIdentifier = NSToolbarItem.Identifier("dev.waterui.navigation.leading")
    private static let trailingIdentifier = NSToolbarItem.Identifier(
      "dev.waterui.navigation.trailing")
    private static let statusIdentifier = NSToolbarItem.Identifier(
      "dev.waterui.navigation.status")

    private static let tabsIdentifier = NSToolbarItem.Identifier("dev.waterui.tabs")
    private static let windowItemPrefix = "dev.waterui.window.item."
    private static let sidebarSeparatorIdentifier = NSToolbarItem.Identifier(
      "dev.waterui.sidebar.separator")

    /// The coordinator attached to a window, created on first use.
    ///
    /// Keyed by the window rather than stored on it, because `NSWindow` is a
    /// system class with no room for our state. The table holds the window
    /// weakly, so closing a window releases its coordinator.
    private static let coordinators = NSMapTable<NSWindow, WuiWindowToolbar>.weakToStrongObjects()

    static func attached(to window: NSWindow) -> WuiWindowToolbar {
      if let existing = coordinators.object(forKey: window) {
        return existing
      }
      let coordinator = WuiWindowToolbar(window: window)
      coordinators.setObject(coordinator, forKey: window)
      return coordinator
    }

    private weak var window: NSWindow?
    private let toolbar = NSToolbar(identifier: "dev.waterui.window")

    /// The tab control, when an app-level tab container is showing its tabs here.
    private var tabsView: NSView?
    /// The window-level toolbar content (`Window::toolbar`), one entry per
    /// child of the declared view, in order. Each becomes its own item so the
    /// toolbar can give each the capsule, spacing and overflow it gives its
    /// own items; a single hosted view would get none of that.
    private var windowItems: [NSView] = []
    /// The split view controller whose sidebar the toolbar aligns itself
    /// with, when the pane on screen is a split view.
    private weak var sidebarSplitViewController: NSSplitViewController?
    /// Tracks the sidebar's collapse state so the toggle's name follows it.
    private var sidebarCollapseObservation: NSKeyValueObservation?
    /// The collapse control currently in the toolbar, if any.
    private weak var sidebarToggle: NSToolbarItem?
    /// Which navigation stack currently owns the page-level items.
    private weak var contentOwner: AnyObject?
    private var content = Content()
    private var searchCoordinator: WuiNavigationSearchCoordinator?
    /// The accessory row showing the search field, while a search is offered.
    private var searchAccessory: NSTitlebarAccessoryViewController?
    /// Identity of the binding the accessory's coordinator is attached to, so a
    /// rebuild that offers the same search keeps the field — and its focus —
    /// instead of swapping it for a fresh one.
    private var searchSource: ObjectIdentifier?
    /// What each action item runs, keyed by the item it belongs to.
    private var itemActions: [NSToolbarItem.Identifier: () -> Void] = [:]

    private init(window: NSWindow) {
      self.window = window
      super.init()
      toolbar.delegate = self
      toolbar.displayMode = .iconOnly
      toolbar.allowsUserCustomization = false
      window.toolbar = toolbar
      // The tab control takes the title's place, exactly as SwiftUI does: a
      // window showing tabs has no separate title, and one without them keeps
      // its title in the toolbar.
      window.toolbarStyle = .unified
      // Full-size content is what lets a sidebar run the window's full height,
      // traffic lights inside it. Everything that is not a sidebar places
      // itself below the toolbar through the safe area instead.
      window.styleMask.insert(.fullSizeContentView)
    }

    /// Offers the window's own toolbar content, or withdraws it when `view` is nil.
    ///
    /// The content is whatever `Window::toolbar` declared — typically a row of
    /// buttons. Its children are split into one toolbar item each: a child
    /// that is a button with a symbol becomes a real `NSToolbarItem` running
    /// the button's action, anything else is hosted as the view it is.
    func setWindowContent(_ view: WuiAnyView?) {
      windowItems = view.map(Self.toolbarChildren) ?? []
      rebuild()
    }

    /// The views `Window::toolbar` content splits into.
    ///
    /// A declared row is a stack of children behind whatever single-child
    /// wrappers (padding, an environment install) the declaration added, so
    /// the walk descends through lone children and stops at the first view
    /// with several — those are the items. A declaration that is a single
    /// leaf is one item.
    private static func toolbarChildren(of view: NSView) -> [NSView] {
      var node: NSView = view
      while node.subviews.count == 1 {
        node = node.subviews[0]
      }
      return node.subviews.isEmpty ? [node] : node.subviews
    }

    /// Offers the app-level tab control, or withdraws it when `view` is nil.
    func setTabs(_ view: NSView?) {
      tabsView = view
      updateTitleVisibility()
      rebuild()
    }

    /// Aligns the toolbar with a full-height sidebar, or withdraws the
    /// alignment when `controller` is nil.
    ///
    /// The alignment is two items: the sidebar's collapse control, and a
    /// separator that tracks the split view's divider so everything after it
    /// sits over the detail column — which is where the Mac puts a window's
    /// page chrome when a sidebar runs the window's full height.
    func setSidebarSplitView(_ controller: NSSplitViewController?) {
      guard sidebarSplitViewController !== controller else { return }
      sidebarSplitViewController = controller
      sidebarCollapseObservation = sidebarItem?.observe(\.isCollapsed) {
        [weak self] _, change in
        let collapsed = change.newValue ?? false
        Task { @MainActor [weak self] in
          self?.updateSidebarToggleLabel(collapsed: collapsed)
        }
      }
      updateTitleVisibility()
      rebuild()
    }

    /// Whether the window title is painted in the titlebar.
    ///
    /// The Mac's own full-height-sidebar apps — Mail, Notes, Reminders — show
    /// no title text next to the traffic lights; the window title still exists
    /// for the Window menu and Mission Control, it is just not drawn. A tab
    /// control takes the title's place the same way.
    private func updateTitleVisibility() {
      window?.titleVisibility =
        tabsView != nil || sidebarSplitViewController != nil ? .hidden : .visible
    }

    /// The sidebar's split view item, when a split owns the toolbar's leading
    /// edge.
    private var sidebarItem: NSSplitViewItem? {
      sidebarSplitViewController?.splitViewItems.first { $0.behavior == .sidebar }
    }

    /// Names the collapse control after what it will do, as the Mac's own
    /// sidebar apps do: "Hide Sidebar" while the sidebar is up, "Show Sidebar"
    /// once it is tucked away.
    private func updateSidebarToggleLabel(collapsed: Bool) {
      let label = collapsed ? "Show Sidebar" : "Hide Sidebar"
      sidebarToggle?.label = label
      sidebarToggle?.paletteLabel = label
      sidebarToggle?.toolTip = label
    }

    /// Offers one navigation stack's chrome, claiming the toolbar for `owner`.
    ///
    /// Only the stack that is actually on screen may contribute: several stacks
    /// exist at once when tabs are involved, and a stack that has been switched
    /// away from must not leave its buttons behind in the toolbar.
    func setContent(_ content: Content, owner: AnyObject) {
      contentOwner = owner
      self.content = content
      rebuild()
    }

    /// Withdraws `owner`'s chrome, if it still holds the toolbar.
    func clearContent(owner: AnyObject) {
      guard contentOwner === owner else { return }
      contentOwner = nil
      content = Content()
      searchCoordinator = nil
      rebuild()
    }

    private func rebuild() {
      // Rebuilding from scratch keeps the item order honest: the identifiers a
      // toolbar shows are computed from what is currently offered, so removing
      // and re-adding is the whole update.
      while !toolbar.items.isEmpty {
        toolbar.removeItem(at: toolbar.items.count - 1)
      }
      for (index, identifier) in currentIdentifiers.enumerated() {
        toolbar.insertItem(withItemIdentifier: identifier, at: index)
      }
      toolbar.centeredItemIdentifiers = centeredIdentifiers
      window?.title = content.title ?? window?.title ?? ""
      updateSearchAccessory()
    }

    /// Keeps the search accessory row in step with the offered content.
    ///
    /// SwiftUI's `.searchable` on a Mac window is not a toolbar item: it is a
    /// titlebar accessory row pinned to the bottom of the titlebar, 38 pt tall
    /// with the field centered at 41% of the window's width — measured off the
    /// SwiftUI reference window. Only a *different* search replaces the row;
    /// rebuilding for the same one leaves it alone, so typing into the field
    /// never loses focus to a toolbar rebuild.
    private func updateSearchAccessory() {
      let source = content.search.map { ObjectIdentifier($0.text) }
      guard source != searchSource else { return }
      searchSource = source

      if let accessory = searchAccessory,
        let index = window?.titlebarAccessoryViewControllers.firstIndex(of: accessory)
      {
        window?.removeTitlebarAccessoryViewController(at: index)
      }
      searchAccessory = nil
      searchCoordinator = nil

      guard let search = content.search else {
        chargeSearchRowHeight(0)
        return
      }
      let accessory = NSTitlebarAccessoryViewController()
      accessory.layoutAttribute = .bottom
      let container = NSView()
      let field = NSSearchField(frame: .zero)
      field.translatesAutoresizingMaskIntoConstraints = false
      container.addSubview(field)
      NSLayoutConstraint.activate([
        field.centerXAnchor.constraint(equalTo: container.centerXAnchor),
        field.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        field.widthAnchor.constraint(equalTo: container.widthAnchor, multiplier: 0.41),
        field.heightAnchor.constraint(equalToConstant: 28),
        container.heightAnchor.constraint(equalToConstant: Self.searchRowHeight),
      ])
      accessory.view = container
      // The titlebar gives the row the height of the frame it is handed at
      // insert; the height constraint alone is not consulted and the row
      // settles a couple of points short. Assigning the view resets that
      // frame, so it is written after the assignment.
      accessory.view.frame = NSRect(
        x: 0, y: 0, width: window?.frame.width ?? 0, height: Self.searchRowHeight)
      window?.addTitlebarAccessoryViewController(accessory)
      let coordinator = WuiNavigationSearchCoordinator(search: search)
      coordinator.attach(searchField: field)
      searchCoordinator = coordinator
      searchAccessory = accessory
      chargeSearchRowHeight(Self.searchRowHeight)
    }

    /// The search row's height, measured off the SwiftUI window's accessory.
    private static let searchRowHeight: CGFloat = 38

    /// The row height currently charged to the window's frame.
    private var chargedSearchRowHeight: CGFloat = 0

    /// Spends or returns the search row's height in the window's frame.
    ///
    /// The row is chrome, so SwiftUI spends it from the window's height, not
    /// the content's: its `.fullSizeContentView` collapse runs after the
    /// accessory exists, and the reference window ends up exactly the row's
    /// height shorter than a toolbar-only one. Here the flag is already in
    /// place when the search arrives — an accessory added afterwards eats
    /// content instead — so the frame absorbs the row directly.
    private func chargeSearchRowHeight(_ height: CGFloat) {
      guard let window else { return }
      let delta = height - chargedSearchRowHeight
      guard delta != 0 else { return }
      chargedSearchRowHeight = height
      guard window.styleMask.contains(.fullSizeContentView) else { return }
      var frame = window.frame
      frame.size.height -= delta
      window.setFrame(frame, display: true)
    }

    /// The toolbar's items, in order.
    ///
    /// The tab control is anchored to the toolbar's centre slot rather than
    /// placed between flexible spaces. Balancing it with spaces makes its
    /// position depend on how many items sit either side of it, so it shifts
    /// whenever the page on screen contributes a different number of actions —
    /// which is not what a Mac does: the tabs stay put and the actions move
    /// around them.
    /// The items the toolbar keeps at its centre, as one group: the tabs and
    /// the page's status item share the slot, so the status text sits beside
    /// the tab control rather than being pushed about by the actions.
    private var centeredIdentifiers: Set<NSToolbarItem.Identifier> {
      var identifiers: Set<NSToolbarItem.Identifier> = []
      if tabsView != nil { identifiers.insert(Self.tabsIdentifier) }
      if content.status != nil { identifiers.insert(Self.statusIdentifier) }
      return identifiers
    }

    private var currentIdentifiers: [NSToolbarItem.Identifier] {
      var identifiers: [NSToolbarItem.Identifier] = []
      if sidebarSplitViewController != nil {
        // The toggle hugs the divider, not the toolbar's leading edge: SwiftUI
        // parks it against the tracking separator at the sidebar's trailing
        // edge, so a flexible space does the pushing.
        identifiers.append(.flexibleSpace)
        identifiers.append(.toggleSidebar)
        identifiers.append(Self.sidebarSeparatorIdentifier)
      }
      if content.showsBack { identifiers.append(Self.backIdentifier) }
      if content.leading != nil { identifiers.append(Self.leadingIdentifier) }
      if content.titleView != nil { identifiers.append(Self.titleIdentifier) }
      if tabsView != nil { identifiers.append(Self.tabsIdentifier) }
      if content.status != nil { identifiers.append(Self.statusIdentifier) }
      identifiers.append(.flexibleSpace)
      // The window's own items sit outside the page's: the page's actions and
      // its search field stay together at the trailing edge, where the page
      // that owns them is used to finding them.
      for index in windowItems.indices {
        identifiers.append(Self.windowItemIdentifier(index))
      }
      if content.trailing != nil { identifiers.append(Self.trailingIdentifier) }
      return identifiers
    }

    // MARK: - NSToolbarDelegate

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
      currentIdentifiers
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
      currentIdentifiers
    }

    func toolbar(
      _ toolbar: NSToolbar,
      itemForItemIdentifier identifier: NSToolbarItem.Identifier,
      willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
      switch identifier {
      case Self.backIdentifier:
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.image = NSImage(
          systemSymbolName: "chevron.backward", accessibilityDescription: "Back")
        item.label = "Back"
        item.isNavigational = true
        item.target = self
        item.action = #selector(backInvoked)
        return item

      case .toggleSidebar:
        // A plain item rather than the system-vended one: the system's own
        // toggle names itself "Sidebar" forever, while the Mac's sidebar apps
        // name the control after what it does — "Hide Sidebar" up, "Show
        // Sidebar" down. The target is the split view controller directly so
        // the action does not depend on the responder chain's mood.
        let item = NSToolbarItem(itemIdentifier: identifier)
        // No accessibility description on the image — the item's label
        // already says what the control does, and it changes with the
        // sidebar's state.
        item.image = NSImage(systemSymbolName: "sidebar.leading", accessibilityDescription: nil)
        item.isNavigational = true
        item.target = sidebarSplitViewController
        item.action = #selector(NSSplitViewController.toggleSidebar(_:))
        sidebarToggle = item
        updateSidebarToggleLabel(collapsed: sidebarItem?.isCollapsed ?? false)
        return item

      case Self.sidebarSeparatorIdentifier:
        guard let splitView = sidebarSplitViewController?.splitView else { return nil }
        return NSTrackingSeparatorToolbarItem(
          identifier: identifier,
          splitView: splitView,
          dividerIndex: 0
        )

      case Self.tabsIdentifier:
        return hostingItem(identifier: identifier, view: tabsView)

      case Self.titleIdentifier:
        return hostingItem(identifier: identifier, view: content.titleView)

      case Self.leadingIdentifier:
        let item = actionItem(identifier: identifier, from: content.leading)
        item?.isNavigational = true
        return item

      case Self.trailingIdentifier:
        return actionItem(identifier: identifier, from: content.trailing)

      case Self.statusIdentifier:
        return hostingItem(identifier: identifier, view: content.status?.view)

      default:
        guard let index = Self.windowItemIndex(identifier) else { return nil }
        return windowItem(identifier: identifier, view: windowItems[index])
      }
    }

    private static func windowItemIdentifier(_ index: Int) -> NSToolbarItem.Identifier {
      NSToolbarItem.Identifier(windowItemPrefix + String(index))
    }

    private static func windowItemIndex(_ identifier: NSToolbarItem.Identifier) -> Int? {
      guard identifier.rawValue.hasPrefix(windowItemPrefix) else { return nil }
      return Int(identifier.rawValue.dropFirst(windowItemPrefix.count))
    }

    /// Builds a toolbar item for one child of the window's toolbar content.
    ///
    /// A button whose label draws a platform symbol becomes a real
    /// `NSToolbarItem` — icon in the glass capsule, name kept for the overflow
    /// menu, tooltip and assistive technology, running the button's action —
    /// exactly as a navigation action does. Any other child is hosted as the
    /// view it is.
    private func windowItem(identifier: NSToolbarItem.Identifier, view: NSView) -> NSToolbarItem? {
      guard let button = view.firstButton, let symbol = button.systemIconName else {
        return hostingItem(identifier: identifier, view: view)
      }
      let item = NSToolbarItem(itemIdentifier: identifier)
      item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
      let label = button.semanticTitle
      item.label = label
      item.paletteLabel = label
      item.toolTip = label.isEmpty ? nil : label
      item.isBordered = true
      item.target = self
      item.action = #selector(actionInvoked(_:))
      itemActions[identifier] = { [weak button] in
        button?.invokeAction()
      }
      return item
    }

    /// Builds a toolbar item for one navigation action.
    ///
    /// An action declared as a semantic label becomes a real `NSToolbarItem`
    /// with an image and a label, which is what makes it look like the Mac's own
    /// chrome: the toolbar shows the icon inside a glass capsule, keeps the name
    /// for the overflow menu and the tooltip, and hands it to assistive
    /// technology. Hosting the label's view instead would draw the name beside
    /// the icon, which no Mac toolbar does.
    ///
    /// An item with no semantic label — arbitrary content — can only be hosted
    /// as the view it is.
    private func actionItem(
      identifier: NSToolbarItem.Identifier,
      from action: WuiNavigationToolbarItem?
    ) -> NSToolbarItem? {
      guard let action else { return nil }
      // With no icon at all there is nothing to draw but the label's own view —
      // a text-only action like "Edit" is a bordered toolbar button showing its
      // text, which is what the Mac does too.
      guard action.systemIconName != nil || action.iconView != nil else {
        return hostingItem(identifier: identifier, view: action.view)
      }

      let item = NSToolbarItem(itemIdentifier: identifier)
      if let name = action.systemIconName {
        item.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
      } else if let iconView = action.iconView {
        // Not a symbol the platform knows — a packaged icon set, say — so it is
        // a scene on a GPU surface and has to be rendered into an image before
        // the toolbar can show it. The item appears without one and gains it
        // when the render lands.
        Task { @MainActor [weak item] in
          item?.image = await renderViewToTemplateImage(iconView, maxSide: 18)
        }
      }
      let label = action.title?.value.toString() ?? ""
      item.label = label
      item.paletteLabel = label
      item.toolTip = label.isEmpty ? nil : label
      item.isBordered = true
      item.target = self
      item.action = #selector(actionInvoked(_:))
      // The label's own button carries the handler, so the toolbar item runs
      // the same action the view would have.
      itemActions[identifier] = { [weak button = action.view.firstButton] in
        button?.invokeAction()
      }
      return item
    }

    /// Wraps a `WaterUI` view in a toolbar item at the size the layout engine gives it.
    ///
    /// `fittingSize` asks AppKit's constraint system, which knows nothing about a
    /// `WaterUI` view and answers with its compressed size — a text button so
    /// measured comes back narrower than its own label and wraps it.
    private func hostingItem(
      identifier: NSToolbarItem.Identifier,
      view: NSView?
    ) -> NSToolbarItem? {
      guard let view else { return nil }
      let size =
        (view as? WuiAnyView)?.sizeThatFits(WuiProposalSize(width: nil, height: nil))
        ?? view.fittingSize
      view.removeFromSuperview()
      // Natively hosted toolbar item: measured under a fully unspecified
      // proposal, so that is the offer its own layout pass receives.
      (view as? WuiAnyView)?.setPlacementProposal(WuiProposalSize(width: nil, height: nil))
      view.frame = NSRect(origin: .zero, size: size)
      // The toolbar measures an item through the constraint system, so the size
      // the layout engine produced is stated as constraints rather than through
      // the item's own long-deprecated size bounds.
      view.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        view.widthAnchor.constraint(equalToConstant: size.width),
        view.heightAnchor.constraint(equalToConstant: size.height),
      ])

      let item = NSToolbarItem(itemIdentifier: identifier)
      item.view = view
      return item
    }

    @objc private func backInvoked() {
      content.onBack?()
    }

    @objc private func actionInvoked(_ sender: NSToolbarItem) {
      itemActions[sender.itemIdentifier]?()
    }
  }

  extension NSView {
    /// The first platform-symbol icon in this subtree.
    var firstSystemIcon: WuiSystemIcon? {
      if let icon = self as? WuiSystemIcon { return icon }
      for subview in subviews {
        if let icon = subview.firstSystemIcon { return icon }
      }
      return nil
    }

    /// The first `WaterUI` button in this subtree.
    ///
    /// Chrome built from a label's semantics rather than its view still has to
    /// run the action the caller attached to that label's button.
    var firstButton: WuiButton? {
      if let button = self as? WuiButton { return button }
      for subview in subviews {
        if let button = subview.firstButton { return button }
      }
      return nil
    }
  }

  extension NSView {
    /// Tells the navigation stacks in this subtree whether they may claim the
    /// window toolbar.
    ///
    /// A container that shows one child at a time — a tab container, say — keeps
    /// every child in the window and merely hides the ones that are not showing.
    /// Hiding does not remove a view from its window, so nothing would otherwise
    /// tell a hidden stack to stop publishing its chrome, and whichever one
    /// published last would own the toolbar no matter which tab was on screen.
    func setNavigationChromeActive(_ active: Bool) {
      if let stack = self as? WuiNavigationStack {
        stack.setChromeActive(active)
        return
      }
      if let navigationView = self as? WuiNavigationView {
        navigationView.setChromeActive(active)
        // Keep descending: a split detail inside carries a bar of its own,
        // and — claiming last — it is the one that wins the toolbar.
      }
      if let splitView = self as? WuiNavigationSplitView {
        splitView.setChromeActive(active)
      }
      for subview in subviews {
        subview.setNavigationChromeActive(active)
      }
    }

    /// Tells the lists in this subtree that they are a sidebar's contents.
    ///
    /// Said explicitly by whoever owns the sidebar, because a list cannot tell
    /// from its own ancestry: whether AppKit has inserted its material view by
    /// the time the list reaches the window is not something to depend on.
    func setIsSidebarContent(_ isSidebar: Bool) {
      if let list = self as? WuiList {
        list.applySidebarPresentation(isSidebar)
        return
      }
      for subview in subviews {
        subview.setIsSidebarContent(isSidebar)
      }
    }
  }
#endif
