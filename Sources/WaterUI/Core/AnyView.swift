//
//  AnyView.swift
//
//
//  Created by Lexo Liu on 8/1/24.
//

import CWaterUI
import Foundation
import os

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

@MainActor
protocol WuiFirstPaintReadyParticipant: AnyObject, Sendable {
  func prepareForReady()
  func waitForReady() async -> Bool
  func participatesInFirstPaintReady() -> Bool
}

@MainActor
private func waitForFirstPaintReadyParticipants(
  _ participants: [any WuiFirstPaintReadyParticipant]
) async {
  let tasks = participants.map { participant in
    Task { @MainActor in await participant.waitForReady() }
  }
  for task in tasks {
    let ready = await task.value
    precondition(ready, "A visible GPU participant failed to render its first frame")
  }
}

// MARK: - Component Registry

/// Internal registry for component factories using pointer-based ID lookup
@MainActor
private var componentRegistry: [WuiViewId: (OpaquePointer, WuiEnvironment) -> any WuiComponent] =
  [:]

/// Set of metadata component IDs (components that wrap content but aren't "real" content themselves)
@MainActor
private var metadataComponentIds: Set<WuiViewId> = []

/// Internal flag to track if builtin components have been registered
@MainActor
private var builtinComponentsRegistered = false

/// Register a component type that conforms to WuiComponent.
@MainActor
public func registerComponent<T: WuiComponent>(_ type: T.Type) {
  registerBuiltinComponentsIfNeeded()
  let viewId = type.viewId
  componentRegistry[viewId] = { anyview, env in
    type.init(anyview: anyview, env: env)
  }
}

/// Register a metadata component type (wrappers that modify env/appearance but aren't content).
@MainActor
private func registerMetadataComponent<T: WuiComponent>(_ type: T.Type) {
  registerComponent(type)
  metadataComponentIds.insert(type.viewId)
}

/// Check if a component is a metadata component (wrapper that modifies env/appearance).
@MainActor
func isMetadataComponent(_ component: any WuiComponent) -> Bool {
  metadataComponentIds.contains(type(of: component).viewId)
}

// MARK: - Root Theme Controller

/// Controls the window's appearance based on the root component's environment theme.
@MainActor
final class RootThemeController {
  private var colorSchemeObservation: WuiComputedObservation<WuiColorScheme>?
  private weak var view: PlatformView?
  private var currentScheme: WuiColorScheme?

  init(env: WuiEnvironment, view: PlatformView) {
    self.view = view
    setupColorSchemeWatcher(env: env)
  }

  private func setupColorSchemeWatcher(env: WuiEnvironment) {
    guard let signal = waterui_theme_color_scheme(env.inner) else {
      fatalError("Root WaterUI environment is missing its color scheme signal")
    }

    let observation = WuiComputedObservation(WuiComputed<WuiColorScheme>(signal)) {
      [weak self] scheme, _ in
      self?.applyColorScheme(scheme)
    }
    colorSchemeObservation = observation
    applyColorScheme(observation.value)
  }

  private func applyColorScheme(_ scheme: WuiColorScheme) {
    currentScheme = scheme
    applyToWindow()
  }

  /// Called when the view is added to window
  func applyToWindow() {
    guard let scheme = currentScheme, let window = view?.window else {
      return
    }

    #if canImport(UIKit)
      let style: UIUserInterfaceStyle =
        switch scheme {
        case WuiColorScheme_Light: .light
        case WuiColorScheme_Dark: .dark
        default: fatalError("Unknown WaterUI color scheme value: \(scheme)")
        }
      window.overrideUserInterfaceStyle = style
    #elseif canImport(AppKit)
      let appearance: NSAppearance? =
        switch scheme {
        case WuiColorScheme_Light: NSAppearance(named: .aqua)
        case WuiColorScheme_Dark: NSAppearance(named: .darkAqua)
        default: fatalError("Unknown WaterUI color scheme value: \(scheme)")
        }

      // Set appearance on window and all its content
      window.appearance = appearance
      window.contentView?.appearance = appearance

      // Force redraw
      window.contentView?.needsDisplay = true
      window.contentView?.needsLayout = true
      window.viewsNeedDisplay = true
    #endif
  }
}

