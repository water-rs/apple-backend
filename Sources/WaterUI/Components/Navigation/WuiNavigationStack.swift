// WuiNavigationStack.swift
// Navigation stack container component with full push/pop support
//
// # Layout Behavior
// NavigationStack stretches to fill available space (greedy).
// Manages a stack of navigation views with native platform navigation.
//
// # Architecture
// Creates a NavigationController (via FFI) that receives push/pop calls from Rust.
// On iOS, uses UINavigationController for native gestures (swipe-back).
// On macOS, uses a custom view stack with titlebar accessories.

import CWaterUI
import OSLog

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

@MainActor
final class WuiNavigationDestinationState {
  private let popEnabled: WuiComputed<Bool>?
  private let popAttempted: Action?
  private let appear: Action?
  private let disappear: Action?
  private let pop: Action?

  init(_ state: CWaterUI.WuiNavigationDestinationState, env: WuiEnvironment) {
    guard let popEnabled = state.pop_enabled else {
      fatalError("Navigation destination pop-enabled signal is null")
    }
    self.popEnabled = WuiComputed<Bool>(popEnabled)
    self.popAttempted = state.pop_attempted.map { Action(inner: $0, env: env) }
    self.appear = state.appear.map { Action(inner: $0, env: env) }
    self.disappear = state.disappear.map { Action(inner: $0, env: env) }
    self.pop = state.pop.map { Action(inner: $0, env: env) }
  }

  init() {
    self.popEnabled = nil
    self.popAttempted = nil
    self.appear = nil
    self.disappear = nil
    self.pop = nil
  }

  func attemptPop() -> Bool {
    popAttempted?.call()
    return popEnabled?.value ?? true
  }

  func appeared() {
    appear?.call()
  }

  func disappeared() {
    disappear?.call()
  }

  func popped() {
    pop?.call()
  }
}

