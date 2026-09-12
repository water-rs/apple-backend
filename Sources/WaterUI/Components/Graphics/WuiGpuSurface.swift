// Compiled out when the app disables WaterUI's `gpu` feature: the
// `waterui_*` GPU symbols this file binds do not exist in that build.
#if !WATERUI_NO_GPU
// WuiGpuSurface.swift
// High-performance GPU rendering surface using wgpu
//
// # Layout Behavior
// GpuSurface stretches to fill available space by default (like SwiftUI's Color).
// Users can control size using the `.frame()` modifier externally.
//
// # Rendering
// Frames are rendered into a pair of IOSurface-backed textures this view owns
// and shown as a plain layer's `contents`, at the display's highest refresh
// rate. The Rust side owns the wgpu Device and Queue and calls the user's
// GpuRenderer callbacks.
//
// # HDR Support
// An HDR surface is allocated half-float in an extended-range colour space,
// which is what asks Core Animation to composite it as EDR.

import CWaterUI
import Foundation
import Metal
import OSLog
import QuartzCore

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

private typealias WuiGpuSurfaceReadyCompletion = @MainActor @Sendable (Bool) -> Void
private typealias WuiGpuSurfaceSetupCompletion = @MainActor @Sendable () -> Void

@MainActor
final class WuiExternalRenderingScopes {
  private var redrawHandlers: [(() -> Void)?] = []

  var isActive: Bool { !redrawHandlers.isEmpty }

  func begin(onRedraw: (() -> Void)?) -> Bool {
    let wasInactive = redrawHandlers.isEmpty
    redrawHandlers.append(onRedraw)
    return wasInactive
  }

  func end() -> Bool {
    precondition(!redrawHandlers.isEmpty, "GpuSurface external rendering scopes are unbalanced")
    redrawHandlers.removeLast()
    return redrawHandlers.isEmpty
  }

  func notifyRedraw() {
    for handler in redrawHandlers {
      handler?()
    }
  }
}

@MainActor
private final class WuiGpuSurfaceRenderState {
  private let gpuState: OpaquePointer
  private var isAttached = false
  private var externalRendering = false
  private var rendererSetupStarted = false
  private var needsRender = true
  /// True while a Rust render call is on the stack. The renderer holds its
  /// semantic view mutably for that whole call, so a redraw wake that arrives
  /// in the middle of it (a `GpuView` whose render pumps an engine that paints
  /// synchronously, as CEF does) must not lay out or measure until the call
  /// returns; `handleExternalRedrawRequest` parks it in `wakeDeferredByRender`.
  private var isRendering = false
  private var wakeDeferredByRender = false
  private var lastResolvedMeasurement: WuiViewDimensions
  private var lastProposal: WuiProposalSize?
  private var deferredMeasurementInvalidation = false
  private let cachedPriority: Int32
  private var width: UInt32 = 0
  private var height: UInt32 = 0
  /// Physical pixels per logical point, reported to the renderer with every
  /// frame. It follows the layer's `contentsScale`, so a window dragged onto a
  /// display of a different density updates it on the next layout pass.
  private var scale: CGFloat = 1.0
  var onRedrawRequested: (() -> Void)?
  /// The input responder's borrow of `gpuState`, invalidated before the drop.
  private weak var inputCarrier: WuiGpuSurfaceInputCarrier?

  // Pointer/cursor state for GPU renderers
  private var pointerState = WuiPointerState(
    has_position: false,
    x: 0,
    y: 0,
    has_hit: false,
    hit_x: 0,
    hit_y: 0
  )

  // Gesture state for zoom/pan interactions
  private var gestureState = WuiGestureState(
    active: false,
    pinch_scale: 1.0,
    has_pinch_center: false,
    pinch_center_x: 0,
    pinch_center_y: 0,
    pan_offset_x: 0,
    pan_offset_y: 0,
    double_tap: false
  )

  let explicitDynamicRangePreference: WuiDynamicRangeMode?

  init(ffiSurface: CWaterUI.WuiGpuSurface, envPtr: OpaquePointer) {
    var descriptor = ffiSurface
    let preference = withUnsafeMutablePointer(to: &descriptor) { surfacePtr in
      waterui_gpu_surface_hdr_preference(surfacePtr)
    }
    self.explicitDynamicRangePreference =
      preference.has_preference
      ? (preference.prefers_hdr ? .high : .standard)
      : nil
    guard
      let state = withUnsafeMutablePointer(
        to: &descriptor,
        {
          waterui_gpu_surface_create($0, envPtr)
        })
    else {
      fatalError("waterui_gpu_surface_create returned null")
    }
    self.gpuState = state
    self.lastResolvedMeasurement = WuiViewDimensions(
      waterui_gpu_surface_measure(state, WuiProposalSize().toCStruct()))
    self.cachedPriority = waterui_gpu_surface_priority(state)
  }

  var isSurfaceAttached: Bool { isAttached }
  var isSetupReady: Bool { waterui_gpu_surface_is_ready(gpuState) }

  /// What the semantic GPU view says about itself, for a screen reader.
  ///
  /// Empty until asynchronous renderer setup finishes, and for every view that
  /// draws nothing a reader needs told about.
  var accessibilityLabelFromContent: String {
    WuiStr(waterui_gpu_surface_accessibility_label(gpuState)).toString()
  }

  /// Whether the semantic GPU view draws interactive content and therefore
  /// takes the raw input events instead of the per-frame pointer snapshot.
  var wantsInputEvents: Bool {
    WuiGpuSurfaceInputCarrier.wantsInputEvents(gpuState: gpuState)
  }

  /// A borrow of this state for the input responder to forward events through.
  ///
  /// The carrier holds no ownership: `shutdown()` invalidates it before the
  /// state is dropped, so a responder that outlives the surface forwards
  /// nothing rather than writing through a dangling handle.
  func makeInputCarrier() -> WuiGpuSurfaceInputCarrier {
    let carrier = WuiGpuSurfaceInputCarrier(gpuState: gpuState)
    inputCarrier = carrier
    return carrier
  }

  func installRedrawCallback() {
    let callback = WuiRedrawCallbackBox { [weak self] in
      self?.handleExternalRedrawRequest()
    }
    waterui_gpu_surface_set_redraw_callback(
      gpuState,
      Unmanaged.passRetained(callback).toOpaque(),
      wuiRedrawWakeCallback,
      wuiRedrawDropCallback
    )
  }

  /// Update pointer position (in surface-local pixel coordinates).
  func updatePointerPosition(_ position: CGPoint?, scaleFactor: CGFloat) {
    needsRender = true
    if let pos = position {
      pointerState.has_position = true
      pointerState.x = Float(pos.x * scaleFactor)
      pointerState.y = Float(pos.y * scaleFactor)
    } else {
      pointerState.has_position = false
    }
  }

  /// Update pointer hit state.
  func updatePointerHit(_ origin: CGPoint?, scaleFactor: CGFloat) {
    needsRender = true
    if let origin {
      pointerState.has_hit = true
      pointerState.hit_x = Float(origin.x * scaleFactor)
      pointerState.hit_y = Float(origin.y * scaleFactor)
    } else {
      pointerState.has_hit = false
    }
  }