/// Register builtin components (called once on first WuiAnyView creation)
@MainActor
private func registerBuiltinComponentsIfNeeded() {
  guard !builtinComponentsRegistered else { return }
  builtinComponentsRegistered = true

  // Basic components
  registerComponent(WuiEmpty.self)
  registerComponent(WuiPlain.self)
  registerComponent(WuiText.self)
  registerComponent(WuiSpacer.self)
  registerComponent(WuiColorView.self)
  registerComponent(WuiResolvedColorView.self)
  registerComponent(WuiResolvedGradientView.self)
  registerComponent(WuiResolvedShape.self)
  registerComponent(WuiSystemIcon.self)

  // Interactive components
  registerComponent(WuiButton.self)
  registerComponent(WuiToggle.self)
  registerComponent(WuiSlider.self)
  registerComponent(WuiTextField.self)
  registerComponent(WuiSecureField.self)
  registerComponent(WuiStepper.self)
  registerComponent(WuiDatePicker.self)
  registerComponent(WuiMultiDatePicker.self)
  registerComponent(WuiColorPicker.self)
  registerComponent(WuiPicker.self)
  registerComponent(WuiProgress.self)
  registerComponent(WuiMenu.self)

  // Container components
  registerComponent(WuiFixedContainer.self)
  registerComponent(WuiContainer.self)
  registerComponent(WuiScroll.self)
  registerComponent(WuiList.self)
  registerComponent(WuiTable.self)

  // Dynamic components
  registerComponent(WuiDynamic.self)

  // Metadata components (wrappers that modify env/appearance)
  registerMetadataComponent(WuiWithEnv.self)
  registerMetadataComponent(WuiSecure.self)
  registerMetadataComponent(WuiStandardDynamicRange.self)
  registerMetadataComponent(WuiHighDynamicRange.self)
  registerMetadataComponent(WuiGesture.self)
  registerMetadataComponent(WuiLifecycleHook.self)
  registerMetadataComponent(WuiOnEvent.self)
  registerMetadataComponent(WuiCursor.self)
  registerMetadataComponent(WuiAccessibilityIdentifier.self)
  registerMetadataComponent(WuiShadow.self)
  registerMetadataComponent(WuiBorder.self)
  registerMetadataComponent(WuiClipShape.self)
  registerMetadataComponent(WuiOpacity.self)
  registerMetadataComponent(WuiScale.self)
  registerMetadataComponent(WuiRotation.self)
  registerMetadataComponent(WuiOffset.self)
  registerMetadataComponent(WuiFocused.self)
  registerMetadataComponent(WuiIgnoreSafeArea.self)
  registerMetadataComponent(WuiRetain.self)
  registerMetadataComponent(WuiContextMenu.self)
  registerMetadataComponent(WuiHittable.self)
  registerMetadataComponent(WuiNavigationTransitionSourceView.self)
  registerMetadataComponent(WuiNavigationTransitionDestinationView.self)

  // Material background (blur effect)
  registerMetadataComponent(WuiMaterialBackground.self)

  // Drag and drop components
  registerMetadataComponent(WuiDraggable.self)
  registerMetadataComponent(WuiDropDestination.self)

  // Media components
  registerComponent(WuiVideo.self)
  registerComponent(WuiVideoPlayer.self)

  // Navigation components
  registerComponent(WuiNavigationStack.self)
  registerComponent(WuiNavigationView.self)
  registerComponent(WuiNavigationSplitView.self)
  registerComponent(WuiTabs.self)

  // GPU components
  registerComponent(WuiGpuSurface.self)
  registerComponent(WuiViewEffect.self)
  registerMetadataComponent(WuiAppliedFilter.self)

  // WebView component
  registerComponent(WuiWebViewComponent.self)

  // Map component. Off unless the app enabled WaterUI's `map` feature, which
  // is what exports the map symbols this component binds to.
  #if WATERUI_MAP
    registerComponent(WuiMapViewComponent.self)
  #endif
}

// MARK: - WuiAnyView