#if canImport(UIKit)
  @MainActor
  final class WuiContentViewController: UIViewController {
    private let contentView: UIView
    private let barState: WuiNavigationBarState?
    private let env: WuiEnvironment
    let destinationState: WuiNavigationDestinationState
    private var colorWatcher: WatcherGuard?
    private var hiddenWatcher: WatcherGuard?
    private var backgroundObservation: WuiComputedObservation<WuiResolvedColor>?
    private var foregroundObservation: WuiComputedObservation<WuiResolvedColor>?
    private var accentObservation: WuiComputedObservation<WuiResolvedColor>?
    private var borderObservation: WuiComputedObservation<WuiResolvedColor>?
    private var searchCoordinator: WuiNavigationSearchCoordinator?
    private let usesThemeBarColor: Bool

    init(
      contentView: UIView,
      barState: WuiNavigationBarState?,
      destinationState: WuiNavigationDestinationState,
      env: WuiEnvironment
    ) {
      self.contentView = contentView
      self.barState = barState
      self.env = env
      self.destinationState = destinationState
      self.usesThemeBarColor = barState?.color == nil
      super.init(nibName: nil, bundle: nil)

      edgesForExtendedLayout = .all
      extendedLayoutIncludesOpaqueBars = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
      super.viewDidLoad()
      // Theme-driven page and navigation backgrounds keep native chrome in
      // sync with WaterUI style overrides and platform color-scheme changes.
      applyThemedBackground()
      contentView.translatesAutoresizingMaskIntoConstraints = true
      view.addSubview(contentView)
      applyNavigationChrome()
      startWatching()
    }

    private func applyThemedBackground() {
      backgroundObservation = WuiComputedObservation(
        themeColor: WuiColorSlot_Background,
        env: env
      ) { [weak self] color, _ in
        guard let self else { return }
        self.view.backgroundColor = color.toUIColor()
      }
      if let color = backgroundObservation?.value {
        view.backgroundColor = color.toUIColor()
      }
      foregroundObservation = WuiComputedObservation(
        themeColor: WuiColorSlot_Foreground,
        env: env
      ) { [weak self] _, _ in
        self?.refreshNavigationAppearance()
      }
      accentObservation = WuiComputedObservation(
        themeColor: WuiColorSlot_Accent,
        env: env
      ) { [weak self] color, _ in
        self?.applyNavigationAccent(color)
      }
      borderObservation = WuiComputedObservation(
        themeColor: WuiColorSlot_Border,
        env: env
      ) { [weak self] _, _ in
        self?.refreshNavigationAppearance()
      }
      if let accent = accentObservation?.value {
        applyNavigationAccent(accent)
      }
    }

    override func viewWillAppear(_ animated: Bool) {
      super.viewWillAppear(animated)
      navigationController?.navigationBar.sizeToFit()
      applyBarState(animated: animated)
    }

    override func viewDidAppear(_ animated: Bool) {
      super.viewDidAppear(animated)
      destinationState.appeared()
    }

    override func viewDidDisappear(_ animated: Bool) {
      super.viewDidDisappear(animated)
      destinationState.disappeared()
    }

    override func viewDidLayoutSubviews() {
      super.viewDidLayoutSubviews()
      contentView.frame = view.bounds
    }

    private func applyNavigationChrome() {
      navigationItem.backAction = UIAction { [weak self] _ in
        guard let self, self.destinationState.attemptPop() else { return }
        waterui_navigation_pop(self.env.inner)
      }

      if let title = barState?.title {
        if title.isPlainText {
          navigationItem.title = title.text ?? ""
          navigationItem.titleView = nil
        } else {
          navigationItem.title = title.text
          navigationItem.titleView = title.view
        }
      } else {
        navigationItem.title = nil
        navigationItem.titleView = nil
      }

      navigationItem.subtitle = barState?.subtitle.text

      let semanticItems = barState?.toolbar ?? []
      let leadingViews = semanticItems.filter {
        $0.placement == WuiNavigationToolbarPlacement_Cancellation
          || $0.placement == WuiNavigationToolbarPlacement_TopBarLeading
      }.map(\.view)
      let trailingViews = semanticItems.filter {
        $0.placement == WuiNavigationToolbarPlacement_PrimaryAction
          || $0.placement == WuiNavigationToolbarPlacement_SecondaryAction
          || $0.placement == WuiNavigationToolbarPlacement_Confirmation
          || $0.placement == WuiNavigationToolbarPlacement_TopBarTrailing
      }.map(\.view)
      let principal = semanticItems.first {
        $0.placement == WuiNavigationToolbarPlacement_Principal
      }?.view
      let bottomViews = semanticItems.filter {
        $0.placement == WuiNavigationToolbarPlacement_BottomBar
          || $0.placement == WuiNavigationToolbarPlacement_Status
      }.map(\.view)

      if let principal {
        principal.removeFromSuperview()
        principal.frame = CGRect(origin: .zero, size: principal.sizeThatFits(WuiProposalSize()))
        navigationItem.titleView = principal
      }

      if !leadingViews.isEmpty {
        for view in leadingViews {
          view.removeFromSuperview()
          view.frame = CGRect(origin: .zero, size: view.sizeThatFits(WuiProposalSize()))
        }
        navigationItem.leftItemsSupplementBackButton = true
        navigationItem.leftBarButtonItems = leadingViews.map(UIBarButtonItem.init(customView:))
      } else {
        navigationItem.leftBarButtonItems = nil
      }

      if !trailingViews.isEmpty {
        for view in trailingViews {
          view.removeFromSuperview()
          view.frame = CGRect(origin: .zero, size: view.sizeThatFits(WuiProposalSize()))
        }
        navigationItem.rightBarButtonItems = trailingViews.map(UIBarButtonItem.init(customView:))
      } else {
        navigationItem.rightBarButtonItems = nil
      }

      if !bottomViews.isEmpty {
        for view in bottomViews {
          view.removeFromSuperview()
          view.frame = CGRect(origin: .zero, size: view.sizeThatFits(WuiProposalSize()))
        }
        toolbarItems = bottomViews.map(UIBarButtonItem.init(customView:))
        navigationController?.setToolbarHidden(false, animated: false)
      } else {
        toolbarItems = nil
        navigationController?.setToolbarHidden(true, animated: false)
      }

      if let search = barState?.search {
        let (controller, coordinator) = makeNavigationSearchController(search)
        navigationItem.searchController = controller
        navigationItem.hidesSearchBarWhenScrolling = false
        searchCoordinator = coordinator
        definesPresentationContext = true
      } else {
        navigationItem.searchController = nil
        searchCoordinator = nil
      }
    }

    private func startWatching() {
      if let barColor = barState?.color {
        colorWatcher = barColor.watch { [weak self] value, metadata in
          guard let self else { return }
          withPlatformAnimation(metadata) {
            self.applyBarColor(value)
          }
        }
        applyBarColor(barColor.value)
      } else {
        applyDefaultBarAppearance()
      }

      if let barHidden = barState?.hidden {
        hiddenWatcher = barHidden.watch { [weak self] value, metadata in
          guard let self else { return }
          self.applyBarHidden(value, animated: shouldAnimate(metadata.animation ?? .none))
        }
        applyBarHidden(barHidden.value, animated: false)
      }
    }

    private func applyBarState(animated: Bool) {
      if let barColor = barState?.color {
        applyBarColor(barColor.value)
      }
      if let barHidden = barState?.hidden {
        applyBarHidden(barHidden.value, animated: animated)
      }
      if let accent = accentObservation?.value {
        applyNavigationAccent(accent)
      }
    }

    private func applyBarColor(_ color: WuiResolvedColor) {
      applyResolvedBarColor(color)
    }

    private func refreshNavigationAppearance() {
      if usesThemeBarColor {
        applyDefaultBarAppearance()
      } else if let color = barState?.color?.value {
        applyResolvedBarColor(color)
      }
    }

    /// SwiftUI's default navigation bar is the system one: a translucent blur
    /// while scrolled under, fully transparent at the scroll edge. Clearing
    /// the item-level appearances restores exactly that; painting the theme
    /// Surface here made every bar an always-opaque gray band.
    private func applyDefaultBarAppearance() {
      navigationItem.standardAppearance = nil
      navigationItem.scrollEdgeAppearance = nil
      navigationItem.compactAppearance = nil
    }

    private func applyResolvedBarColor(_ color: WuiResolvedColor) {
      let appearance = UINavigationBarAppearance()
      appearance.configureWithOpaqueBackground()
      appearance.backgroundColor = color.toUIColor()
      if let foreground = foregroundObservation?.value.toUIColor() {
        appearance.titleTextAttributes = [.foregroundColor: foreground]
        appearance.largeTitleTextAttributes = [.foregroundColor: foreground]
      }
      appearance.shadowColor = borderObservation?.value.toUIColor()
      navigationItem.standardAppearance = appearance
      navigationItem.scrollEdgeAppearance = appearance
      navigationItem.compactAppearance = appearance
    }

    private func applyNavigationAccent(_ color: WuiResolvedColor) {
      let accent = color.toUIColor()
      view.tintColor = accent
      navigationController?.navigationBar.tintColor = accent
    }

    private func applyBarHidden(_ hidden: Bool, animated: Bool) {
      navigationController?.setNavigationBarHidden(hidden, animated: animated)
    }
  }