  /// Update gesture state for pinch zoom.
  func updatePinchGesture(active: Bool, scale: CGFloat, center: CGPoint?, scaleFactor: CGFloat) {
    needsRender = true
    gestureState.active = active
    gestureState.pinch_scale = Float(scale)
    if let center = center {
      gestureState.has_pinch_center = true
      gestureState.pinch_center_x = Float(center.x * scaleFactor)
      gestureState.pinch_center_y = Float(center.y * scaleFactor)
    } else {
      gestureState.has_pinch_center = false
    }
  }

  /// Update gesture state for pan.
  func updatePanGesture(active: Bool, offsetX: CGFloat, offsetY: CGFloat, scaleFactor: CGFloat) {
    needsRender = true
    gestureState.active = active
    gestureState.pan_offset_x = Float(offsetX * scaleFactor)
    gestureState.pan_offset_y = Float(offsetY * scaleFactor)
  }

  /// Signal a double-tap gesture.
  func triggerDoubleTap() {
    needsRender = true
    gestureState.double_tap = true
  }

  /// Clear double-tap flag (called after rendering).
  private func clearDoubleTap() {
    gestureState.double_tap = false
  }

  /// Reset gesture state when gesture ends.
  func resetGestureState() {
    needsRender = true
    gestureState.active = false
    gestureState.pinch_scale = 1.0
    gestureState.has_pinch_center = false
    gestureState.pan_offset_x = 0
    gestureState.pan_offset_y = 0
  }

  /// Send current pointer + gesture state to the GPU surface before rendering.
  private func syncInputState() {
    let input = WuiGpuSurfaceInput(pointer: pointerState, gesture: gestureState)
    waterui_gpu_surface_set_input(gpuState, input)
    // Clear double_tap after sending (it's a one-frame signal)
    clearDoubleTap()
  }

  @discardableResult
  func updateSize(width: UInt32, height: UInt32, scale: CGFloat) -> Bool {
    guard self.width != width || self.height != height || self.scale != scale else { return false }
    needsRender = true
    self.width = width
    self.height = height
    self.scale = scale
    return true
  }

  /// Starts the renderer against the format the host will present in.
  ///
  /// There is no surface to attach: the host owns the textures and hands one in
  /// with every frame, so all the renderer needs is the format it must produce.
  @discardableResult
  func attachIfNeeded(
    texturePtr: UnsafeMutableRawPointer,
    width: UInt32,
    height: UInt32,
    scale: CGFloat
  ) -> Bool {
    _ = updateSize(width: width, height: height, scale: scale)
    guard !isAttached else { return false }
    waterui_gpu_surface_prepare_metal_texture(gpuState, texturePtr)
    rendererSetupStarted = true
    isAttached = true
    needsRender = true
    return true
  }

  func detachIfNeeded() {
    guard isAttached else { return }
    isAttached = false
  }

  /// Renders one frame into a texture the host presents, or answers why it
  /// could not.
  ///
  /// There is no "needs another frame" answer to carry back: a renderer that
  /// wants one asks for it through the redraw callback, which arms the clock
  /// on its own.
  func renderIntoPresentedTexture(
    _ texture: MTLTexture,
    force: Bool = false
  ) -> OpaquePointer? {
    guard !externalRendering else { return nil }
    guard force || needsRender else { return nil }
    guard isAttached, width > 0, height > 0, scale > 0 else { return nil }
    guard isSetupReady else {
      needsRender = true
      return nil
    }

    needsRender = false
    return renderPreparedMetalTexture(
      texturePtr: Unmanaged.passUnretained(texture).toOpaque(),
      width: width,
      height: height,
      scale: scale
    )
  }

  /// Runs one Rust render call, replaying any redraw wake that arrived while
  /// it was on the stack once the renderer has released its view again.
  private func withRenderInProgress<T>(_ render: () -> T) -> T {
    precondition(!isRendering, "GpuSurface render re-entered while a render call was in progress")
    isRendering = true
    let result = render()
    isRendering = false
    if wakeDeferredByRender {
      wakeDeferredByRender = false
      onRedrawRequested?()
    }
    return result
  }

  func setExternalRendering(_ enabled: Bool) {
    precondition(externalRendering != enabled, "GpuSurface external rendering state did not change")
    externalRendering = enabled
    if !enabled {
      needsRender = true
    }
  }

  func prepareMetalTexture(_ texturePtr: UnsafeMutableRawPointer) -> Bool {
    waterui_gpu_surface_prepare_metal_texture(gpuState, texturePtr)
    rendererSetupStarted = true
    return isSetupReady
  }

  func renderPreparedMetalTexture(
    texturePtr: UnsafeMutableRawPointer,
    width: UInt32,
    height: UInt32,
    scale: CGFloat
  ) -> OpaquePointer {
    precondition(width > 0 && height > 0, "External texture rendering requires non-zero dimensions")
    precondition(scale > 0, "External texture rendering requires a positive device-pixel ratio")
    precondition(isSetupReady, "External texture rendering requires completed asynchronous setup")
    syncInputState()
    let fence = withRenderInProgress {
      waterui_gpu_surface_render_to_metal_texture(
        gpuState,
        texturePtr,
        width,
        height,
        Double(scale)
      )
    }
    guard let fence else {
      fatalError("waterui_gpu_surface_render_to_metal_texture returned null")
    }
    return fence
  }

  func measure(_ proposal: WuiProposalSize) -> WuiViewDimensions {
    lastProposal = proposal
    if !rendererSetupStarted || isSetupReady {
      let dimensions = WuiViewDimensions(
        waterui_gpu_surface_measure(gpuState, proposal.toCStruct()))
      lastResolvedMeasurement = dimensions
      return dimensions
    }
    // GpuView::setup(&mut self).await owns the semantic renderer until ready,
    // while native layout remains synchronous. Reuse the last real measurement
    // and invalidate once setup returns ownership to the FFI state.
    deferredMeasurementInvalidation = true
    return lastResolvedMeasurement
  }

  /// Whether the host laid this surface out with a measurement the renderer
  /// no longer gives.
  ///
  /// A `GpuView` whose content changes size — a photo whose first frame just
  /// decoded — requests a redraw, which is the only signal it has; native
  /// layout is on demand, so the surface asks the renderer again with the
  /// proposal it was last measured with and reports a stale box to the host.
  ///
  /// Asked whenever the renderer can answer — before setup starts as well as
  /// after it completes — and not only once the surface is attached: a
  /// content-sized view that first measured empty was never given the bounds
  /// that attaching requires, so gating this on setup would leave it empty
  /// for good.
  func takeMeasurementInvalidation() -> Bool {
    if deferredMeasurementInvalidation {
      guard isSetupReady else { return false }
      deferredMeasurementInvalidation = false
      return true
    }
    guard !rendererSetupStarted || isSetupReady, let proposal = lastProposal else {
      return false
    }
    let dimensions = WuiViewDimensions(
      waterui_gpu_surface_measure(gpuState, proposal.toCStruct()))
    guard dimensions.cgSize != lastResolvedMeasurement.cgSize else { return false }
    lastResolvedMeasurement = dimensions
    return true
  }

  func layoutPriority() -> Int32 {
    cachedPriority
  }