#if canImport(UIKit)
  /// The entry point for WaterUI views from Rust.
  /// Resolves an opaque FFI pointer into a concrete WuiComponent at initialization time.
  @MainActor
  public final class WuiAnyView: UIView, WuiComponent {
    public static var rawId: CWaterUI.WuiTypeId { waterui_anyview_id() }

    /// The resolved inner component - never nil after initialization
    private let inner: any WuiComponent
    private let themeEnvironment: WuiEnvironment
    private var rootThemeController: RootThemeController?
    private var lastAutoLayoutWidth: CGFloat = 0

    public var stretchAxis: WuiStretchAxis {
      inner.stretchAxis
    }

    /// Creates a WuiAnyView by resolving an opaque FFI pointer to a concrete component.
    /// This is the public interface for creating WaterUI views from Rust pointers.
    public init(anyview: OpaquePointer, env: WuiEnvironment) {
      registerBuiltinComponentsIfNeeded()
      self.themeEnvironment = env
      self.inner = Self.resolve(anyview: anyview, env: env)
      super.init(frame: .zero)

      // Allow content to draw outside bounds (needed for ignore_safe_area)
      clipsToBounds = false

      // Embed the resolved view using manual frame layout (not AutoLayout)
      // This is critical: WaterUI uses Rust layout engine, not AutoLayout
      inner.translatesAutoresizingMaskIntoConstraints = true
      addSubview(inner)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    public func layoutPriority() -> Int32 {
      inner.layoutPriority()
    }

    public func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
      inner.sizeThatFits(proposal)
    }

    public func measure(_ proposal: WuiProposalSize) -> WuiViewDimensions {
      inner.measure(proposal)
    }

    /// Returns intrinsic content size for UIKit Auto Layout integration.
    /// This allows WaterUI views to participate in Auto Layout constraints.
    override public var intrinsicContentSize: CGSize {
      var intrinsic = sizeThatFits(WuiProposalSize())

      // When the host constrains our width via Auto Layout, keep the natural (content) width
      // but recompute height using the current width so multiline content can wrap correctly.
      guard !translatesAutoresizingMaskIntoConstraints, bounds.width > 0 else {
        return applyStretchAxisToIntrinsicSize(intrinsic)
      }

      let constrained = sizeThatFits(WuiProposalSize(width: Float(bounds.width), height: nil))
      intrinsic.height = constrained.height
      return applyStretchAxisToIntrinsicSize(intrinsic)
    }

    override public func sizeThatFits(_ size: CGSize) -> CGSize {
      sizeThatFits(WuiProposalSize(size: size))
    }

    override public func layoutSubviews() {
      super.layoutSubviews()
      // Manually size inner view to fill bounds and trigger nested layout
      inner.frame = bounds
      inner.setNeedsLayout()
      inner.layoutIfNeeded()

      // If the host constrains our width via Auto Layout, re-measure with that width so
      // multiline text (and other width-dependent layouts) can grow vertically.
      if !translatesAutoresizingMaskIntoConstraints, bounds.width > 0,
        bounds.width != lastAutoLayoutWidth
      {
        lastAutoLayoutWidth = bounds.width
        invalidateIntrinsicContentSize()
      }
    }

    private func applyStretchAxisToIntrinsicSize(_ size: CGSize) -> CGSize {
      switch stretchAxis {
      case .none:
        return size
      case .horizontal:
        return CGSize(width: UIView.noIntrinsicMetric, height: size.height)
      case .vertical:
        return CGSize(width: size.width, height: UIView.noIntrinsicMetric)
      case .both, .mainAxis, .crossAxis:
        return CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
      }
    }

    override public func didMoveToWindow() {
      super.didMoveToWindow()
      if window != nil {
        setupRootThemeControllerIfNeeded()
      }
    }

    private func setupRootThemeControllerIfNeeded() {
      guard !hasAnyViewAncestor() else { return }
      if rootThemeController == nil {
        rootThemeController = RootThemeController(env: themeEnvironment, view: self)
      }
      rootThemeController?.applyToWindow()
    }

    private func hasAnyViewAncestor() -> Bool {
      var ancestor = superview
      while let current = ancestor {
        if current is WuiAnyView { return true }
        ancestor = current.superview
      }
      return false
    }

    // MARK: - Async Ready

    /// Wait for all GpuSurfaces in the view tree to complete setup and first render.
    /// Call this before showing the window to prevent flicker.
    @MainActor
    public func ready() async {
      let all = collectFirstPaintReadyParticipants()
      for participant in all {
        participant.prepareForReady()
      }
      let participants = firstPaintReadyParticipants(all)
      guard !participants.isEmpty else { return }

      await waitForFirstPaintReadyParticipants(participants)
    }

    private func firstPaintReadyParticipants(_ all: [any WuiFirstPaintReadyParticipant])
      -> [any WuiFirstPaintReadyParticipant]
    {
      let eligible = all.filter { $0.participatesInFirstPaintReady() }
      return eligible
    }

    /// Recursively collects GPU-backed participants that must be ready before first paint.
    private func collectFirstPaintReadyParticipants() -> [any WuiFirstPaintReadyParticipant] {
      var participants: [any WuiFirstPaintReadyParticipant] = []
      collectFirstPaintReadyParticipantsRecursive(from: self, into: &participants)
      return participants
    }

    private func collectFirstPaintReadyParticipantsRecursive(
      from view: UIView,
      into participants: inout [any WuiFirstPaintReadyParticipant]
    ) {
      if let participant = view as? any WuiFirstPaintReadyParticipant {
        participants.append(participant)
      }
      for subview in view.subviews {
        collectFirstPaintReadyParticipantsRecursive(from: subview, into: &participants)
      }
    }

    // MARK: - Internal Resolution

    internal static func resolve(anyview: OpaquePointer, env: WuiEnvironment)
      -> any WuiComponent
    {
      let viewId = WuiViewId(waterui_view_id(anyview))

      // Look up registered component factory - O(1) pointer-based lookup
      if let factory = componentRegistry[viewId] {
        return factory(anyview, env)
      }

      if let next = waterui_view_body(anyview, env.inner) {
        return resolve(anyview: next, env: env)
      }

      fatalError("Unsupported component type: \(viewId.toString())")
    }
  }