#endif

@MainActor
final class NavigationControllerWrapper {
  private weak var delegate: WuiNavigationStack?
  private var pendingTransactions: [CWaterUI.WuiNavigationTransaction] = []

  var hasPendingTransactions: Bool {
    !pendingTransactions.isEmpty
  }

  func install(delegate: WuiNavigationStack) {
    precondition(self.delegate == nil, "Navigation controller delegate was installed twice")
    self.delegate = delegate
    let pending = pendingTransactions
    pendingTransactions.removeAll()
    pending.forEach(delegate.handleApply)
  }

  func apply(_ transaction: CWaterUI.WuiNavigationTransaction) {
    if let delegate {
      delegate.handleApply(transaction)
    } else {
      pendingTransactions.append(transaction)
    }
  }
}

@MainActor
final class WuiNavigationStack: PlatformView, WuiComponent {
  static var rawId: CWaterUI.WuiTypeId { waterui_navigation_stack_id() }

  private(set) var stretchAxis: WuiStretchAxis = .both

  private let childEnv: WuiEnvironment
  private let transition: WuiNavigationTransition
  private var wrapper: NavigationControllerWrapper?
  private var pendingTransactionId: UInt64?

  #if canImport(UIKit)
    private var navController: UINavigationController!
    private var viewStack: [UIViewController] = []
    private var expectedNativeStack: [UIViewController]?
    private var pendingRemovedStates: [WuiNavigationDestinationState] = []
  #elseif canImport(AppKit)
    private struct NavigationEntry {
      let view: NSView
      let barState: WuiNavigationBarState?
      let destinationState: WuiNavigationDestinationState
      var isActive: Bool
    }

