// WuiNavigationView.swift
// Navigation view component with navigation bar
//
// # Layout Behavior
// NavigationView stretches to fill available space (greedy).
// Contains a navigation bar and content area.

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
  private let usesThemeBarColor: Bool
  private var barBackgroundObservation: WuiComputedObservation<WuiResolvedColor>?
  private var borderObservation: WuiComputedObservation<WuiResolvedColor>?
  private var overlaySurfaceObservation: WuiComputedObservation<WuiResolvedColor>?

  #if canImport(UIKit)
    private let navBarView = UIView()
    private let borderView = UIView()
    private var inlineBackButton: UIButton?
    private var overlayBackButton: UIButton?
    private var searchView: UIView?
  #elseif canImport(AppKit)
    private let navBarView = NSView()
    private let borderView = NSView()
    private var inlineBackButton: NSButton?
    private var overlayBackButton: NSButton?
    private var searchView: NSView?
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
    self.usesThemeBarColor = barState.color == nil
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

  func notifyDestinationPopped() {
    setDestinationActive(false)
    destinationState.popped()
  }

  private func configureNavBar() {
    if hasNavigationController {
      navBarView.isHidden = true
      return
    }

    navBarView.translatesAutoresizingMaskIntoConstraints = true
    addSubview(navBarView)

    #if canImport(AppKit)
      navBarView.wantsLayer = true
      borderView.wantsLayer = true
    #endif

    barBackgroundObservation = WuiComputedObservation(
      themeColor: WuiColorSlot_Surface,
      env: env
    ) { [weak self] color, _ in
      guard let self, self.usesThemeBarColor else { return }
      self.applyBarColor(color)
    }
    borderObservation = WuiComputedObservation(
      themeColor: WuiColorSlot_Border,
      env: env
    ) { [weak self] color, _ in
      self?.applyBorderColor(color)
    }
    overlaySurfaceObservation = WuiComputedObservation(
      themeColor: WuiColorSlot_Surface,
      env: env
    ) { [weak self] color, _ in
      self?.applyOverlaySurfaceColor(color)
    }
    if let background = barBackgroundObservation?.value {
      applyBarColor(background)
    }
    if let border = borderObservation?.value {
      applyBorderColor(border)
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

  private func applyBarColor(_ color: WuiResolvedColor) {
    #if canImport(UIKit)
      navBarView.backgroundColor = color.toUIColor()
    #elseif canImport(AppKit)
      navBarView.layer?.backgroundColor = color.toNSColor().cgColor
    #endif
  }

  private func applyBorderColor(_ color: WuiResolvedColor) {
    #if canImport(UIKit)
      borderView.backgroundColor = color.toUIColor()
    #elseif canImport(AppKit)
      borderView.layer?.backgroundColor = color.toNSColor().cgColor
    #endif
  }

  private func applyOverlaySurfaceColor(_ color: WuiResolvedColor) {
    #if canImport(UIKit)
      overlayBackButton?.backgroundColor = color.toUIColor().withAlphaComponent(0.92)
    #elseif canImport(AppKit)
      overlayBackButton?.layer?.backgroundColor =
        color.toNSColor()
        .withAlphaComponent(0.92)
        .cgColor
    #endif
  }

  private func applyBarHidden(_ hidden: Bool) {
    navBarView.isHidden = hidden
    updateBackButtonVisibility()
    #if canImport(UIKit)
      setNeedsLayout()
      layoutIfNeeded()
    #elseif canImport(AppKit)
      needsLayout = true
    #endif
  }

  private func installInlineBackButton() {
    #if canImport(UIKit)
      let button = UIButton(type: .system)
      button.setImage(UIImage(systemName: "chevron.backward"), for: .normal)
      button.setTitle("Back", for: .normal)
      button.semanticContentAttribute = .forceLeftToRight
      button.addTarget(self, action: #selector(backButtonTapped), for: .touchUpInside)
      button.translatesAutoresizingMaskIntoConstraints = true
      navBarView.addSubview(button)
      inlineBackButton = button
    #elseif canImport(AppKit)
      let button = NSButton(title: "Back", target: self, action: #selector(backButtonTapped))
      button.image = NSImage(systemSymbolName: "chevron.backward", accessibilityDescription: "Back")
      button.bezelStyle = .inline
      button.isBordered = false
      button.wantsLayer = true
      button.layer?.cornerRadius = 8
      button.translatesAutoresizingMaskIntoConstraints = true
      navBarView.addSubview(button)
      inlineBackButton = button
    #endif
  }

  private func installOverlayBackButton() {
    #if canImport(UIKit)
      let button = UIButton(type: .system)
      button.setImage(UIImage(systemName: "chevron.backward"), for: .normal)
      button.layer.cornerRadius = 8
      button.addTarget(self, action: #selector(backButtonTapped), for: .touchUpInside)
      button.translatesAutoresizingMaskIntoConstraints = true
      addSubview(button)
      overlayBackButton = button
      if let surface = overlaySurfaceObservation?.value {
        applyOverlaySurfaceColor(surface)
      }
    #elseif canImport(AppKit)
      let button = NSButton(frame: .zero)
      button.image = NSImage(systemSymbolName: "chevron.backward", accessibilityDescription: "Back")
      button.bezelStyle = .accessoryBarAction
      button.isBordered = false
      button.target = self
      button.action = #selector(backButtonTapped)
      button.translatesAutoresizingMaskIntoConstraints = true
      addSubview(button)
      overlayBackButton = button
      if let surface = overlaySurfaceObservation?.value {
        applyOverlaySurfaceColor(surface)
      }
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
    let showsInlineBack = backAction != nil && !navBarView.isHidden
    let showsOverlayBack = backAction != nil && navBarView.isHidden
    inlineBackButton?.isHidden = !showsInlineBack
    overlayBackButton?.isHidden = !showsOverlayBack
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
    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      setDestinationActive(window != nil)
    }

    override func layout() {
      super.layout()
      performLayout()
    }
  #endif

  private func performLayout() {
    let barHeight = navBarView.isHidden ? 0 : measuredNavBarHeight()
    let headerHeight = navBarView.isHidden ? 0 : measuredHeaderHeight()
    let searchHeight = navBarView.isHidden ? 0 : measuredSearchHeight()
    let horizontalInset: CGFloat = 16
    let itemSpacing: CGFloat = 8

    navBarView.frame = CGRect(x: 0, y: 0, width: bounds.width, height: barHeight)

    var leadingCursor = horizontalInset
    if let inlineBackButton, !inlineBackButton.isHidden {
      let size = inlineBackButtonSize(headerHeight: headerHeight)
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
        y: headerHeight + 8,
        width: max(bounds.width - horizontalInset * 2, 1),
        height: searchHeight
      )
    }

    borderView.frame = CGRect(x: 0, y: barHeight - 1, width: bounds.width, height: 1)
    overlayBackButton?.frame = CGRect(x: 8, y: 8, width: 30, height: 30)

    contentView.frame = CGRect(
      x: 0,
      y: barHeight,
      width: bounds.width,
      height: bounds.height - barHeight
    )
  }

  private func measuredNavBarHeight() -> CGFloat {
    let headerHeight = measuredHeaderHeight()
    let searchHeight = measuredSearchHeight()
    if searchHeight > 0 {
      return headerHeight + 8 + searchHeight + 8
    }
    return headerHeight
  }

  private func measuredHeaderHeight() -> CGFloat {
    #if canImport(UIKit)
      let baseline = UINavigationBar().sizeThatFits(
        CGSize(width: bounds.width, height: UIView.layoutFittingCompressedSize.height)
      ).height
    #elseif canImport(AppKit)
      let baseline = max(NSButton().fittingSize.height, titleView.fittingSize.height)
    #endif

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
    let backHeight = inlineBackButtonSize(headerHeight: baseline).height
    return max(
      baseline,
      titleSize.height + 16,
      leadingHeight + 16,
      trailingHeight + 16,
      backHeight + 16
    )
  }

  private func measuredSearchHeight() -> CGFloat {
    guard let searchView else { return 0 }
    #if canImport(UIKit)
      return max(
        searchView.sizeThatFits(
          CGSize(
            width: max(bounds.width - 32, 1), height: UIView.layoutFittingCompressedSize.height)
        ).height,
        44
      )
    #elseif canImport(AppKit)
      return max(searchView.fittingSize.height, 28)
    #endif
  }

  private func inlineBackButtonSize(headerHeight: CGFloat) -> CGSize {
    guard let inlineBackButton else { return .zero }
    #if canImport(UIKit)
      return inlineBackButton.sizeThatFits(
        CGSize(width: max(bounds.width * 0.4, 44), height: max(headerHeight, 44))
      )
    #elseif canImport(AppKit)
      return inlineBackButton.sizeThatFits(
        CGSize(width: max(bounds.width * 0.4, 44), height: max(headerHeight, 24))
      )
    #endif
  }
}