#elseif canImport(AppKit)
  /// The entry point for WaterUI views from Rust.
  /// Resolves an opaque FFI pointer into a concrete WuiComponent at initialization time.
  @MainActor
  public final class WuiAnyView: NSView, WuiComponent {
    public static var rawId: CWaterUI.WuiTypeId { waterui_anyview_id() }

    /// The resolved inner component - never nil after initialization
    private let inner: any WuiComponent
    private let themeEnvironment: WuiEnvironment
    private var rootThemeController: RootThemeController?
    private var lastAutoLayoutWidth: CGFloat = 0
    private var pendingWindowMinSizeUpdate = false
    private var lastWindowMinSize: NSSize = .zero

    /// Explicit `Window::min_size` from the app. When set, it drives
    /// `NSWindow.contentMinSize` and the measured content minimum no longer
    /// applies (the app has taken over the resize floor).
    public var explicitWindowMinSize: NSSize? {
      didSet { updateWindowMinSizeIfNeeded(force: true) }
    }
    private var lastMinSizeProbeBounds: NSSize = .zero

    public var stretchAxis: WuiStretchAxis {
      inner.stretchAxis
    }

    /// Creates a WuiAnyView by resolving an opaque FFI pointer to a concrete component.
    /// This is the public interface for creating WaterUI views from Rust pointers.
    public init(anyview: OpaquePointer, env: WuiEnvironment) {
      registerBuiltinComponentsIfNeeded()
      self.themeEnvironment = env
      self.inner = Self.resolve(anyview: anyview, env: env)
      super.init(frame: .zero)

      // Embed the resolved view using manual frame layout (not AutoLayout)
      // This is critical: WaterUI uses Rust layout engine, not AutoLayout
      inner.translatesAutoresizingMaskIntoConstraints = true
      addSubview(inner)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    public func layoutPriority() -> Int32 {
      inner.layoutPriority()
    }

    public func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
      inner.sizeThatFits(proposal)
    }

    public func measure(_ proposal: WuiProposalSize) -> WuiViewDimensions {
      inner.measure(proposal)
    }

    /// Returns intrinsic content size for AppKit Auto Layout integration.
    /// This allows WaterUI views to participate in Auto Layout constraints.
    override public var intrinsicContentSize: NSSize {
      var intrinsic = sizeThatFits(WuiProposalSize())

      // When the host constrains our width via Auto Layout, keep the natural (content) width
      // but recompute height using the current width so multiline content can wrap correctly.
      guard !translatesAutoresizingMaskIntoConstraints, bounds.width > 0 else {
        return applyStretchAxisToIntrinsicSize(intrinsic)
      }

      let constrained = sizeThatFits(WuiProposalSize(width: Float(bounds.width), height: nil))
      intrinsic.height = constrained.height
      return applyStretchAxisToIntrinsicSize(intrinsic)
    }

    override public var isFlipped: Bool { true }

    public func sizeThatFits(_ size: NSSize) -> NSSize {
      sizeThatFits(WuiProposalSize(size: size))
    }

    override public func layout() {
      super.layout()
      // Manually size inner view to fill bounds
      inner.frame = bounds

      // If the host constrains our width via Auto Layout, re-measure with that width so
      // multiline text (and other width-dependent layouts) can grow vertically.
      if !translatesAutoresizingMaskIntoConstraints, bounds.width > 0,
        bounds.width != lastAutoLayoutWidth
      {
        lastAutoLayoutWidth = bounds.width
        invalidateIntrinsicContentSize()
      }
      if isWindowRootContent(), bounds.size != lastMinSizeProbeBounds {
        lastMinSizeProbeBounds = bounds.size
        scheduleWindowMinSizeUpdate()
      }
    }

    private func applyStretchAxisToIntrinsicSize(_ size: NSSize) -> NSSize {
      switch stretchAxis {
      case .none:
        return size
      case .horizontal:
        return NSSize(width: NSView.noIntrinsicMetric, height: size.height)
      case .vertical:
        return NSSize(width: size.width, height: NSView.noIntrinsicMetric)
      case .both, .mainAxis, .crossAxis:
        return NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
      }
    }

    override public func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if window != nil {
        setupRootThemeControllerIfNeeded()
        lastMinSizeProbeBounds = .zero
        if isWindowRootContent() {
          scheduleWindowMinSizeUpdate()
        }
      }
    }

    private func setupRootThemeControllerIfNeeded() {
      guard !hasAnyViewAncestor() else { return }
      if rootThemeController == nil {
        rootThemeController = RootThemeController(env: themeEnvironment, view: self)
      }
      rootThemeController?.applyToWindow()
    }

    private func hasAnyViewAncestor() -> Bool {
      var ancestor = superview
      while let current = ancestor {
        if current is WuiAnyView { return true }
        ancestor = current.superview
      }
      return false
    }

    func refreshWindowMinSize(force: Bool = false) {
      guard isWindowRootContent() else { return }
      updateWindowMinSizeIfNeeded(force: force)
    }

    private func scheduleWindowMinSizeUpdate() {
      guard !pendingWindowMinSizeUpdate else { return }
      pendingWindowMinSizeUpdate = true
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.pendingWindowMinSizeUpdate = false
        self.updateWindowMinSizeIfNeeded(force: false)
      }
    }

    private func updateWindowMinSizeIfNeeded(force: Bool) {
      guard let window else { return }
      guard isWindowRootContent() else { return }

      if let explicit = explicitWindowMinSize {
        let didChange =
          abs(explicit.width - lastWindowMinSize.width) > 0.5
          || abs(explicit.height - lastWindowMinSize.height) > 0.5
        if force || didChange {
          window.contentMinSize = explicit
          lastWindowMinSize = explicit
        }
        return
      }

      let minMeasured = sizeThatFits(WuiProposalSize(width: 0, height: 0))
      let idealMeasured = sizeThatFits(WuiProposalSize())
      let measuredWidth = firstSpecifiedWindowAxis(minMeasured.width, idealMeasured.width)
      let measuredHeight = firstSpecifiedWindowAxis(minMeasured.height, idealMeasured.height)

      guard let screenBounds = window.screen?.visibleFrame.size else {
        fatalError("Window minimum-size resolution requires an attached display")
      }
      let screenMaxWidth = screenBounds.width
      let screenMaxHeight = screenBounds.height

      let previousWidth =
        firstSpecifiedWindowAxis(lastWindowMinSize.width, window.contentMinSize.width)
      let previousHeight =
        firstSpecifiedWindowAxis(lastWindowMinSize.height, window.contentMinSize.height)

      // Use measured minima when available; otherwise keep the last stable value.
      var nextWidth = measuredWidth ?? previousWidth ?? 0
      var nextHeight = measuredHeight ?? previousHeight ?? 0

      nextWidth = min(max(nextWidth, 0), screenMaxWidth)
      nextHeight = min(max(nextHeight, 0), screenMaxHeight)

      // If this update had no valid measurement for an axis, never lower that axis below
      // the last committed minimum.
      if measuredWidth == nil, let previousWidth {
        nextWidth = max(nextWidth, previousWidth)
      }
      if measuredHeight == nil, let previousHeight {
        nextHeight = max(nextHeight, previousHeight)
      }

      let nextMin = NSSize(width: nextWidth, height: nextHeight)

      let didChange =
        abs(nextMin.width - lastWindowMinSize.width) > 0.5
        || abs(nextMin.height - lastWindowMinSize.height) > 0.5
      if force || didChange {
        window.contentMinSize = nextMin
        lastWindowMinSize = nextMin
      }
    }

    private func isWindowRootContent() -> Bool {
      guard let window else { return false }
      return superview === window.contentView
    }

    /// Layout represents an unspecified axis with zero, a non-finite value, or
    /// `noIntrinsicMetric`; choose the first proposal that actually specifies one.
    private func firstSpecifiedWindowAxis(_ first: CGFloat, _ second: CGFloat) -> CGFloat? {
      if first.isFinite, first > 0 {
        return first
      }
      if second.isFinite, second > 0 {
        return second
      }
      return nil
    }

    // MARK: - Async Ready

    /// Wait for all GpuSurfaces in the view tree to complete setup and first render.
    /// Call this before showing the window to prevent flicker.
    @MainActor
    public func ready() async {
      let all = collectFirstPaintReadyParticipants()
      for participant in all {
        participant.prepareForReady()
      }
      let participants = firstPaintReadyParticipants(all)
      guard !participants.isEmpty else { return }

      await waitForFirstPaintReadyParticipants(participants)
    }

    private func firstPaintReadyParticipants(_ all: [any WuiFirstPaintReadyParticipant])
      -> [any WuiFirstPaintReadyParticipant]
    {
      let eligible = all.filter { $0.participatesInFirstPaintReady() }
      return eligible
    }

    /// Recursively collects GPU-backed participants that must be ready before first paint.
    private func collectFirstPaintReadyParticipants() -> [any WuiFirstPaintReadyParticipant] {
      var participants: [any WuiFirstPaintReadyParticipant] = []
      collectFirstPaintReadyParticipantsRecursive(from: self, into: &participants)
      return participants
    }

    private func collectFirstPaintReadyParticipantsRecursive(
      from view: NSView,
      into participants: inout [any WuiFirstPaintReadyParticipant]
    ) {
      if let participant = view as? any WuiFirstPaintReadyParticipant {
        participants.append(participant)
      }
      for subview in view.subviews {
        collectFirstPaintReadyParticipantsRecursive(from: subview, into: &participants)
      }
    }

    // MARK: - Internal Resolution

    internal static func resolve(anyview: OpaquePointer, env: WuiEnvironment)
      -> any WuiComponent
    {
      let viewId = WuiViewId(waterui_view_id(anyview))

      // Look up registered component factory - O(1) pointer-based lookup
      if let factory = componentRegistry[viewId] {
        return factory(anyview, env)
      }

      if let next = waterui_view_body(anyview, env.inner) {
        return resolve(anyview: next, env: env)
      }

      fatalError("Unsupported component type: \(viewId.toString())")
    }
  }
#endif