    private var viewStack: [NavigationEntry] = []
    private var currentIndex = 0
    private weak var windowToolbar: WuiWindowToolbar?
    /// Starts true so a stack with no tab container above it — the common case —
    /// publishes its chrome without being told to.
    private var chromeIsActive = true
    private var hiddenWatcher: WatcherGuard?
    private var pendingRemovedEntries: [NavigationEntry] = []
    private var pendingAppearanceIndex: Int?
  #endif

  convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
    let ffiStack: CWaterUI.WuiNavigationStack = waterui_force_as_navigation_stack(anyview)

    guard let childEnvPtr = waterui_clone_env(env.inner) else {
      fatalError("Failed to clone environment")
    }
    let childEnv = WuiEnvironment(childEnvPtr)

    let wrapper = NavigationControllerWrapper()
    let wrapperPtr = Unmanaged.passRetained(wrapper).toOpaque()

    waterui_env_install_navigation_controller(
      childEnv.inner,
      wrapperPtr,
      { data, transaction in
        let wrapper = Unmanaged<NavigationControllerWrapper>.fromOpaque(data!).takeUnretainedValue()
        wrapper.apply(transaction)
      },
      { data in
        _ = Unmanaged<NavigationControllerWrapper>.fromOpaque(data!).takeRetainedValue()
      }
    )

    guard let unresolvedRoot = ffiStack.root else {
      fatalError("Navigation stack root is null")
    }
    guard let resolvedRoot = waterui_navigation_stack_root(unresolvedRoot, childEnv.inner) else {
      fatalError("Failed to resolve navigation stack root")
    }
    let rootViewId = WuiViewId(waterui_view_id(resolvedRoot))
    let navigationViewId = WuiViewId(waterui_navigation_view_id())

    let rootView: WuiAnyView
    let rootBarState: WuiNavigationBarState?
    let rootDestinationState: WuiNavigationDestinationState
    let rootDisplayMode: WuiNavigationTitleDisplayMode

    if rootViewId == navigationViewId {
      let rootNav = waterui_force_as_navigation_view(resolvedRoot)
      rootView = WuiAnyView(anyview: rootNav.content, env: childEnv)
      rootBarState = makeNavigationBarState(from: rootNav.bar, env: childEnv)
      rootDestinationState = WuiNavigationDestinationState(rootNav.state, env: childEnv)
      rootDisplayMode = rootNav.bar.display_mode
    } else {
      fatalError("Resolved navigation stack root is not a NavigationView")
    }