  private func handleExternalRedrawRequest() {
    needsRender = true
    if isRendering {
      wakeDeferredByRender = true
      return
    }
    onRedrawRequested?()
  }

  func shutdown() {
    onRedrawRequested = nil
    inputCarrier?.invalidate()
    inputCarrier = nil
    detachIfNeeded()
    waterui_gpu_surface_drop(gpuState)
  }
}

/// High-performance GPU rendering surface using wgpu.
/// Presents IOSurface-backed frames, driven by a display link configured for
/// the display's maximum refresh rate.
@MainActor
final class WuiGpuSurface: PlatformView, WuiComponent, WuiFirstPaintReadyParticipant {
  static var rawId: CWaterUI.WuiTypeId { waterui_gpu_surface_id() }

  private(set) var stretchAxis: WuiStretchAxis = .both

  private let renderState: WuiGpuSurfaceRenderState

  /// The view whose layer shows the rendered frames.
  ///
  /// Frames arrive as an `IOSurface` pair on a plain layer's `contents` rather
  /// than through a `CAMetalLayer` swapchain: Core Animation composites them in
  /// place with no drawable pool and no `present`, a frame that did not change
  /// costs nothing, and — unlike a drawable — every capture path can read one
  /// (waterui#519).
  private let presentationLayer = CALayer()
  private var presenter: WuiSurfacePresenter!
  /// The format the presented surfaces carry, settled with the dynamic range.
  private var presentationPixelFormat: MTLPixelFormat = .invalid
  /// Whether a frame is between its render and its fence.
  private var framePresentationInFlight = false
  /// Whether a frame was asked for at a moment one could not be drawn.
  ///
  /// The renderer asks for its next frame exactly once, through the redraw
  /// callback, so a request that arrives while a presentation is in flight or
  /// while nothing can be seen has to be kept: dropping it stops a
  /// self-animating surface after a single frame.
  private var frameOwed = false

  #if canImport(AppKit)
    private var trackingArea: NSTrackingArea?
    private weak var observedWindow: NSWindow?
    private var windowObservers: [NSObjectProtocol] = []
  #endif

  #if canImport(UIKit)
    private var appObservers: [NSObjectProtocol] = []
  #endif

  private var isSurfaceAttached: Bool { renderState.isSurfaceAttached }
  private let externalRenderingScopes = WuiExternalRenderingScopes()
  /// The display-link driver, created on first use.
  ///
  /// Deliberately not `lazy`: the driver's callback holds a weak reference to
  /// this surface, and `deinit` stops the display link. A `lazy` property would
  /// *create* the driver at that point for a surface that never rendered — and
  /// forming a weak reference to an object already deallocating traps.
  private var frameDriverStorage: WuiDisplayLinkDriver?
  private var frameDriver: WuiDisplayLinkDriver {
    if let driver = frameDriverStorage {
      return driver
    }
    let driver = WuiDisplayLinkDriver { [weak self] in
      self?.renderFrame()
    }
    frameDriverStorage = driver
    return driver
  }
  /// The first responder installed for a GPU view that takes its own input.
  private var inputResponder: WuiGpuSurfaceInputResponder?
  private var captureSuppressionCount = 0
  private var keepRedrawing = false
  /// The label this surface itself last published, so an application label put
  /// on top of it is never overwritten by the next frame.
  private var publishedAccessibilityLabel: String?
  /// Whether the content has changed since the label was last asked for. Starts
  /// true so the first drawn frame publishes one.
  private var needsAccessibilityLabelRefresh = true
  private var redrawWakeScheduled = false
  private var readyCompletions: [WuiGpuSurfaceReadyCompletion] = []
  private var setupCompletions: [WuiGpuSurfaceSetupCompletion] = []

  /// Content scale factor for high-DPI displays
  private var currentScaleFactor: CGFloat = 1.0
  private var configuredDynamicRangeMode: WuiDynamicRangeMode?
  private let explicitDynamicRangePreference: WuiDynamicRangeMode?
  /// Renderer target range, decided at the first attach and stable afterwards.
  private var latchedRendererDynamicRangeMode: WuiDynamicRangeMode?

  /// Gesture tracking state
  private var gestureStartScale: CGFloat = 1.0
  private var cumulativeScale: CGFloat = 1.0
  private var gesturePanOffset: CGPoint = .zero

  // MARK: - WuiComponent Init

  convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
    let stretchAxis = WuiStretchAxis(waterui_view_stretch_axis(anyview))
    let ffiSurface = waterui_force_as_gpu_surface(anyview)
    self.init(
      stretchAxis: stretchAxis,
      ffiSurface: ffiSurface,
      env: env
    )
  }

  // MARK: - Designated Init

  init(
    stretchAxis: WuiStretchAxis,
    ffiSurface: CWaterUI.WuiGpuSurface,
    env: WuiEnvironment
  ) {
    self.stretchAxis = stretchAxis
    let renderState = WuiGpuSurfaceRenderState(ffiSurface: ffiSurface, envPtr: env.inner)
    let metalDevice = wuiMetalDevice(environment: env)
    self.renderState = renderState
    self.explicitDynamicRangePreference = renderState.explicitDynamicRangePreference

    super.init(frame: .zero)

    renderState.onRedrawRequested = { [weak self] in
      self?.handleRedrawRequest()
    }
    renderState.installRedrawCallback()
    setupPresentation(device: metalDevice)
    setupPointerTracking()
    setupLifecycleObservers()
    installInputResponderIfNeeded()
  }

  /// Gives an input-taking GPU view the first responder it needs.
  ///
  /// A view that only draws never gets one: no focus is claimed, no keystroke
  /// is intercepted, and the surrounding WaterUI widgets keep every event —
  /// which is why the responder is a separate view installed on demand rather
  /// than this surface conforming to the text-input protocols itself.
  private func installInputResponderIfNeeded() {
    guard renderState.wantsInputEvents else { return }
    let responder = WuiGpuSurfaceInputResponder(carrier: renderState.makeInputCarrier())
    responder.translatesAutoresizingMaskIntoConstraints = false
    addSubview(responder)
    NSLayoutConstraint.activate([
      responder.leadingAnchor.constraint(equalTo: leadingAnchor),
      responder.trailingAnchor.constraint(equalTo: trailingAnchor),
      responder.topAnchor.constraint(equalTo: topAnchor),
      responder.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
    inputResponder = responder
  }

  private func setupLifecycleObservers() {
    #if canImport(UIKit)
      let center = NotificationCenter.default
      appObservers.append(
        center.addObserver(
          forName: UIApplication.willResignActiveNotification,
          object: nil,
          queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated {
            self?.updateDisplayLinkState()
          }
        }
      )
      appObservers.append(
        center.addObserver(
          forName: UIApplication.didBecomeActiveNotification,
          object: nil,
          queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated {
            self?.updateDisplayLinkState()
          }
        }
      )
    #endif
  }

  // MARK: - Pointer Tracking Setup

  private func setupPointerTracking() {
    #if canImport(UIKit)
      // iOS/iPadOS: Add hover gesture for pointer tracking (iPadOS with trackpad/mouse)
      let hoverGesture = UIHoverGestureRecognizer(
        target: self, action: #selector(handleHover(_:)))
      addGestureRecognizer(hoverGesture)

      // Add pinch gesture for zoom
      let pinchGesture = UIPinchGestureRecognizer(
        target: self, action: #selector(handlePinch(_:)))
      addGestureRecognizer(pinchGesture)

      // Add pan gesture for chart panning
      let panGesture = UIPanGestureRecognizer(
        target: self, action: #selector(handlePan(_:)))
      panGesture.minimumNumberOfTouches = 2  // Require 2 fingers to avoid conflict with scroll
      panGesture.cancelsTouchesInView = false
      addGestureRecognizer(panGesture)

      // Add double-tap gesture for reset
      let doubleTapGesture = UITapGestureRecognizer(
        target: self, action: #selector(handleDoubleTap(_:)))
      doubleTapGesture.numberOfTapsRequired = 2
      addGestureRecognizer(doubleTapGesture)

      // Allow simultaneous gesture recognition
      pinchGesture.delegate = self
      panGesture.delegate = self
    #elseif canImport(AppKit)
      // macOS: Tracking area is updated in updateTrackingAreas()
      // Add magnification gesture for zoom
      let magnifyGesture = NSMagnificationGestureRecognizer(
        target: self, action: #selector(handleMagnification(_:)))
      addGestureRecognizer(magnifyGesture)

    // Add pan gesture for chart panning (scroll gesture)
    // Note: On macOS, we use scroll events instead of a separate pan gesture
    #endif
  }

  #if canImport(UIKit)
    @objc private func handleHover(_ gesture: UIHoverGestureRecognizer) {
      switch gesture.state {
      case .began, .changed:
        let location = gesture.location(in: self)
        renderState.updatePointerPosition(location, scaleFactor: currentScaleFactor)
        scheduleInputRender()
      case .ended, .cancelled:
        renderState.updatePointerPosition(nil, scaleFactor: currentScaleFactor)
        scheduleInputRender()
      default:
        break
      }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
      super.touchesBegan(touches, with: event)
      if let touch = touches.first {
        let location = touch.location(in: self)
        renderState.updatePointerPosition(location, scaleFactor: currentScaleFactor)
        renderState.updatePointerHit(location, scaleFactor: currentScaleFactor)
        scheduleInputRender()
      }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
      super.touchesMoved(touches, with: event)
      if let touch = touches.first {
        let location = touch.location(in: self)
        renderState.updatePointerPosition(location, scaleFactor: currentScaleFactor)
        scheduleInputRender()
      }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
      super.touchesEnded(touches, with: event)
      renderState.updatePointerHit(nil, scaleFactor: currentScaleFactor)
      scheduleInputRender()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
      super.touchesCancelled(touches, with: event)
      renderState.updatePointerHit(nil, scaleFactor: currentScaleFactor)
      scheduleInputRender()
    }

    // MARK: - Gesture Handlers (iOS)

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
      let center = gesture.location(in: self)

      switch gesture.state {
      case .began:
        gestureStartScale = cumulativeScale
        renderState.updatePinchGesture(
          active: true,
          scale: cumulativeScale,
          center: center,
          scaleFactor: currentScaleFactor
        )
      case .changed:
        let newScale = gestureStartScale * gesture.scale
        cumulativeScale = newScale
        renderState.updatePinchGesture(
          active: true,
          scale: cumulativeScale,
          center: center,
          scaleFactor: currentScaleFactor
        )
      case .ended, .cancelled:
        renderState.updatePinchGesture(
          active: false,
          scale: cumulativeScale,
          center: nil,
          scaleFactor: currentScaleFactor
        )
      default:
        break
      }
      scheduleInputRender()
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
      let translation = gesture.translation(in: self)

      switch gesture.state {
      case .began:
        gesturePanOffset = .zero
        renderState.updatePanGesture(
          active: true,
          offsetX: 0,
          offsetY: 0,
          scaleFactor: currentScaleFactor
        )
      case .changed:
        gesturePanOffset = CGPoint(x: translation.x, y: translation.y)
        renderState.updatePanGesture(
          active: true,
          offsetX: translation.x,
          offsetY: translation.y,
          scaleFactor: currentScaleFactor
        )
      case .ended, .cancelled:
        renderState.updatePanGesture(
          active: false,
          offsetX: translation.x,
          offsetY: translation.y,
          scaleFactor: currentScaleFactor
        )
        gesturePanOffset = .zero
      default:
        break
      }
      scheduleInputRender()
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
      if gesture.state == .recognized {
        // Reset zoom/pan state
        cumulativeScale = 1.0
        gesturePanOffset = .zero
        renderState.triggerDoubleTap()
        renderState.resetGestureState()
        scheduleInputRender()
      }
    }
  #elseif canImport(AppKit)
    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      // AppKit calls this whenever the geometry or window changes, and a
      // tracking area installed against the previous window keeps reporting
      // against it, so the old one is always removed first.
      if let trackingArea {
        removeTrackingArea(trackingArea)
        self.trackingArea = nil
      }
      guard window != nil else { return }
      // `.activeInKeyWindow` on purpose: pointer position feeds the renderer's
      // hover state, and a background window has no hover to show. Tracking it
      // there would wake the frame clock for a window the user is not using.
      // `.inVisibleRect` keeps the area in step with the view's visible bounds,
      // which makes the `rect` argument irrelevant.
      let options: NSTrackingArea.Options = [
        .mouseEnteredAndExited,
        .mouseMoved,
        .activeInKeyWindow,
        .inVisibleRect,
      ]
      let area = NSTrackingArea(
        rect: .zero,
        options: options,
        owner: self,
        userInfo: nil
      )
      trackingArea = area
      addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
      super.mouseEntered(with: event)
      let location = convert(event.locationInWindow, from: nil)
      renderState.updatePointerPosition(location, scaleFactor: currentScaleFactor)
      scheduleInputRender()
    }

    override func mouseMoved(with event: NSEvent) {
      super.mouseMoved(with: event)
      let location = convert(event.locationInWindow, from: nil)
      renderState.updatePointerPosition(location, scaleFactor: currentScaleFactor)
      scheduleInputRender()
    }

    override func mouseExited(with event: NSEvent) {
      super.mouseExited(with: event)
      renderState.updatePointerPosition(nil, scaleFactor: currentScaleFactor)
      scheduleInputRender()
    }

    override func mouseDragged(with event: NSEvent) {
      super.mouseDragged(with: event)
      let location = convert(event.locationInWindow, from: nil)
      renderState.updatePointerPosition(location, scaleFactor: currentScaleFactor)
      scheduleInputRender()
    }

    override func mouseUp(with event: NSEvent) {
      super.mouseUp(with: event)
      renderState.updatePointerHit(nil, scaleFactor: currentScaleFactor)
      scheduleInputRender()
    }

    override var acceptsFirstResponder: Bool { true }

    // MARK: - Gesture Handlers (macOS)

    @objc private func handleMagnification(_ gesture: NSMagnificationGestureRecognizer) {
      let center = convert(gesture.location(in: self), from: nil)

      switch gesture.state {
      case .began:
        gestureStartScale = cumulativeScale
        renderState.updatePinchGesture(
          active: true,
          scale: cumulativeScale,
          center: center,
          scaleFactor: currentScaleFactor
        )
      case .changed:
        let newScale = gestureStartScale * (1.0 + gesture.magnification)
        cumulativeScale = newScale
        renderState.updatePinchGesture(
          active: true,
          scale: cumulativeScale,
          center: center,
          scaleFactor: currentScaleFactor
        )
      case .ended, .cancelled:
        renderState.updatePinchGesture(
          active: false,
          scale: cumulativeScale,
          center: nil,
          scaleFactor: currentScaleFactor
        )
      default:
        break
      }
      scheduleInputRender()
    }

    override func scrollWheel(with event: NSEvent) {
      // When hosted inside NSScrollView, keep native scrolling as the default.
      // Hold Option to explicitly route wheel/trackpad delta to the GPU gesture channel.
      let hasScrollableAncestor = enclosingScrollView != nil
      let explicitSurfacePan = event.modifierFlags.contains(.option)
      if hasScrollableAncestor && !explicitSurfacePan {
        super.scrollWheel(with: event)
        return
      }

      // Handle scroll wheel for panning (with Option key or trackpad)
      // Note: deltaX/deltaY are in points
      let deltaX = event.scrollingDeltaX
      let deltaY = event.scrollingDeltaY

      // Check for scroll gesture phase
      switch event.phase {
      case .began:
        gesturePanOffset = .zero
        renderState.updatePanGesture(
          active: true,
          offsetX: deltaX,
          offsetY: deltaY,
          scaleFactor: currentScaleFactor
        )
      case .changed:
        gesturePanOffset = CGPoint(
          x: gesturePanOffset.x + deltaX,
          y: gesturePanOffset.y + deltaY
        )
        renderState.updatePanGesture(
          active: true,
          offsetX: gesturePanOffset.x,
          offsetY: gesturePanOffset.y,
          scaleFactor: currentScaleFactor
        )
      case .ended, .cancelled:
        renderState.updatePanGesture(
          active: false,
          offsetX: gesturePanOffset.x,
          offsetY: gesturePanOffset.y,
          scaleFactor: currentScaleFactor
        )
        gesturePanOffset = .zero
      default:
        // Handle scroll events without phases (e.g., mouse wheel)
        if event.phase == [] && event.momentumPhase == [] {
          // Immediate scroll event - treat as one-shot pan
          renderState.updatePanGesture(
            active: true,
            offsetX: deltaX,
            offsetY: deltaY,
            scaleFactor: currentScaleFactor
          )
          renderState.updatePanGesture(
            active: false,
            offsetX: deltaX,
            offsetY: deltaY,
            scaleFactor: currentScaleFactor
          )
        }
      }
      scheduleInputRender()
    }

    // Double-click to reset zoom/pan
    override func mouseDown(with event: NSEvent) {
      window?.makeFirstResponder(self)
      super.mouseDown(with: event)
      let location = convert(event.locationInWindow, from: nil)
      renderState.updatePointerPosition(location, scaleFactor: currentScaleFactor)
      renderState.updatePointerHit(location, scaleFactor: currentScaleFactor)
      scheduleInputRender()

      // Check for double-click
      if event.clickCount == 2 {
        cumulativeScale = 1.0
        gesturePanOffset = .zero
        renderState.triggerDoubleTap()
        renderState.resetGestureState()
        scheduleInputRender()
      }
    }
  #endif

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Metal Layer Setup

  private func setupPresentation(device: MTLDevice) {
    presentationLayer.isOpaque = false
    // The frames are rendered at device-pixel size, so the layer must not
    // rescale them; `contentsScale` is what tells Core Animation that.
    presentationLayer.contentsGravity = .resize
    #if canImport(UIKit)
      presentationLayer.backgroundColor = UIColor.clear.cgColor
      layer.addSublayer(presentationLayer)
    #elseif canImport(AppKit)
      presentationLayer.backgroundColor = NSColor.clear.cgColor
      // Layer-hosting, as this view was when it hosted a `CAMetalLayer`: it has
      // no subviews of its own, and an assigned layer is the one way to be sure
      // one exists before the first layout pass asks for it.
      let hostLayer = CALayer()
      hostLayer.backgroundColor = NSColor.clear.cgColor
      hostLayer.addSublayer(presentationLayer)
      layer = hostLayer
    #endif
    presenter = WuiSurfacePresenter(device: device, layer: presentationLayer)
  }

  /// Resolves the renderer's target dynamic range for a requested presentation.
  ///
  /// Automatic mode follows the display: an SDR panel negotiates an SDR surface
  /// format instead of paying for an FP16 target whose extended range it cannot
  /// show. An explicit preference always wins.
  ///
  /// The answer is latched on first use because wgpu keeps the format it
  /// negotiated for this renderer across detach/attach cycles — a later attach
  /// cannot change it, and pretending otherwise would leave the layer's declared
  /// format disagreeing with the surface's. Presentation range keeps tracking
  /// the display, so moving an HDR-capable surface between displays still
  /// switches EDR presentation on and off.
  private func rendererDynamicRange(
    presenting presentation: WuiDynamicRangeMode
  ) -> WuiDynamicRangeMode {
    if let latchedRendererDynamicRangeMode {
      return latchedRendererDynamicRangeMode
    }
    let mode = explicitDynamicRangePreference ?? presentation
    latchedRendererDynamicRangeMode = mode
    Logger.graphics.debug(
      "GpuSurface renderer target latched to \(mode == .high ? "HDR" : "SDR", privacy: .public)"
    )
    return mode
  }

  /// Settles the format the frames are rendered and composited in.
  private func configureDynamicRange(
    presentation: WuiDynamicRangeMode,
    renderer: WuiDynamicRangeMode
  ) {
    guard configuredDynamicRangeMode != presentation else { return }
    precondition(!isSurfaceAttached, "GpuSurface dynamic range cannot change while attached")
    precondition(
      presentation == .standard || renderer == .high,
      "An HDR presentation requires an HDR-capable renderer target"
    )
    applyDynamicRange(presentation, to: self)
    // The presented `IOSurface` carries both halves of what a `CAMetalLayer`
    // was told separately: its Metal format, and the colour space Core
    // Animation composites it in. A plain layer has no
    // `wantsExtendedDynamicRangeContent` to set — the extended-range colour
    // space on the surface is what asks for EDR.
    presentationPixelFormat = renderer == .high ? .rgba16Float : .bgra8Unorm_srgb
    presenter.release()
    configuredDynamicRangeMode = presentation
  }

  // MARK: - GPU Initialization

  private func initializeGpuIfNeeded() {
    guard bounds.width > 0 && bounds.height > 0 else { return }
    #if canImport(UIKit)
      guard window != nil else { return }
    #elseif canImport(AppKit)
      guard let window else { return }
    #endif

    let requestedRange = explicitDynamicRangePreference ?? requireInheritedDynamicRange(for: self)
    let rendererRange = rendererDynamicRange(presenting: requestedRange)
    // An SDR renderer target has no extended range to present, so a surface that
    // latched SDR stays SDR even once its window reaches an HDR display.
    let presentationRange: WuiDynamicRangeMode =
      rendererRange == .standard ? .standard : requestedRange
    if configuredDynamicRangeMode != presentationRange {
      if isSurfaceAttached {
        stopDisplayLink()
        renderState.detachIfNeeded()
      }
      configureDynamicRange(presentation: presentationRange, renderer: rendererRange)
    }

    #if canImport(UIKit)
      currentScaleFactor = contentScaleFactor
    #elseif canImport(AppKit)
      currentScaleFactor = window.backingScaleFactor
    #endif

    let width = UInt32(bounds.width * currentScaleFactor)
    let height = UInt32(bounds.height * currentScaleFactor)

    // The presented surfaces are allocated at this size by the next render,
    // so ask for that render promptly: until it arrives the layer shows the
    // previous frame scaled to the new bounds.
    let sizeChanged = renderState.updateSize(
      width: width, height: height, scale: currentScaleFactor)
    if sizeChanged {
      keepRedrawing = true
    }

    updatePresentationFrame()

    presenter.configure(
      width: Int(width), height: Int(height), pixelFormat: presentationPixelFormat)

    guard !isSurfaceAttached else { return }
    guard let first = presenter.nextFrame() else {
      fatalError("GpuSurface presenter has no texture to prepare the renderer with")
    }
    if renderState.attachIfNeeded(
      texturePtr: Unmanaged.passUnretained(first.texture).toOpaque(),
      width: width,
      height: height,
      scale: currentScaleFactor
    ) {
      Logger.graphics.debug(
        """
        GpuSurface attached: \(width, privacy: .public)x\(height, privacy: .public), \
        renderer=\(rendererRange == .high ? "HDR" : "SDR", privacy: .public), \
        presentation=\(presentationRange == .high ? "HDR" : "SDR", privacy: .public)
        """
      )
      renderInitialFrame()
    }
  }

  // MARK: - Display Link

  private func startDisplayLink() {
    frameDriver.start(for: self)
  }

  private func stopDisplayLink() {
    // Only a driver that exists can be running, and this runs from `deinit`.
    frameDriverStorage?.stop()
  }

  private func renderFrame(force: Bool = false) {
    if externalRenderingScopes.isActive {
      externalRenderingScopes.notifyRedraw()
      return
    }
    // One frame at a time: the surface it renders into is the one not being
    // shown, and starting a second before the first is presented would render
    // over the frame on screen. The request is owed, not dropped — a renderer
    // asks for its next frame exactly once, so swallowing one stops the
    // animation for good.
    guard !framePresentationInFlight else {
      frameOwed = true
      return
    }
    // A frame nobody can see is not worth drawing, and the occlusion machinery
    // exists to not draw it — but it is still owed, for the same reason. The
    // first frame is forced past this, because the window's reveal waits on it
    // and the window is not visible until it arrives.
    guard force || isEffectivelyVisible() else {
      frameOwed = true
      return
    }

    guard let pending = presenter.nextFrame(),
      let fence = renderState.renderIntoPresentedTexture(pending.texture, force: force)
    else {
      // Nothing was rendered: either there is nothing to draw, the surfaces are
      // not allocated yet, or asynchronous setup is still running. None of
      // those clear by spinning the display link — the renderer's redraw
      // callback wakes us when the situation changes — so let it stop.
      keepRedrawing = false
      updateDisplayLinkState()
      return
    }

    framePresentationInFlight = true
    // A renderer that wants another frame asks through the redraw callback,
    // which arms the clock itself; the presented frame does not carry the
    // answer back the way the swapchain's render call did.
    keepRedrawing = false
    publishContentAccessibilityLabel()
    updateDisplayLinkState()
    // Shown only once the GPU has finished writing it: a surface handed to
    // Core Animation mid-write composites a half-drawn frame.
    observeGpuCaptureFence(fence) { [weak self] in
      guard let self else { return }
      self.framePresentationInFlight = false
      self.presenter.present(pending)
      self.completeReady(true)
      self.updateDisplayLinkState()
    }
  }

  /// Names this surface's element with whatever its content says it draws.
  ///
  /// Rendered pixels are opaque to VoiceOver: a formula, chart or diagram drawn
  /// into a surface is announced as an unlabelled element unless the content
  /// states its own meaning. The content is what knows, so the answer comes
  /// from it rather than from anything the host could infer.
  ///
  /// Asked after a frame rather than once at creation, because the label is
  /// empty until asynchronous renderer setup finishes — and only when the
  /// content actually invalidated, because deriving the label can be real work
  /// (a formula runs its source through speech rules) and a display link that
  /// drives an animation must not pay it sixty times a second.
  ///
  /// An application label always wins. `WuiAccessibilityLabel` applies the
  /// app's own label to this very view, so anything on it that this surface did
  /// not put there belongs to someone else and is left alone.
  private func publishContentAccessibilityLabel() {
    guard needsAccessibilityLabelRefresh else { return }
    needsAccessibilityLabelRefresh = false

    #if canImport(UIKit)
      let existing = accessibilityLabel
    #elseif canImport(AppKit)
      let existing = accessibilityLabel()
    #endif
    // An empty label is no label: AppKit hands back `""` for a view nobody has
    // named, and the two mean the same thing to a reader.
    let current = (existing?.isEmpty == false) ? existing : nil
    guard current == nil || current == publishedAccessibilityLabel else { return }

    let content = renderState.accessibilityLabelFromContent
    let label = content.isEmpty ? nil : content
    guard label != publishedAccessibilityLabel else { return }
    publishedAccessibilityLabel = label

    #if canImport(UIKit)
      isAccessibilityElement = label != nil
      accessibilityLabel = label
    #elseif canImport(AppKit)
      setAccessibilityElement(label != nil)
      setAccessibilityLabel(label)
    #endif
  }

  /// Publishes input state and lets the display link drive the actual frame.
  ///
  /// Input events arrive faster than the display refreshes, and rendering
  /// inline would draw frames that are replaced before they are ever
  /// composited. The event handlers therefore only update
  /// `renderState` (which marks it as needing a render) and arm the frame
  /// clock, which coalesces a burst of events into one frame per refresh.
  private func scheduleInputRender() {
    if externalRenderingScopes.isActive {
      externalRenderingScopes.notifyRedraw()
      return
    }
    keepRedrawing = true
    updateDisplayLinkState()
  }

  private func renderInitialFrame() {
    renderFrame(force: true)
  }

  private func isEffectivelyVisible() -> Bool {
    #if canImport(UIKit)
      guard let window else { return false }
      guard hasVisibleAncestry() else { return false }
      guard window.screen != nil else { return false }
      return UIApplication.shared.applicationState == .active
    #elseif canImport(AppKit)
      guard let window else { return false }
      guard hasVisibleAncestry() else { return false }
      // A window that is on no display cannot present; the frame clock falls
      // back to the run loop for those, so gating here keeps an offscreen
      // window from rendering frames nobody sees.
      guard window.screen != nil else { return false }
      if window.isMiniaturized { return false }
      if isPresentationOccluded { return false }
      return true
    #else
      return true
    #endif
  }

  /// Reports whether this view and every ancestor is visible.
  ///
  /// A hidden or fully transparent ancestor hides this view just as effectively
  /// as its own flags do, and neither `isHidden` nor `alpha` is inherited.
  private func hasVisibleAncestry() -> Bool {
    var node: PlatformView? = self
    while let current = node {
      #if canImport(UIKit)
        if current.isHidden || current.alpha <= 0 { return false }
      #elseif canImport(AppKit)
        if current.isHidden || current.alphaValue <= 0 { return false }
      #endif
      node = current.superview
    }
    return true
  }

  private func updateDisplayLinkState() {
    syncDisplayLink()
    replayOwedFrame()
  }

  private func syncDisplayLink() {
    let shouldTick = keepRedrawing
    guard shouldTick else {
      stopDisplayLink()
      return
    }
    guard !externalRenderingScopes.isActive, isSurfaceAttached, isEffectivelyVisible() else {
      stopDisplayLink()
      return
    }
    startDisplayLink()
  }

  /// Draws the frame a redraw request asked for while one could not be drawn.
  ///
  /// Every reason a frame is deferred — a presentation in flight, an occluded
  /// or miniaturized window, a view out of its window — ends at a call to
  /// `updateDisplayLinkState`, so this is where the deferred frame is picked
  /// back up. It goes through the on-demand wake rather than rendering here,
  /// so that `renderFrame` never re-enters itself through its own call to
  /// `updateDisplayLinkState`.
  private func replayOwedFrame() {
    guard frameOwed, !framePresentationInFlight, !externalRenderingScopes.isActive else { return }
    guard isSurfaceAttached, isEffectivelyVisible() else { return }
    frameOwed = false
    scheduleOnDemandRender()
  }

  func beginExternalRendering(onRedraw: (() -> Void)? = nil) {
    if externalRenderingScopes.begin(onRedraw: onRedraw) {
      Logger.graphics.debug("GpuSurface entered external rendering; presentation suspended")
      renderState.setExternalRendering(true)
      keepRedrawing = false
      stopDisplayLink()
    }
  }

  func endExternalRendering(resumingPresentation: Bool) {
    if externalRenderingScopes.end() {
      Logger.graphics.debug(
        "GpuSurface left external rendering, resuming=\(resumingPresentation, privacy: .public)"
      )
      renderState.setExternalRendering(false)
      if resumingPresentation {
        scheduleOnDemandRender()
      }
    }
  }

  private func handleRedrawRequest() {
    completeSetupIfReady()
    // The content invalidated, which is the one moment its description can have
    // changed; the next drawn frame republishes it.
    needsAccessibilityLabelRefresh = true
    if renderState.takeMeasurementInvalidation() {
      // The whole ancestor chain, not just the parent: a stack that grew
      // re-lays its own children inside the box its parent gave it, so only a
      // root-to-leaf pass moves the siblings that follow this surface.
      invalidateLayoutHierarchy()
    }
    if externalRenderingScopes.isActive {
      externalRenderingScopes.notifyRedraw()
    } else {
      scheduleOnDemandRender()
    }
  }

  private func waitForSetup() async {
    if renderState.isSetupReady { return }
    await withCheckedContinuation { continuation in
      setupCompletions.append {
        continuation.resume()
      }
    }
  }

  private func completeSetupIfReady() {
    guard renderState.isSetupReady else { return }
    guard !setupCompletions.isEmpty else { return }
    Logger.graphics.debug(
      "GpuSurface setup complete, waiters=\(self.setupCompletions.count, privacy: .public)"
    )
    let completions = setupCompletions
    setupCompletions.removeAll()
    for completion in completions {
      completion()
    }
  }

  private func scheduleOnDemandRender() {
    guard !redrawWakeScheduled else { return }
    redrawWakeScheduled = true
    DispatchQueue.main.async { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.redrawWakeScheduled = false
        self.renderFrame()
      }
    }
  }

  private func setPresentationHidden(_ hidden: Bool) {
    guard presentationLayer.isHidden != hidden else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    presentationLayer.isHidden = hidden
    CATransaction.commit()
  }

  /// Positions the presentation view and tells Core Animation the frames are
  /// already at device-pixel size.
  private func updatePresentationFrame() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    presentationLayer.frame = bounds
    presentationLayer.contentsScale = currentScaleFactor
    CATransaction.commit()
  }

  func beginCaptureSuppression() {
    captureSuppressionCount += 1
    let shouldHide = captureSuppressionCount == 1
    if shouldHide {
      setPresentationHidden(true)
    }
  }

  func endCaptureSuppression() {
    precondition(
      captureSuppressionCount > 0, "GpuSurface capture suppression scopes are unbalanced")
    captureSuppressionCount -= 1
    let shouldShow = captureSuppressionCount == 0
    if shouldShow {
      setPresentationHidden(false)
    }
  }

  func prepareExternalRender(texture: MTLTexture) -> Bool {
    renderState.prepareMetalTexture(Unmanaged.passUnretained(texture).toOpaque())
  }

  /// Renders one frame into a caller-owned texture and reports GPU completion.
  ///
  /// `self` is captured weakly because marking this surface ready is only
  /// meaningful while it exists, but `completion` is invoked unconditionally:
  /// it is the caller's half of the fence handshake, and dropping it would
  /// strand the composition waiting on a frame that already finished.
  func renderPreparedExternalTexture(
    texture: MTLTexture,
    width: UInt32,
    height: UInt32,
    completion: @escaping @MainActor @Sendable () -> Void
  ) {
    let fence = renderState.renderPreparedMetalTexture(
      texturePtr: Unmanaged.passUnretained(texture).toOpaque(),
      width: width,
      height: height,
      scale: currentScaleFactor
    )
    observeGpuCaptureFence(fence) { [weak self] in
      self?.completeReady(true)
      completion()
    }
  }

  func renderExternalTexture(
    width: UInt32,
    height: UInt32
  ) async -> MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: capturePixelFormat,
      width: Int(width),
      height: Int(height),
      mipmapped: false
    )
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .shared
    guard let texture = captureDevice.makeTexture(descriptor: descriptor) else {
      fatalError("GpuSurface failed to create an external render texture")
    }

    _ = prepareExternalRender(texture: texture)
    await waitForSetup()
    await withCheckedContinuation { continuation in
      renderPreparedExternalTexture(
        texture: texture,
        width: width,
        height: height
      ) {
        continuation.resume()
      }
    }
    return texture
  }

  var captureDevice: MTLDevice {
    presenter.presentationDevice
  }

  /// The pixel format an external capture texture must use.
  ///
  /// The format is established when the dynamic range is configured, which
  /// happens on the way into the first attach; before that the layer still
  /// carries Core Animation's default and would hand out the wrong format.
  var capturePixelFormat: MTLPixelFormat {
    precondition(
      configuredDynamicRangeMode != nil,
      "GpuSurface must have a configured dynamic range before external capture"
    )
    return presentationPixelFormat
  }

  func prepareForReady() {
    #if canImport(UIKit)
      setNeedsLayout()
      layoutIfNeeded()
    #elseif canImport(AppKit)
      needsLayout = true
      layoutSubtreeIfNeeded()
    #endif
  }

  // MARK: - Async Ready

  /// Wait for GPU setup and first frame to complete.
  /// Call this before showing the window to prevent flicker.
  func waitForReady() async -> Bool {
    await withCheckedContinuation { continuation in
      requestReadyFrame { result in
        continuation.resume(returning: result)
      }
    }
  }

  private func requestReadyFrame(_ completion: @escaping WuiGpuSurfaceReadyCompletion) {
    // Whether a frame has been *presented*, not whether one has been
    // submitted: the two are a GPU frame apart, and this is what the window's
    // reveal waits on so it does not race the first frame onto the screen.
    if presenter.hasPresentedFrame {
      completion(true)
      return
    }
    readyCompletions.append(completion)
    prepareForReady()
    guard renderState.isSurfaceAttached else {
      completeReady(false)
      return
    }
    if renderState.isSetupReady {
      renderFrame(force: true)
    }
  }

  private func completeReady(_ result: Bool) {
    let completions = readyCompletions
    readyCompletions.removeAll()
    for completion in completions {
      completion(result)
    }
  }

  func participatesInFirstPaintReady() -> Bool {
    #if canImport(UIKit)
      guard window != nil else { return false }
      guard !isHidden, alpha > 0.01 else { return false }
      guard bounds.width > 0.5, bounds.height > 0.5 else { return false }
      return true
    #elseif canImport(AppKit)
      guard window != nil else { return false }
      guard !isHidden, alphaValue > 0.01 else { return false }
      guard bounds.width > 0.5, bounds.height > 0.5 else { return false }
      return true
    #else
      return true
    #endif
  }

  // MARK: - WuiComponent

  func layoutPriority() -> Int32 {
    renderState.layoutPriority()
  }

  func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
    measure(proposal).cgSize
  }

  func measure(_ proposal: WuiProposalSize) -> WuiViewDimensions {
    renderState.measure(proposal)
  }

  // MARK: - Layout

  #if canImport(UIKit)
    override func layoutSubviews() {
      super.layoutSubviews()
      updatePresentationLayerFrame()
      initializeGpuIfNeeded()
      updateDisplayLinkState()
    }

    override func didMoveToWindow() {
      super.didMoveToWindow()
      if window == nil {
        renderState.detachIfNeeded()
        completeReady(false)
        keepRedrawing = false
        stopDisplayLink()
        return
      }
      // Update scale factor when added to window
      currentScaleFactor = contentScaleFactor
      updatePresentationLayerFrame()
      initializeGpuIfNeeded()
      updateDisplayLinkState()
    }
  #elseif canImport(AppKit)
    override func layout() {
      super.layout()
      updatePresentationLayerFrame()
      initializeGpuIfNeeded()
      updateDisplayLinkState()
    }

    nonisolated override var isFlipped: Bool { true }

    override var wantsLayer: Bool {
      get { true }
      set {}
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard let window else {
        renderState.detachIfNeeded()
        completeReady(false)
        keepRedrawing = false
        stopDisplayLink()
        updateWindowObservers()
        return
      }
      // Update scale factor when added to window
      currentScaleFactor = window.backingScaleFactor
      updatePresentationLayerFrame()
      initializeGpuIfNeeded()
      updateWindowObservers()
      updateDisplayLinkState()
    }

    override func viewDidChangeBackingProperties() {
      super.viewDidChangeBackingProperties()
      guard let window else { return }
      currentScaleFactor = window.backingScaleFactor
      updatePresentationLayerFrame()
      initializeGpuIfNeeded()
      updateDisplayLinkState()
    }

    override func viewDidHide() {
      super.viewDidHide()
      updateDisplayLinkState()
    }

    override func viewDidUnhide() {
      super.viewDidUnhide()
      updateDisplayLinkState()
    }
  #endif

  private func updatePresentationLayerFrame() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)

    updatePresentationFrame()

    CATransaction.commit()
  }

  #if canImport(AppKit)
    private func updateWindowObservers() {
      if observedWindow === window { return }

      let center = NotificationCenter.default
      for token in windowObservers {
        center.removeObserver(token)
      }
      windowObservers.removeAll()
      observedWindow = window

      guard let window else { return }

      windowObservers.append(
        center.addObserver(
          forName: NSWindow.didChangeOcclusionStateNotification,
          object: window,
          queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated {
            self?.updateDisplayLinkState()
          }
        }
      )
      windowObservers.append(
        center.addObserver(
          forName: NSWindow.didMiniaturizeNotification,
          object: window,
          queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated {
            self?.updateDisplayLinkState()
          }
        }
      )
      windowObservers.append(
        center.addObserver(
          forName: NSWindow.didDeminiaturizeNotification,
          object: window,
          queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated {
            self?.updateDisplayLinkState()
          }
        }
      )
      windowObservers.append(
        center.addObserver(
          forName: NSWindow.didBecomeKeyNotification,
          object: window,
          queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated {
            self?.updateDisplayLinkState()
          }
        }
      )
      windowObservers.append(
        center.addObserver(
          forName: NSWindow.didResignKeyNotification,
          object: window,
          queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated {
            self?.updateDisplayLinkState()
          }
        }
      )
      // A window can move between displays, or off every display entirely. The
      // frame clock is locked to a specific display's refresh rate, so it has to
      // be rebuilt; re-running the visibility check does exactly that.
      windowObservers.append(
        center.addObserver(
          forName: NSWindow.didChangeScreenNotification,
          object: window,
          queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated {
            guard let self else { return }
            self.stopDisplayLink()
            self.initializeGpuIfNeeded()
            self.updateDisplayLinkState()
          }
        }
      )
    }
  #endif

  // MARK: - Cleanup

  @MainActor deinit {
    precondition(
      !externalRenderingScopes.isActive,
      "GpuSurface was deinitialized with active external rendering scopes"
    )
    precondition(
      captureSuppressionCount == 0,
      "GpuSurface was deinitialized with active capture suppression scopes"
    )
    stopDisplayLink()
    #if canImport(UIKit)
      let center = NotificationCenter.default
      for token in appObservers {
        center.removeObserver(token)
      }
      appObservers.removeAll()
    #elseif canImport(AppKit)
      let center = NotificationCenter.default
      for token in windowObservers {
        center.removeObserver(token)
      }
      windowObservers.removeAll()
    #endif
    renderState.shutdown()
  }
}

/// Creates WaterUI's native GPU host for a renderer-owned surface descriptor.
///
/// Optional backend products use this factory to compose GPU-backed primitives
/// without exposing the internal GPU surface component type.
@MainActor
public func makeWaterUIGpuSurface(
  stretchAxis: WuiStretchAxis,
  ffiSurface: CWaterUI.WuiGpuSurface,
  env: WuiEnvironment
) -> PlatformView {
  WuiGpuSurface(stretchAxis: stretchAxis, ffiSurface: ffiSurface, env: env)
}

// MARK: - UIGestureRecognizerDelegate

#if canImport(UIKit)
  extension WuiGpuSurface: UIGestureRecognizerDelegate {
    func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer,
      shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
      if gestureRecognizer.view is UIScrollView || otherGestureRecognizer.view is UIScrollView {
        return true
      }

      // Allow pinch and pan gestures to work together
      let isPinch =
        gestureRecognizer is UIPinchGestureRecognizer
        || otherGestureRecognizer is UIPinchGestureRecognizer
      let isPan =
        gestureRecognizer is UIPanGestureRecognizer
        || otherGestureRecognizer is UIPanGestureRecognizer

      return isPinch && isPan
    }
  }
#endif
#endif  // !WATERUI_NO_GPU
