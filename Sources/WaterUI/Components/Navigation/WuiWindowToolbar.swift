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
  /// toolbar button, the search field's own presentation, the spacing between
  /// items and the overflow menu when the window is too narrow. None of that can
  /// be painted by hand, and a bare view in a titlebar accessory gets none of it.
  @MainActor
  final class WuiWindowToolbar: NSObject, NSToolbarDelegate {
    /// The toolbar contribution of one navigation stack.
    struct Content {
      var showsBack = false
      var title: String?
      var titleView: NSView?
      var leading: WuiNavigationToolbarItem?
      var trailing: WuiNavigationToolbarItem?
      var search: WuiNavigationSearch?
      var onBack: (() -> Void)?
    }

    private static let backIdentifier = NSToolbarItem.Identifier("dev.waterui.navigation.back")
    private static let titleIdentifier = NSToolbarItem.Identifier("dev.waterui.navigation.title")
    private static let leadingIdentifier = NSToolbarItem.Identifier("dev.waterui.navigation.leading")
    private static let trailingIdentifier = NSToolbarItem.Identifier(
      "dev.waterui.navigation.trailing")
    private static let searchIdentifier = NSToolbarItem.Identifier("dev.waterui.navigation.search")
    private static let tabsIdentifier = NSToolbarItem.Identifier("dev.waterui.tabs")
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
    /// The split view whose sidebar the toolbar aligns itself with, when the
    /// pane on screen is a split view.
    private weak var sidebarSplitView: NSSplitView?
    /// Which navigation stack currently owns the page-level items.
    private weak var contentOwner: AnyObject?
    private var content = Content()
    private var searchCoordinator: WuiNavigationSearchCoordinator?
    private var searchField: NSSearchField?
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

    /// Offers the app-level tab control, or withdraws it when `view` is nil.
    func setTabs(_ view: NSView?) {
      tabsView = view
      window?.titleVisibility = view == nil ? .visible : .hidden
      rebuild()
    }

    /// Aligns the toolbar with a full-height sidebar, or withdraws the
    /// alignment when `splitView` is nil.
    ///
    /// The alignment is two items: the sidebar's collapse control, and a
    /// separator that tracks the split view's divider so everything after it
    /// sits over the detail column — which is where the Mac puts a window's
    /// page chrome when a sidebar runs the window's full height.
    func setSidebarSplitView(_ splitView: NSSplitView?) {
      guard sidebarSplitView !== splitView else { return }
      sidebarSplitView = splitView
      rebuild()
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
      searchField = nil
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
      window?.title = content.title ?? window?.title ?? ""
    }

    /// The toolbar's items, in order.
    ///
    /// The tab control is anchored to the toolbar's centre slot rather than
    /// placed between flexible spaces. Balancing it with spaces makes its
    /// position depend on how many items sit either side of it, so it shifts
    /// whenever the page on screen contributes a different number of actions —
    /// which is not what a Mac does: the tabs stay put and the actions move
    /// around them.
    private var currentIdentifiers: [NSToolbarItem.Identifier] {
      var identifiers: [NSToolbarItem.Identifier] = []
      if sidebarSplitView != nil {
        identifiers.append(.toggleSidebar)
        identifiers.append(Self.sidebarSeparatorIdentifier)
      }
      if content.showsBack { identifiers.append(Self.backIdentifier) }
      if content.leading != nil { identifiers.append(Self.leadingIdentifier) }
      if content.titleView != nil { identifiers.append(Self.titleIdentifier) }
      if tabsView != nil { identifiers.append(Self.tabsIdentifier) }
      identifiers.append(.flexibleSpace)
      if content.trailing != nil { identifiers.append(Self.trailingIdentifier) }
      if content.search != nil { identifiers.append(Self.searchIdentifier) }
      return identifiers
    }

    func toolbarCenteredItemIdentifiers(_ toolbar: NSToolbar) -> Set<NSToolbarItem.Identifier> {
      tabsView == nil ? [] : [Self.tabsIdentifier]
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

      case Self.searchIdentifier:
        guard let search = content.search else { return nil }
        let item = NSSearchToolbarItem(itemIdentifier: identifier)
        let coordinator = WuiNavigationSearchCoordinator(search: search)
        coordinator.attach(searchField: item.searchField)
        searchCoordinator = coordinator
        searchField = item.searchField
        return item

      case Self.sidebarSeparatorIdentifier:
        guard let sidebarSplitView else { return nil }
        return NSTrackingSeparatorToolbarItem(
          identifier: identifier,
          splitView: sidebarSplitView,
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

      default:
        return nil
      }
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
