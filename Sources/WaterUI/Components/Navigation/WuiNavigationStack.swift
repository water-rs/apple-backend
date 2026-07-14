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

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

#if canImport(UIKit)
  @MainActor
  final class WuiContentViewController: UIViewController {
    private let contentView: UIView
    private let barState: WuiNavigationBarState?
    private let env: WuiEnvironment
    private var colorWatcher: WatcherGuard?
    private var hiddenWatcher: WatcherGuard?
    private var backgroundObservation: WuiComputedObservation<WuiResolvedColor>?
    private var foregroundObservation: WuiComputedObservation<WuiResolvedColor>?
    private var accentObservation: WuiComputedObservation<WuiResolvedColor>?
    private var borderObservation: WuiComputedObservation<WuiResolvedColor>?
    private var searchCoordinator: WuiNavigationSearchCoordinator?
    private let usesThemeBarColor: Bool

    init(contentView: UIView, barState: WuiNavigationBarState?, env: WuiEnvironment) {
      self.contentView = contentView
      self.barState = barState
      self.env = env
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
        if self.usesThemeBarColor {
          self.applyResolvedBarColor(color)
        }
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

    override func viewDidLayoutSubviews() {
      super.viewDidLayoutSubviews()
      contentView.frame = view.bounds
    }

    private func applyNavigationChrome() {
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

      if let leadingView = barState?.leading {
        leadingView.removeFromSuperview()
        leadingView.frame = CGRect(origin: .zero, size: leadingView.sizeThatFits(WuiProposalSize()))
        navigationItem.leftItemsSupplementBackButton = true
        navigationItem.leftBarButtonItems = [UIBarButtonItem(customView: leadingView)]
      } else {
        navigationItem.leftBarButtonItems = nil
      }

      if let trailingView = barState?.trailing {
        trailingView.removeFromSuperview()
        trailingView.frame = CGRect(
          origin: .zero, size: trailingView.sizeThatFits(WuiProposalSize()))
        navigationItem.rightBarButtonItems = [UIBarButtonItem(customView: trailingView)]
      } else {
        navigationItem.rightBarButtonItems = nil
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
      } else if let background = backgroundObservation?.value {
        applyResolvedBarColor(background)
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
        guard let background = backgroundObservation?.value else { return }
        applyResolvedBarColor(background)
      } else if let color = barState?.color?.value {
        applyResolvedBarColor(color)
      }
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
  weak var delegate: WuiNavigationStack?

  func push(_ navView: CWaterUI.WuiNavigationView) {
    delegate?.handlePush(navView)
  }

  func pop() {
    delegate?.handlePop()
  }
}

@MainActor
final class WuiNavigationStack: PlatformView, WuiComponent {
  static var rawId: CWaterUI.WuiTypeId { waterui_navigation_stack_id() }

  private(set) var stretchAxis: WuiStretchAxis = .both

  private let childEnv: WuiEnvironment
  private let transition: WuiNavigationTransition
  private var wrapper: NavigationControllerWrapper?

  #if canImport(UIKit)
    private var navController: UINavigationController!
    private var viewStack: [UIViewController] = []
  #elseif canImport(AppKit)
    private struct NavigationEntry {
      let view: NSView
      let barState: WuiNavigationBarState?
    }

    private var viewStack: [NavigationEntry] = []
    private var currentIndex = 0
    private var backButton: NSButton?
    private var backAccessory: NSTitlebarAccessoryViewController?
    private var titleAccessory: NSTitlebarAccessoryViewController?
    private var titleContainer: NSView?
    private var leadingAccessory: NSTitlebarAccessoryViewController?
    private var leadingContainer: NSView?
    private var trailingAccessory: NSTitlebarAccessoryViewController?
    private var trailingContainer: NSView?
    private var searchAccessory: NSTitlebarAccessoryViewController?
    private var searchContainer: NSView?
    private var searchCoordinator: WuiNavigationSearchCoordinator?
    private var hiddenWatcher: WatcherGuard?
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
      { data, navView in
        let wrapper = Unmanaged<NavigationControllerWrapper>.fromOpaque(data!).takeUnretainedValue()
        wrapper.push(navView)
      },
      { data in
        let wrapper = Unmanaged<NavigationControllerWrapper>.fromOpaque(data!).takeUnretainedValue()
        wrapper.pop()
      },
      { data in
        _ = Unmanaged<NavigationControllerWrapper>.fromOpaque(data!).takeRetainedValue()
      }
    )

    let rootViewId = WuiViewId(waterui_view_id(ffiStack.root))
    let navigationViewId = WuiViewId(waterui_navigation_view_id())

    let rootView: WuiAnyView
    let rootBarState: WuiNavigationBarState?
    let rootDisplayMode: WuiNavigationTitleDisplayMode

    if rootViewId == navigationViewId {
      let rootNav = waterui_force_as_navigation_view(ffiStack.root)
      rootView = WuiAnyView(anyview: rootNav.content, env: childEnv)
      rootBarState = makeNavigationBarState(from: rootNav.bar, env: childEnv)
      rootDisplayMode = rootNav.bar.display_mode
    } else {
      rootView = WuiAnyView(anyview: ffiStack.root, env: childEnv)
      rootBarState = nil
      rootDisplayMode = WuiNavigationTitleDisplayMode_Automatic
    }

    self.init(
      rootView: rootView,
      rootBarState: rootBarState,
      rootDisplayMode: rootDisplayMode,
      transition: ffiStack.transition,
      childEnv: childEnv,
      wrapper: wrapper
    )
  }

  init(
    rootView: WuiAnyView,
    rootBarState: WuiNavigationBarState?,
    rootDisplayMode: WuiNavigationTitleDisplayMode,
    transition: WuiNavigationTransition,
    childEnv: WuiEnvironment,
    wrapper: NavigationControllerWrapper
  ) {
    self.transition = transition
    self.childEnv = childEnv
    self.wrapper = wrapper
    super.init(frame: .zero)

    wrapper.delegate = self
    configureNavigation(with: rootView, barState: rootBarState, displayMode: rootDisplayMode)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func configureNavigation(
    with rootView: WuiAnyView,
    barState: WuiNavigationBarState?,
    displayMode: WuiNavigationTitleDisplayMode
  ) {
    #if canImport(UIKit)
      let rootVC = makeViewController(
        for: rootView,
        barState: barState,
        displayMode: convertDisplayMode(displayMode)
      )
      navController = UINavigationController(rootViewController: rootVC)
      navController.navigationBar.prefersLargeTitles = true
      navController.delegate = self
      navController.view.translatesAutoresizingMaskIntoConstraints = true
      addSubview(navController.view)
      viewStack.append(rootVC)
    #elseif canImport(AppKit)
      rootView.translatesAutoresizingMaskIntoConstraints = true
      addSubview(rootView)
      viewStack.append(NavigationEntry(view: rootView, barState: barState))
      currentIndex = 0
    #endif
  }

  func handlePush(_ navView: CWaterUI.WuiNavigationView) {
    let barState = makeNavigationBarState(from: navView.bar, env: childEnv)
    let contentView = WuiAnyView(anyview: navView.content, env: childEnv)

    #if canImport(UIKit)
      let displayMode = convertDisplayMode(navView.bar.display_mode)
      let vc = makeViewController(for: contentView, barState: barState, displayMode: displayMode)
      pushViewController(vc)
      viewStack.append(vc)
    #elseif canImport(AppKit)
      pushView(contentView, barState: barState)
    #endif
  }

  func handlePop() {
    #if canImport(UIKit)
      guard viewStack.count > 1 else { return }
      popViewController()
      viewStack.removeLast()
    #elseif canImport(AppKit)
      popView()
    #endif
  }

  #if canImport(UIKit)
    private func pushViewController(_ vc: UIViewController) {
      switch transition {
      case WuiNavigationTransition_PushPop:
        navController.pushViewController(vc, animated: true)
      case WuiNavigationTransition_Fade:
        addFadeTransition(to: navController.view.layer)
        navController.pushViewController(vc, animated: false)
      case WuiNavigationTransition_None:
        navController.pushViewController(vc, animated: false)
      default:
        fatalError("Unsupported WaterUI navigation transition: \(transition.rawValue)")
      }
    }

    private func popViewController() {
      switch transition {
      case WuiNavigationTransition_PushPop:
        navController.popViewController(animated: true)
      case WuiNavigationTransition_Fade:
        addFadeTransition(to: navController.view.layer)
        navController.popViewController(animated: false)
      case WuiNavigationTransition_None:
        navController.popViewController(animated: false)
      default:
        fatalError("Unsupported WaterUI navigation transition: \(transition.rawValue)")
      }
    }

    private func addFadeTransition(to layer: CALayer?) {
      guard let layer else { return }
      let transition = CATransition()
      transition.type = .fade
      transition.duration = 0.25
      transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      layer.add(transition, forKey: "waterui.navigation.fade")
    }

    private func makeViewController(
      for view: UIView,
      barState: WuiNavigationBarState?,
      displayMode: UINavigationItem.LargeTitleDisplayMode = .automatic
    ) -> UIViewController {
      let vc = WuiContentViewController(contentView: view, barState: barState, env: childEnv)
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
      case WuiNavigationTitleDisplayMode_Large:
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
      viewStack = navigationController.viewControllers
    }
  #elseif canImport(AppKit)
    private func setupTitlebar() {
      guard let window else { return }
      guard backAccessory == nil else { return }

      let button = NSButton(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
      button.image = NSImage(systemSymbolName: "chevron.backward", accessibilityDescription: "Back")
      button.bezelStyle = .accessoryBarAction
      button.isBordered = false
      button.imagePosition = .imageOnly
      button.target = self
      button.action = #selector(backButtonTapped)
      button.isHidden = true
      backButton = button

      let accessory = NSTitlebarAccessoryViewController()
      accessory.view = button
      accessory.layoutAttribute = .leading
      window.addTitlebarAccessoryViewController(accessory)
      backAccessory = accessory

      window.titleVisibility = .visible
      updateTitlebarState()
    }

    private func updateTitlebarState() {
      guard let window else { return }

      hiddenWatcher = nil
      let topBarState = viewStack.last?.barState
      if let hidden = topBarState?.hidden {
        hiddenWatcher = hidden.watch { [weak self] _, _ in
          self?.updateTitlebarState()
        }
      }

      let isHidden = topBarState?.hidden?.value ?? false
      backButton?.isHidden = currentIndex <= 0 || isHidden
      applyTitle(isHidden ? nil : topBarState?.title, in: window)
      installLeadingAccessory(isHidden ? nil : topBarState?.leading, in: window)
      installSearchAccessory(isHidden ? nil : topBarState?.search, in: window)
      installTrailingAccessory(isHidden ? nil : topBarState?.trailing, in: window)
    }

    @objc private func backButtonTapped() {
      waterui_navigation_pop(childEnv.inner)
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if window != nil {
        setupTitlebar()
      }
    }

    private func pushView(_ view: NSView, barState: WuiNavigationBarState?) {
      if let currentView = viewStack.last?.view {
        currentView.isHidden = true
      }

      view.translatesAutoresizingMaskIntoConstraints = true
      view.frame = bounds
      view.alphaValue = transition == WuiNavigationTransition_None ? 1 : 0
      addSubview(view)
      viewStack.append(NavigationEntry(view: view, barState: barState))
      currentIndex = max(0, viewStack.count - 1)
      updateTitlebarState()

      if transition == WuiNavigationTransition_None {
        view.alphaValue = 1
      } else {
        NSAnimationContext.runAnimationGroup { context in
          context.duration = 0.25
          view.animator().alphaValue = 1
        }
      }
    }

    private func popView() {
      guard viewStack.count > 1 else { return }

      let currentEntry = viewStack.removeLast()
      let currentView = currentEntry.view
      currentIndex = max(0, viewStack.count - 1)
      updateTitlebarState()

      if transition == WuiNavigationTransition_None {
        currentView.removeFromSuperview()
      } else {
        NSAnimationContext.runAnimationGroup(
          { context in
            context.duration = 0.25
            currentView.animator().alphaValue = 0
          },
          completionHandler: {
            Task { @MainActor in
              currentView.removeFromSuperview()
            }
          })
      }

      viewStack.last?.view.isHidden = false
    }

    private func applyTitle(_ title: WuiNavigationTitle?, in window: NSWindow) {
      guard let title else {
        window.titleVisibility = .visible
        window.title = ""
        removeTitleAccessory()
        return
      }

      if title.isPlainText {
        window.titleVisibility = .visible
        window.title = title.text ?? ""
        removeTitleAccessory()
      } else {
        window.titleVisibility = .hidden
        window.title = ""
        installTitleAccessory(title.view, in: window)
      }
    }

    private func installTitleAccessory(_ titleView: NSView, in window: NSWindow) {
      let accessory = ensureTitleAccessory(in: window)
      titleView.removeFromSuperview()
      titleView.translatesAutoresizingMaskIntoConstraints = true
      titleView.frame = NSRect(origin: .zero, size: titleView.fittingSize)
      accessory.view = titleView
      titleContainer = titleView
    }

    private func ensureTitleAccessory(in window: NSWindow) -> NSTitlebarAccessoryViewController {
      if let titleAccessory {
        return titleAccessory
      }

      let accessory = NSTitlebarAccessoryViewController()
      accessory.layoutAttribute = .centerX
      window.addTitlebarAccessoryViewController(accessory)
      titleAccessory = accessory
      return accessory
    }

    private func removeTitleAccessory() {
      titleContainer?.removeFromSuperview()
      titleContainer = nil
      titleAccessory?.view = NSView(frame: .zero)
    }

    private func installLeadingAccessory(_ leadingView: NSView?, in window: NSWindow) {
      guard let leadingView else {
        leadingContainer?.removeFromSuperview()
        leadingContainer = nil
        leadingAccessory?.view = NSView(frame: .zero)
        return
      }

      let accessory = ensureLeadingAccessory(in: window)
      leadingView.removeFromSuperview()
      leadingView.translatesAutoresizingMaskIntoConstraints = true
      leadingView.frame = NSRect(origin: .zero, size: leadingView.fittingSize)
      accessory.view = leadingView
      leadingContainer = leadingView
    }

    private func installTrailingAccessory(_ trailingView: NSView?, in window: NSWindow) {
      guard let trailingView else {
        trailingContainer?.removeFromSuperview()
        trailingContainer = nil
        trailingAccessory?.view = NSView(frame: .zero)
        return
      }

      let accessory = ensureTrailingAccessory(in: window)
      trailingView.removeFromSuperview()
      trailingView.translatesAutoresizingMaskIntoConstraints = true
      trailingView.frame = NSRect(origin: .zero, size: trailingView.fittingSize)
      accessory.view = trailingView
      trailingContainer = trailingView
    }

    private func installSearchAccessory(_ search: WuiNavigationSearch?, in window: NSWindow) {
      guard let search else {
        searchCoordinator = nil
        searchContainer?.removeFromSuperview()
        searchContainer = nil
        searchAccessory?.view = NSView(frame: .zero)
        return
      }

      let accessory = ensureSearchAccessory(in: window)
      let (searchField, coordinator) = makeInlineNavigationSearchView(search)
      searchField.removeFromSuperview()
      searchField.translatesAutoresizingMaskIntoConstraints = true
      searchField.frame = NSRect(
        origin: .zero,
        size: CGSize(
          width: max(searchField.fittingSize.width, 240), height: searchField.fittingSize.height)
      )
      accessory.view = searchField
      searchContainer = searchField
      searchCoordinator = coordinator
    }

    private func ensureLeadingAccessory(in window: NSWindow) -> NSTitlebarAccessoryViewController {
      if let leadingAccessory {
        return leadingAccessory
      }

      let accessory = NSTitlebarAccessoryViewController()
      accessory.layoutAttribute = .leading
      window.addTitlebarAccessoryViewController(accessory)
      leadingAccessory = accessory
      return accessory
    }

    private func ensureSearchAccessory(in window: NSWindow) -> NSTitlebarAccessoryViewController {
      if let searchAccessory {
        return searchAccessory
      }

      let accessory = NSTitlebarAccessoryViewController()
      accessory.layoutAttribute = .trailing
      window.addTitlebarAccessoryViewController(accessory)
      searchAccessory = accessory
      return accessory
    }

    private func ensureTrailingAccessory(in window: NSWindow) -> NSTitlebarAccessoryViewController {
      if let trailingAccessory {
        return trailingAccessory
      }

      let accessory = NSTitlebarAccessoryViewController()
      accessory.layoutAttribute = .trailing
      window.addTitlebarAccessoryViewController(accessory)
      trailingAccessory = accessory
      return accessory
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
    override var isFlipped: Bool { true }

    override func layout() {
      super.layout()
      for entry in viewStack {
        entry.view.frame = bounds
      }
    }
  #endif
}

#if canImport(UIKit)
  extension WuiNavigationStack: UINavigationControllerDelegate {}
#endif
