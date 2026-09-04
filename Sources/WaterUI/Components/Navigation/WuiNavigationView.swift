// WuiNavigationView.swift
// Navigation view component with navigation bar
//
// # Layout Behavior
// NavigationView stretches to fill available space (greedy).
// Contains a navigation bar and content area.
//
// The bar only renders here when the destination is NOT hosted by a native
// navigation controller (e.g. inside Tabs or a split-view detail). On iOS it
// is a real standalone UINavigationBar; macOS has no native in-content bar
// primitive, so the bar is composed from the platform's own materials
// (NSVisualEffectView header material + hairline separator).

import CWaterUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

@MainActor
final class WuiNavigationView: PlatformView, WuiComponent {
  static var rawId: CWaterUI.WuiTypeId { waterui_navigation_view_id() }

  private(set) var stretchAxis: WuiStretchAxis = .both

  private let barState: WuiNavigationBarState
  private let env: WuiEnvironment
  private let contentView: WuiAnyView
  private let hasNavigationController: Bool
  private let destinationState: WuiNavigationDestinationState
  private var destinationIsActive = false

  private var titleView: WuiAnyView
  private var colorWatcher: WatcherGuard?
  private var hiddenWatcher: WatcherGuard?
  private var searchCoordinator: WuiNavigationSearchCoordinator?
  private var backAction: Action?

  #if canImport(UIKit)
    private let navigationBar = UINavigationBar()
    private let barItem = UINavigationItem()
    private var backItem: UIBarButtonItem?
    private var overlayBackButton: UIButton?
    private var searchView: UIView?
  #elseif canImport(AppKit)
    private let navBarView = NSVisualEffectView()
    private let borderView = NSView()
    private var borderObservation: WuiComputedObservation<WuiResolvedColor>?
    private var inlineBackButton: NSButton?
    private var overlayBackButton: NSButton?
    private var searchView: NSView?
    /// The window toolbar this view's chrome lives in, when the window has one.
    private weak var windowToolbar: WuiWindowToolbar?
    /// Whether a container showing one child at a time lets this view publish
    /// chrome; see `NSView.setNavigationChromeActive(_:)`.
    private var chromeIsActive = true
    /// The Mac shows a page's title and actions in the window toolbar; the
    /// in-content bar exists only for windows without a titlebar.
    private var presentsChromeInToolbar = false
    /// Whether the in-content bar's views have been built and attached.
    private var inContentBarInstalled = false
  #endif

  convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
    let ffiNav: CWaterUI.WuiNavigationView = waterui_force_as_navigation_view(anyview)
    self.init(ffiNav: ffiNav, env: env)
  }

  convenience init(ffiNav: CWaterUI.WuiNavigationView, env: WuiEnvironment) {
    let contentView = WuiAnyView(anyview: ffiNav.content, env: env)
    let barState = makeNavigationBarState(from: ffiNav.bar, env: env)
    let destinationState = WuiNavigationDestinationState(ffiNav.state, env: env)
    self.init(
      content: contentView,
      barState: barState,
      destinationState: destinationState,
      env: env,
      hasNavigationController: waterui_env_has_navigation_controller(env.inner),
      backAction: nil
    )
  }

  init(
    content: WuiAnyView,
    barState: WuiNavigationBarState,
    destinationState: WuiNavigationDestinationState,
    env: WuiEnvironment,
    hasNavigationController: Bool,
    backAction: Action?
  ) {
    self.barState = barState
    self.env = env
    self.contentView = content
    self.hasNavigationController = hasNavigationController
    self.destinationState = destinationState
    self.titleView = barState.title.view
    self.backAction = backAction

    super.init(frame: .zero)

    configureNavBar()
    configureContent()
    installOverlayBackButton()
    setupColorWatcher(barState.color)
    setupHiddenWatcher(barState.hidden)
    updateBackButtonVisibility()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func setBackAction(_ action: Action?) {
    backAction = action
    updateBackButtonVisibility()
    #if canImport(UIKit)
      setNeedsLayout()
    #elseif canImport(AppKit)
      publishChrome()
      needsLayout = true
    #endif
  }

  func setDestinationActive(_ active: Bool) {
    guard active != destinationIsActive else { return }
    destinationIsActive = active
    if active {
      destinationState.appeared()
    } else {
      destinationState.disappeared()
    }
  }

  private func configureNavBar() {
    if hasNavigationController {
      barIsInstalled = false
      return
    }
    barIsInstalled = true

    #if canImport(UIKit)
      navigationBar.translatesAutoresizingMaskIntoConstraints = true
      navigationBar.items = [barItem]
      addSubview(navigationBar)

      titleView.translatesAutoresizingMaskIntoConstraints = true
      barItem.titleView = titleView

      if let trailingView = barState.trailing {
        trailingView.translatesAutoresizingMaskIntoConstraints = true
        barItem.rightBarButtonItem = UIBarButtonItem(customView: trailingView)
      }
      rebuildLeadingItems()

      if let search = barState.search {
        let (searchView, coordinator) = makeInlineNavigationSearchView(search)
        searchView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(searchView)
        self.searchView = searchView
        searchCoordinator = coordinator
      }
    #endif
    // On AppKit the bar's home depends on the window — the toolbar when it has
    // a titlebar, an in-content bar otherwise — so installation waits for
    // `viewDidMoveToWindow`.
  }

  #if canImport(AppKit)
    /// Builds the in-content bar, for a window without a titlebar.
    private func installInContentBar() {
      guard !inContentBarInstalled else {
        // Coming back from a titled window: the toolbar reparented the bar's
        // views into its items, so they return home with the bar.
        addSubview(navBarView)
        navBarView.addSubview(titleView)
        if let leadingView = barState.leading { navBarView.addSubview(leadingView) }
        if let trailingView = barState.trailing { navBarView.addSubview(trailingView) }
        if let searchView { navBarView.addSubview(searchView) }
        return
      }
      inContentBarInstalled = true

      navBarView.translatesAutoresizingMaskIntoConstraints = true
      // The header material is the platform's own bar background: a
      // translucent in-window blur that adapts to the appearance.
      navBarView.material = .headerView
      navBarView.blendingMode = .withinWindow
      addSubview(navBarView)

      borderView.wantsLayer = true
      borderObservation = WuiComputedObservation(
        themeColor: WuiColorSlot_Border,
        env: env
      ) { [weak self] color, _ in
        self?.borderView.layer?.backgroundColor = color.toNSColor().cgColor
      }
      if let border = borderObservation?.value {
        borderView.layer?.backgroundColor = border.toNSColor().cgColor
      }

      titleView.translatesAutoresizingMaskIntoConstraints = true
      navBarView.addSubview(titleView)

      if let leadingView = barState.leading {
        leadingView.translatesAutoresizingMaskIntoConstraints = true
        navBarView.addSubview(leadingView)
      }

      if let trailingView = barState.trailing {
        trailingView.translatesAutoresizingMaskIntoConstraints = true
        navBarView.addSubview(trailingView)
      }

      borderView.translatesAutoresizingMaskIntoConstraints = true
      navBarView.addSubview(borderView)

      installInlineBackButton()

      if let search = barState.search {
        let (searchView, coordinator) = makeInlineNavigationSearchView(search)
        searchView.translatesAutoresizingMaskIntoConstraints = true
        navBarView.addSubview(searchView)
        self.searchView = searchView
        searchCoordinator = coordinator
      }
    }
  #endif

  /// Whether this view renders its own bar (no native controller hosts it).
  private var barIsInstalled = false

  #if canImport(UIKit)
    /// The back chevron plus the semantic leading item. SwiftUI's back
    /// button is an accent-tinted chevron; the previous-title text is not
    /// available at this level and is deliberately omitted rather than
    /// hardcoding a non-localized literal.
    private func rebuildLeadingItems() {
      var items: [UIBarButtonItem] = []
      if backAction != nil {
        let back = UIBarButtonItem(
          image: UIImage(systemName: "chevron.backward"),
          style: .plain,
          target: self,
          action: #selector(backButtonTapped)
        )
        backItem = back
        items.append(back)
      } else {
        backItem = nil
      }
      if let leadingView = barState.leading {
        leadingView.translatesAutoresizingMaskIntoConstraints = true
        items.append(UIBarButtonItem(customView: leadingView))
      }
      barItem.leftBarButtonItems = items
      barItem.leftItemsSupplementBackButton = false
    }
  #endif

  private func configureContent() {
    contentView.translatesAutoresizingMaskIntoConstraints = true
    addSubview(contentView)
  }

  private func setupColorWatcher(_ color: WuiComputed<WuiResolvedColor>?) {
    guard let color else { return }
    colorWatcher = color.watch { [weak self] value, metadata in
      guard let self else { return }
      withPlatformAnimation(metadata) {
        self.applyBarColor(value)
      }
    }
    applyBarColor(color.value)
  }

  private func setupHiddenWatcher(_ hidden: WuiComputed<Bool>?) {
    guard let hidden else { return }
    hiddenWatcher = hidden.watch { [weak self] value, _ in
      self?.applyBarHidden(value)
    }
    applyBarHidden(hidden.value)
  }

  /// Applied only for an app-provided explicit bar color; the default bar
  /// keeps the platform chrome (system appearance on iOS, header material
  /// on macOS).
  private func applyBarColor(_ color: WuiResolvedColor) {
    #if canImport(UIKit)
      let appearance = UINavigationBarAppearance()
      appearance.configureWithOpaqueBackground()
      appearance.backgroundColor = color.toUIColor()
      navigationBar.standardAppearance = appearance
      navigationBar.scrollEdgeAppearance = appearance
      navigationBar.compactAppearance = appearance
    #elseif canImport(AppKit)
      navBarView.wantsLayer = true
      navBarView.material = .windowBackground
      navBarView.layer?.backgroundColor = color.toNSColor().cgColor
    #endif
  }

  private var barIsHidden = false

  private func applyBarHidden(_ hidden: Bool) {
    barIsHidden = hidden
    #if canImport(UIKit)
      navigationBar.isHidden = hidden
      searchView?.isHidden = hidden
      setNeedsLayout()
      layoutIfNeeded()
    #elseif canImport(AppKit)
      navBarView.isHidden = hidden
      publishChrome()
      needsLayout = true
    #endif
    updateBackButtonVisibility()
  }

  #if canImport(AppKit)
    private func installInlineBackButton() {
      guard
        let chevron = NSImage(
          systemSymbolName: "chevron.backward",
          accessibilityDescription: "Back"
        )
      else {
        fatalError("SF Symbol chevron.backward is unavailable")
      }
      let button = NSButton(image: chevron, target: self, action: #selector(backButtonTapped))
      button.bezelStyle = .accessoryBarAction
      button.isBordered = false
      button.translatesAutoresizingMaskIntoConstraints = true
      navBarView.addSubview(button)
      inlineBackButton = button
    }
  #endif

  private func installOverlayBackButton() {
    #if canImport(UIKit)
      let button = UIButton(type: .system)
      button.setImage(UIImage(systemName: "chevron.backward"), for: .normal)
      button.addTarget(self, action: #selector(backButtonTapped), for: .touchUpInside)
      button.translatesAutoresizingMaskIntoConstraints = true
      addSubview(button)
      overlayBackButton = button
    #elseif canImport(AppKit)
      guard
        let chevron = NSImage(
          systemSymbolName: "chevron.backward",
          accessibilityDescription: "Back"
        )
      else {
        fatalError("SF Symbol chevron.backward is unavailable")
      }
      let button = NSButton(image: chevron, target: self, action: #selector(backButtonTapped))
      button.bezelStyle = .accessoryBarAction
      button.isBordered = false
      button.translatesAutoresizingMaskIntoConstraints = true
      addSubview(button)
      overlayBackButton = button
    #endif
  }

  @objc private func backButtonTapped() {
    if let backAction {
      backAction.call()
      return
    }
    waterui_navigation_pop(env.inner)
  }

  private func updateBackButtonVisibility() {
    let barVisible = barIsInstalled && !barIsHidden
    let showsOverlayBack = backAction != nil && !barVisible
    overlayBackButton?.isHidden = !showsOverlayBack
    #if canImport(UIKit)
      if barIsInstalled {
        rebuildLeadingItems()
      }
    #elseif canImport(AppKit)
      // In toolbar mode the back control is a toolbar item, not this button.
      inlineBackButton?.isHidden = !(backAction != nil && barVisible && !presentsChromeInToolbar)
    #endif
  }

  func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
    let width = proposal.width.map(CGFloat.init) ?? 320
    let height = proposal.height.map(CGFloat.init) ?? 480
    return CGSize(width: width, height: height)
  }

  #if canImport(UIKit)
    override func didMoveToWindow() {
      super.didMoveToWindow()
      setDestinationActive(window != nil)
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      performLayout()
    }
  #elseif canImport(AppKit)
    nonisolated override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      setDestinationActive(window != nil)
      updateChromePresentation()
    }

    /// Chooses where the bar lives: the window toolbar when the window has a
    /// titlebar — where the Mac shows a page's title and actions — or an
    /// in-content bar when it has none.
    private func updateChromePresentation() {
      guard barIsInstalled else { return }
      guard let window else {
        // Leaving a window; a hidden tab's page must not keep the toolbar.
        windowToolbar?.clearContent(owner: self)
        windowToolbar = nil
        presentsChromeInToolbar = false
        return
      }
      if window.hasTitlebar {
        presentsChromeInToolbar = true
        navBarView.removeFromSuperview()
        windowToolbar = WuiWindowToolbar.attached(to: window)
        publishChrome()
      } else {
        windowToolbar?.clearContent(owner: self)
        windowToolbar = nil
        presentsChromeInToolbar = false
        installInContentBar()
      }
      needsLayout = true
    }

    /// Whether this container lets the view claim the window toolbar; see
    /// `NSView.setNavigationChromeActive(_:)`.
    func setChromeActive(_ active: Bool) {
      guard chromeIsActive != active else { return }
      chromeIsActive = active
      if active {
        publishChrome()
      } else {
        windowToolbar?.clearContent(owner: self)
      }
    }

    /// Whether the bar has anything to show. A page with no title, items,
    /// search, or back action claims nothing, so a deeper page's chrome — a
    /// split detail's title, say — is not clobbered by an empty ancestor.
    private var barHasContent: Bool {
      let titleIsEmpty = barState.title.isPlainText && (barState.title.text ?? "").isEmpty
      return !titleIsEmpty || barState.leadingItem != nil || barState.trailingItem != nil
        || barState.search != nil || backAction != nil
    }

    /// Publishes the bar to the window toolbar, claiming it for this view.
    private func publishChrome() {
      guard presentsChromeInToolbar, let windowToolbar else { return }
      guard chromeIsActive, barState.hidden?.value != true, barHasContent else {
        windowToolbar.clearContent(owner: self)
        return
      }
      var content = WuiWindowToolbar.Content()
      content.showsBack = backAction != nil
      content.onBack = { [weak self] in self?.backButtonTapped() }
      if barState.title.isPlainText {
        content.title = barState.title.text ?? ""
      } else {
        content.titleView = barState.title.view
      }
      content.leading = barState.leadingItem
      content.trailing = barState.trailingItem
      content.search = barState.search
      windowToolbar.setContent(content, owner: self)
    }

    override func layout() {
      super.layout()
      performLayout()
    }
  #endif

  private let itemSpacing: CGFloat = 8
  private let horizontalInset: CGFloat = 16

  private func performLayout() {
    #if canImport(AppKit)
      if presentsChromeInToolbar || !barIsInstalled || barIsHidden {
        overlayBackButton?.frame = CGRect(x: 8, y: 8, width: 30, height: 30)
        layoutContentBelowWindowChrome()
      } else {
        layoutAppKitBar()
      }
    #elseif canImport(UIKit)
      guard barIsInstalled, !barIsHidden else {
        overlayBackButton?.frame = CGRect(x: 8, y: 8, width: 30, height: 30)
        contentView.frame = bounds
        return
      }
      sizeBarItemViews()
      let barHeight = navigationBar.sizeThatFits(
        CGSize(width: bounds.width, height: UIView.layoutFittingCompressedSize.height)
      ).height
      navigationBar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: barHeight)

      var contentTop = barHeight
      if let searchView {
        let searchHeight = max(
          searchView.sizeThatFits(
            CGSize(
              width: max(bounds.width - horizontalInset * 2, 1),
              height: UIView.layoutFittingCompressedSize.height
            )
          ).height,
          44
        )
        searchView.frame = CGRect(
          x: horizontalInset,
          y: barHeight,
          width: max(bounds.width - horizontalInset * 2, 1),
          height: searchHeight
        )
        contentTop = barHeight + searchHeight + itemSpacing
      }

      contentView.frame = CGRect(
        x: 0,
        y: contentTop,
        width: bounds.width,
        height: bounds.height - contentTop
      )
    #endif
  }

  #if canImport(UIKit)
    /// UIBarButtonItem custom views and the title view size themselves; a
    /// WaterUI view has no intrinsic size, so measure and stamp the frames
    /// before the bar lays out.
    private func sizeBarItemViews() {
      let barProposal = WuiProposalSize(
        width: Float(max(bounds.width * 0.4, 1)),
        height: nil
      )
      let titleSize = titleView.sizeThatFits(barProposal)
      titleView.frame.size = titleSize
      if let leadingView = barState.leading {
        leadingView.frame.size = leadingView.sizeThatFits(barProposal)
      }
      if let trailingView = barState.trailing {
        trailingView.frame.size = trailingView.sizeThatFits(barProposal)
      }
    }
  #elseif canImport(AppKit)
    /// Places the content below the window's own chrome.
    ///
    /// With the bar in the window toolbar there is nothing to draw here; the
    /// toolbar's height reaches this view as its top safe-area inset when the
    /// window supplies full-size content, and is zero when the view already
    /// sits below the titlebar.
    private func layoutContentBelowWindowChrome() {
      let topInset = directlyHostsSplitView ? 0 : safeAreaInsets.top
      contentView.frame = CGRect(
        x: 0,
        y: topInset,
        width: bounds.width,
        height: bounds.height - topInset
      )
    }

    /// Whether the content is the split view itself, reached through
    /// `WuiAnyView` wrappers only.
    ///
    /// The split hands the window's top inset to its own columns — that is what
    /// lets the sidebar run the window's full height — so this view must not
    /// consume the inset first. Content that wraps the split in anything else
    /// (padding, say) has asked for a laid-out box and keeps the inset.
    private var directlyHostsSplitView: Bool {
      var node: NSView? = contentView
      while let current = node {
        if current is WuiNavigationSplitView { return true }
        guard current is WuiAnyView else { return false }
        node = current.subviews.first
      }
      return false
    }

    private func layoutAppKitBar() {
      let headerHeight = measuredHeaderHeight()
      let searchHeight = measuredSearchHeight()
      let barHeight =
        searchHeight > 0
        ? headerHeight + itemSpacing + searchHeight + itemSpacing
        : headerHeight

      navBarView.frame = CGRect(x: 0, y: 0, width: bounds.width, height: barHeight)

      var leadingCursor = horizontalInset
      if let inlineBackButton, !inlineBackButton.isHidden {
        let size = inlineBackButton.fittingSize
        inlineBackButton.frame = CGRect(
          x: leadingCursor,
          y: (headerHeight - size.height) / 2,
          width: size.width,
          height: size.height
        )
        leadingCursor = inlineBackButton.frame.maxX + itemSpacing
      }

      if let leadingView = barState.leading {
        let leadingSize = leadingView.sizeThatFits(
          WuiProposalSize(width: Float(max(bounds.width * 0.3, 1)), height: Float(headerHeight))
        )
        leadingView.frame = CGRect(
          x: leadingCursor,
          y: (headerHeight - leadingSize.height) / 2,
          width: leadingSize.width,
          height: leadingSize.height
        )
        leadingCursor = leadingView.frame.maxX + itemSpacing
      }

      var trailingBoundary = bounds.width - horizontalInset
      if let trailingView = barState.trailing {
        let trailingSize = trailingView.sizeThatFits(
          WuiProposalSize(width: Float(max(bounds.width * 0.3, 1)), height: Float(headerHeight))
        )
        trailingView.frame = CGRect(
          x: trailingBoundary - trailingSize.width,
          y: (headerHeight - trailingSize.height) / 2,
          width: trailingSize.width,
          height: trailingSize.height
        )
        trailingBoundary = trailingView.frame.minX - itemSpacing
      }

      let titleProposalWidth = max(trailingBoundary - leadingCursor, 1)
      let titleSize = titleView.sizeThatFits(
        WuiProposalSize(width: Float(titleProposalWidth), height: Float(headerHeight))
      )
      let minTitleX = leadingCursor
      let maxTitleX = max(minTitleX, trailingBoundary - titleSize.width)
      let centeredTitleX = (bounds.width - titleSize.width) / 2
      let titleX = min(max(centeredTitleX, minTitleX), maxTitleX)
      titleView.frame = CGRect(
        x: titleX,
        y: (headerHeight - titleSize.height) / 2,
        width: titleSize.width,
        height: titleSize.height
      )

      if let searchView {
        searchView.frame = CGRect(
          x: horizontalInset,
          y: headerHeight + itemSpacing,
          width: max(bounds.width - horizontalInset * 2, 1),
          height: searchHeight
        )
      }

      let hairline = 1 / (window?.backingScaleFactor ?? 1)
      borderView.frame = CGRect(
        x: 0, y: barHeight - hairline, width: bounds.width, height: hairline)

      contentView.frame = CGRect(
        x: 0,
        y: barHeight,
        width: bounds.width,
        height: bounds.height - barHeight
      )
    }

    private func measuredHeaderHeight() -> CGFloat {
      let baseline = max(NSButton().fittingSize.height, titleView.fittingSize.height)
      let titleSize = titleView.sizeThatFits(
        WuiProposalSize(width: Float(max(bounds.width, 1)), height: nil)
      )
      let leadingHeight =
        barState.leading?.sizeThatFits(
          WuiProposalSize(width: Float(max(bounds.width * 0.3, 1)), height: nil)
        ).height ?? 0
      let trailingHeight =
        barState.trailing?.sizeThatFits(
          WuiProposalSize(width: Float(max(bounds.width * 0.3, 1)), height: nil)
        ).height ?? 0
      let backHeight = inlineBackButton.map { $0.isHidden ? 0 : $0.fittingSize.height } ?? 0
      return max(
        baseline,
        titleSize.height + itemSpacing * 2,
        leadingHeight + itemSpacing * 2,
        trailingHeight + itemSpacing * 2,
        backHeight + itemSpacing * 2
      )
    }

    private func measuredSearchHeight() -> CGFloat {
      guard let searchView else { return 0 }
      return max(searchView.fittingSize.height, 28)
    }
  #endif
}

/// While its own bar is not on screen — it delegates to an enclosing stack, or
/// the bar is hidden — a navigation view is a wrapper around its content. With
/// a visible in-content bar it answers for itself: the bar is laid out from
/// this view's own top edge, which is not safe-area aware.
extension WuiNavigationView: WuiPrimaryContentProviding {
  var wuiPrimaryContent: PlatformView? {
    barIsInstalled && !barIsHidden ? nil : contentView
  }
}