    self.init(
      rootView: rootView,
      rootBarState: rootBarState,
      rootDestinationState: rootDestinationState,
      rootDisplayMode: rootDisplayMode,
      transition: ffiStack.transition,
      childEnv: childEnv,
      wrapper: wrapper
    )
  }

  init(
    rootView: WuiAnyView,
    rootBarState: WuiNavigationBarState?,
    rootDestinationState: WuiNavigationDestinationState,
    rootDisplayMode: WuiNavigationTitleDisplayMode,
    transition: WuiNavigationTransition,
    childEnv: WuiEnvironment,
    wrapper: NavigationControllerWrapper
  ) {
    self.transition = transition
    self.childEnv = childEnv
    self.wrapper = wrapper
    super.init(frame: .zero)

    configureNavigation(
      with: rootView,
      barState: rootBarState,
      destinationState: rootDestinationState,
      displayMode: rootDisplayMode,
      activateAppKitRoot: !wrapper.hasPendingTransactions
    )
    wrapper.install(delegate: self)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func configureNavigation(
    with rootView: WuiAnyView,
    barState: WuiNavigationBarState?,
    destinationState: WuiNavigationDestinationState,
    displayMode: WuiNavigationTitleDisplayMode,
    activateAppKitRoot: Bool
  ) {
    #if canImport(UIKit)
      let rootVC = makeViewController(
        for: rootView,
        barState: barState,
        destinationState: destinationState,
        displayMode: convertDisplayMode(displayMode),
        restorationDepth: 0
      )
      navController = UINavigationController(rootViewController: rootVC)
      navController.navigationBar.prefersLargeTitles = true
      navController.delegate = self
      navController.interactivePopGestureRecognizer?.delegate = self
      navController.view.translatesAutoresizingMaskIntoConstraints = true
      addSubview(navController.view)
      viewStack.append(rootVC)
    #elseif canImport(AppKit)
      rootView.identifier = NSUserInterfaceItemIdentifier(
        navigationRestorationIdentifier(depth: 0))
      rootView.translatesAutoresizingMaskIntoConstraints = true
      addSubview(rootView)
      viewStack.append(
        NavigationEntry(
          view: rootView,
          barState: barState,
          destinationState: destinationState,
          isActive: activateAppKitRoot
        ))
      if activateAppKitRoot {
        destinationState.appeared()
      }
      currentIndex = 0
    #endif
  }

  func handleApply(_ transaction: CWaterUI.WuiNavigationTransaction) {
    let inserted = WuiArray<CWaterUI.WuiNavigationView>(transaction.inserted).toArray()
    if let pendingTransactionId {
      #if canImport(UIKit)
        settleSupersededUIKitTransaction()
      #elseif canImport(AppKit)
        settleSupersededAppKitTransaction()
      #endif
      _ = waterui_navigation_transition_cancelled(childEnv.inner, pendingTransactionId)
    }
    pendingTransactionId = transaction.id
    #if canImport(UIKit)
      precondition(
        Int(transaction.retained_prefix + transaction.removed) + 1 == viewStack.count,
        "UIKit navigation transaction must replace the current suffix"
      )
      let retained = Array(viewStack.prefix(Int(transaction.retained_prefix) + 1))
      pendingRemovedStates =
        viewStack
        .dropFirst(Int(transaction.retained_prefix) + 1)
        .map { controller in
          guard let controller = controller as? WuiContentViewController else {
            fatalError("UIKit navigation stack contains a non-WaterUI destination")
          }
          return controller.destinationState
        }
      let insertedControllers = inserted.enumerated().map { offset, navView in
        let barState = makeNavigationBarState(from: navView.bar, env: childEnv)
        let destinationState = WuiNavigationDestinationState(navView.state, env: childEnv)
        let contentView = WuiAnyView(anyview: navView.content, env: childEnv)
        return makeViewController(
          for: contentView,
          barState: barState,
          destinationState: destinationState,
          displayMode: convertDisplayMode(navView.bar.display_mode),
          restorationDepth: Int(transaction.retained_prefix) + offset + 1
        )
      }
      let next = retained + insertedControllers
      expectedNativeStack = next
      if transaction.removed == 0 && insertedControllers.count == 1 {
        pushViewController(insertedControllers[0])
      } else if transaction.removed == 1 && insertedControllers.isEmpty {
        popViewController()
      } else {
        setViewControllers(next)
      }
      viewStack = next
    #elseif canImport(AppKit)
      applyAppKitTransaction(transaction, inserted: inserted)
    #endif
  }

  private func completeTransaction(_ id: UInt64) {
    guard pendingTransactionId == id else { return }
    _ = waterui_navigation_transition_completed(childEnv.inner, id)
    pendingTransactionId = nil
  }

  #if canImport(UIKit)
    private func pushViewController(_ vc: UIViewController) {
      navController.pushViewController(vc, animated: nativeTransitionIsAnimated())
    }

    private func popViewController() {
      navController.popViewController(animated: nativeTransitionIsAnimated())
    }

    private func setViewControllers(_ viewControllers: [UIViewController]) {
      navController.setViewControllers(viewControllers, animated: nativeTransitionIsAnimated())
    }

    private func nativeTransitionIsAnimated() -> Bool {
      switch transition.kind {
      case WuiNavigationTransitionKind_Automatic,
        WuiNavigationTransitionKind_Fade,
        WuiNavigationTransitionKind_Zoom:
        return true
      case WuiNavigationTransitionKind_None:
        return false
      case WuiNavigationTransitionKind_Custom:
        Logger.waterui.warning(
          "Custom navigation transition is unavailable on UIKit; applying without animation")
        return false
      default:
        fatalError("Unsupported WaterUI navigation transition: \(transition.kind.rawValue)")
      }
    }

    private func makeViewController(
      for view: UIView,
      barState: WuiNavigationBarState?,
      destinationState: WuiNavigationDestinationState,
      displayMode: UINavigationItem.LargeTitleDisplayMode = .automatic,
      restorationDepth: Int
    ) -> UIViewController {
      let vc = WuiContentViewController(
        contentView: view,
        barState: barState,
        destinationState: destinationState,
        env: childEnv
      )
      vc.restorationIdentifier = navigationRestorationIdentifier(depth: restorationDepth)
      switch transition.kind {
      case WuiNavigationTransitionKind_Automatic,
        WuiNavigationTransitionKind_None,
        WuiNavigationTransitionKind_Custom:
        break
      case WuiNavigationTransitionKind_Fade:
        vc.preferredTransition = .crossDissolve
      case WuiNavigationTransitionKind_Zoom:
        let sourceTag = Int(transition.source_id)
        vc.preferredTransition = .zoom { context in
          guard let source = context.sourceViewController.view.viewWithTag(sourceTag) else {
            fatalError("Navigation zoom source \(sourceTag) is not present in the source page")
          }
          return source
        }
      default:
        fatalError("Unsupported WaterUI navigation transition: \(transition.kind.rawValue)")
      }
      vc.navigationItem.largeTitleDisplayMode = displayMode
      return vc
    }

    private func convertDisplayMode(_ mode: WuiNavigationTitleDisplayMode)
      -> UINavigationItem.LargeTitleDisplayMode
    {
      switch mode {
      case WuiNavigationTitleDisplayMode_Automatic:
        return .automatic
      case WuiNavigationTitleDisplayMode_Inline:
        return .never
      // UIKit's navigation bar has two title sizes, not three: there is no
      // counterpart to Material's medium flexible app bar, so a medium title
      // takes the large one. The asymmetry is real and is not papered over
      // with a hand-drawn bar.
      case WuiNavigationTitleDisplayMode_Medium, WuiNavigationTitleDisplayMode_Large:
        return .always
      default:
        fatalError("Unsupported WaterUI navigation title display mode: \(mode.rawValue)")
      }
    }

    func navigationController(
      _ navigationController: UINavigationController,
      didShow viewController: UIViewController,
      animated: Bool
    ) {
      let next = navigationController.viewControllers
      if let expectedNativeStack {
        guard stacksMatch(next, expectedNativeStack) else { return }
        self.expectedNativeStack = nil
        for state in pendingRemovedStates {
          state.popped()
        }
        pendingRemovedStates.removeAll()
        if let pendingTransactionId {
          completeTransaction(pendingTransactionId)
        }
        viewStack = next
        return
      }
      if next.count < viewStack.count {
        precondition(
          stacksMatch(Array(viewStack.prefix(next.count)), next),
          "UIKit native navigation pop must remove a suffix"
        )
        for controller in viewStack.dropFirst(next.count) {
          guard let controller = controller as? WuiContentViewController else {
            fatalError("UIKit navigation stack contains a non-WaterUI destination")
          }
          controller.destinationState.popped()
        }
        waterui_navigation_complete_native_pop(
          childEnv.inner,
          UInt(viewStack.count - next.count)
        )
      }
      viewStack = next
    }

    private func settleSupersededUIKitTransaction() {
      for state in pendingRemovedStates {
        state.popped()
      }
      pendingRemovedStates.removeAll()
      expectedNativeStack = nil
    }

    private func stacksMatch(_ left: [UIViewController], _ right: [UIViewController]) -> Bool {
      left.count == right.count
        && zip(left, right).allSatisfy { pair in
          pair.0 === pair.1
        }
    }
  #elseif canImport(AppKit)
    private func setupTitlebar() {
      guard let window, window.hasTitlebar else { return }
      windowToolbar = WuiWindowToolbar.attached(to: window)
      updateTitlebarState()
    }

    /// Whether this stack is the one the user is looking at.
    ///
    /// A tab container keeps every tab's content in the window and hides all but
    /// one, so being in a window is not the same as being on screen. Only the
    /// stack that is actually visible may publish chrome; see
    /// `NSView.setNavigationChromeActive(_:)`.
    func setChromeActive(_ active: Bool) {
      guard chromeIsActive != active else { return }
      chromeIsActive = active
      if active {
        updateTitlebarState()
      } else {
        windowToolbar?.clearContent(owner: self)
      }
    }

    /// Publishes this stack's chrome to the window toolbar.
    ///
    /// The items go through `NSToolbarItem` rather than titlebar accessory
    /// views, which is what gives them the system's own appearance — the glass
    /// capsule around a toolbar button, the search field's presentation, the
    /// spacing between items. A window has one toolbar, so the stack claims it
    /// while it is on screen and gives it back when it leaves; see
    /// `WuiWindowToolbar`.
    private func updateTitlebarState() {
      guard let windowToolbar, chromeIsActive else { return }

      hiddenWatcher = nil
      let topBarState = viewStack.last?.barState
      if let hidden = topBarState?.hidden {
        hiddenWatcher = hidden.watch { [weak self] _, _ in
          self?.updateTitlebarState()
        }
      }

      guard topBarState?.hidden?.value != true else {
        windowToolbar.clearContent(owner: self)
        return
      }

      var content = WuiWindowToolbar.Content()
      content.showsBack = currentIndex > 0
      content.onBack = { [weak self] in self?.backButtonTapped() }
      if let title = topBarState?.title {
        if title.isPlainText {
          content.title = title.text ?? ""
        } else {
          content.titleView = title.view
        }
      }
      content.leading = topBarState?.leadingItem
      content.trailing = topBarState?.trailingItem
      content.search = topBarState?.search
      windowToolbar.setContent(content, owner: self)
    }

    private func backButtonTapped() {
      guard viewStack.last?.destinationState.attemptPop() != false else { return }
      waterui_navigation_pop(childEnv.inner)
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if window == nil {
        // Several stacks exist at once behind a tab container; one that has been
        // switched away from must not leave its buttons in the toolbar.
        windowToolbar?.clearContent(owner: self)
        windowToolbar = nil
        return
      }
      setupTitlebar()
    }

    private func applyAppKitTransaction(
      _ transaction: CWaterUI.WuiNavigationTransaction,
      inserted: [CWaterUI.WuiNavigationView]
    ) {
      precondition(
        Int(transaction.retained_prefix + transaction.removed) + 1 == viewStack.count,
        "AppKit navigation transaction must replace the current suffix"
      )
      guard let oldTop = viewStack.last else {
        fatalError("AppKit navigation stack is missing its root destination")
      }

      let oldTopIndex = viewStack.count - 1
      if viewStack[oldTopIndex].isActive {
        viewStack[oldTopIndex].destinationState.disappeared()
        viewStack[oldTopIndex].isActive = false
      }

      let retainedCount = Int(transaction.retained_prefix) + 1
      let retained = Array(viewStack.prefix(retainedCount))
      let removed = Array(viewStack.dropFirst(retainedCount))
      let insertedEntries = inserted.enumerated().map { offset, navView in
        let view = WuiAnyView(anyview: navView.content, env: childEnv)
        view.translatesAutoresizingMaskIntoConstraints = true
        view.identifier = NSUserInterfaceItemIdentifier(
          navigationRestorationIdentifier(depth: retainedCount + offset))
        view.frame = bounds
        view.isHidden = true
        view.alphaValue = 1
        addSubview(view)
        return NavigationEntry(
          view: view,
          barState: makeNavigationBarState(from: navView.bar, env: childEnv),
          destinationState: WuiNavigationDestinationState(navView.state, env: childEnv),
          isActive: false
        )
      }
      let next = retained + insertedEntries
      guard let newTop = next.last else {
        fatalError("AppKit navigation transaction removed the root destination")
      }

      viewStack = next
      currentIndex = viewStack.count - 1
      pendingRemovedEntries = removed
      pendingAppearanceIndex = currentIndex
      updateTitlebarState()

      newTop.view.isHidden = false
      let fades = appKitTransitionUsesFade()
      if fades {
        let transactionId = transaction.id
        oldTop.view.isHidden = false
        oldTop.view.alphaValue = 1
        newTop.view.alphaValue = 0
        NSAnimationContext.runAnimationGroup { _ in
          oldTop.view.animator().alphaValue = 0
          newTop.view.animator().alphaValue = 1
        } completionHandler: { [weak self] in
          Task { @MainActor in
            self?.finishAppKitTransaction(transactionId)
          }
        }
      } else {
        finishAppKitTransaction(transaction.id)
      }
    }

    private func finishAppKitTransaction(_ id: UInt64) {
      guard pendingTransactionId == id else { return }
      for entry in pendingRemovedEntries {
        entry.view.removeFromSuperview()
        entry.destinationState.popped()
      }
      pendingRemovedEntries.removeAll()
      markAppKitDestinationAppeared(at: pendingAppearanceIndex)
      pendingAppearanceIndex = nil
      normalizeAppKitStackVisibility()
      completeTransaction(id)
    }

    private func settleSupersededAppKitTransaction() {
      for entry in pendingRemovedEntries {
        entry.view.removeFromSuperview()
        entry.destinationState.popped()
      }
      pendingRemovedEntries.removeAll()
      markAppKitDestinationAppeared(at: pendingAppearanceIndex)
      pendingAppearanceIndex = nil
      normalizeAppKitStackVisibility()
    }

    private func markAppKitDestinationAppeared(at index: Int?) {
      guard let index else { return }
      precondition(
        viewStack.indices.contains(index), "AppKit navigation appearance index is invalid")
      guard !viewStack[index].isActive else { return }
      viewStack[index].destinationState.appeared()
      viewStack[index].isActive = true
    }

    private func normalizeAppKitStackVisibility() {
      for (index, entry) in viewStack.enumerated() {
        entry.view.alphaValue = 1
        entry.view.isHidden = index != viewStack.count - 1
      }
    }

    private func appKitTransitionUsesFade() -> Bool {
      switch transition.kind {
      case WuiNavigationTransitionKind_Fade:
        return true
      case WuiNavigationTransitionKind_Automatic,
        WuiNavigationTransitionKind_None:
        return false
      case WuiNavigationTransitionKind_Zoom:
        Logger.waterui.warning(
          "Zoom navigation transition is unavailable on AppKit; applying without animation")
        return false
      case WuiNavigationTransitionKind_Custom:
        Logger.waterui.warning(
          "Custom navigation transition is unavailable on AppKit; applying without animation")
        return false
      default:
        fatalError("Unsupported WaterUI navigation transition: \(transition.kind.rawValue)")
      }
    }

  #endif

  func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
    let width = proposal.width.map(CGFloat.init) ?? 320
    let height = proposal.height.map(CGFloat.init) ?? 480
    return CGSize(width: width, height: height)
  }

  #if canImport(UIKit)
    override func layoutSubviews() {
      super.layoutSubviews()
      navController?.view.frame = bounds
    }
  #elseif canImport(AppKit)
    nonisolated override var isFlipped: Bool { true }

    override func layout() {
      super.layout()
      for entry in viewStack {
        entry.view.frame = bounds
      }
    }
  #endif
}

private func navigationRestorationIdentifier(depth: Int) -> String {
  precondition(depth >= 0, "Navigation restoration depth must be non-negative")
  return "dev.waterui.navigation.destination.\(depth)"
}

#if canImport(UIKit)
  extension WuiNavigationStack: UINavigationControllerDelegate, UIGestureRecognizerDelegate {
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
      guard gestureRecognizer === navController.interactivePopGestureRecognizer else {
        return true
      }
      guard viewStack.count > 1 else { return false }
      guard let destination = viewStack.last as? WuiContentViewController else {
        fatalError("UIKit navigation stack contains a non-WaterUI destination")
      }
      return destination.destinationState.attemptPop()
    }
  }
#endif

#if canImport(AppKit)
  extension NSWindow {
    /// Whether this window has a titlebar to hang accessories off.
    ///
    /// `addTitlebarAccessoryViewController` reaches for `titlebarViewController`,
    /// which raises `NSInternalInconsistencyException` on a window without
    /// `.titled` — the offscreen window preview renders into, among others.
    var hasTitlebar: Bool { styleMask.contains(.titled) }
  }
#endif
