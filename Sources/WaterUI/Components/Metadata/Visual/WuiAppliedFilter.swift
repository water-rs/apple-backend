// Compiled out when the app disables WaterUI's `gpu` feature: the
// `waterui_*` GPU symbols this file binds do not exist in that build.
#if !WATERUI_NO_GPU
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

private struct WuiAppliedFilterCaptureFrame: @unchecked Sendable {
  let texture: MTLTexture
  let width: UInt32
  let height: UInt32
}

private typealias WuiAppliedFilterReadyCompletion = @MainActor @Sendable (Bool) -> Void

@MainActor
private final class WuiAppliedFilterRenderState {
  private let filterState: OpaquePointer
  private var width: UInt32 = 0
  private var height: UInt32 = 0
  private(set) var isAttached = false
  var isReady: Bool { waterui_applied_filter_is_ready(filterState) }

  init(ffiFilter: inout CWaterUI.WuiAppliedFilter, env: WuiEnvironment) {
    guard let filterState = waterui_applied_filter_create(&ffiFilter, env.inner) else {
      fatalError("waterui_applied_filter_create returned null")
    }
    self.filterState = filterState
  }

  func installRedrawCallback(onRedraw: @escaping @MainActor @Sendable () -> Void) {
    let callback = WuiRedrawCallbackBox(wake: onRedraw)
    waterui_applied_filter_set_redraw_callback(
      filterState,
      Unmanaged.passRetained(callback).toOpaque(),
      wuiRedrawWakeCallback,
      wuiRedrawDropCallback
    )
  }

  func updateSize(width: UInt32, height: UInt32) {
    self.width = width
    self.height = height
  }

  func attachIfNeeded(
    outputLayer: CAMetalLayer,
    width: UInt32,
    height: UInt32,
    prefersHDR: Bool
  ) {
    updateSize(width: width, height: height)
    guard !isAttached else { return }
    waterui_applied_filter_attach(
      filterState,
      Unmanaged.passUnretained(outputLayer).toOpaque(),
      width,
      height,
      prefersHDR
    )
    waterui_applied_filter_setup(filterState)
    isAttached = true
    Logger.graphics.debug(
      "AppliedFilter attached: \(width, privacy: .public)x\(height, privacy: .public)"
    )
  }

  func detachIfNeeded() {
    guard isAttached else { return }
    waterui_applied_filter_detach(filterState)
    isAttached = false
    Logger.graphics.debug("AppliedFilter detached")
  }

  /// Prepares the capture texture for one frame.
  ///
  /// Resolving the output size is what tells the filter state how large its
  /// presentation surface must be; `prepare_capture` then reconfigures the
  /// output surface (and with it the layer's drawable size) from that answer,
  /// so the resolved size stays entirely on the Rust side.
  func prepareCapture() -> WuiAppliedFilterCaptureFrame? {
    guard isAttached, width > 0, height > 0 else { return nil }
    precondition(isReady, "AppliedFilter capture requires completed asynchronous setup")
    waterui_applied_filter_resolve_output_size(filterState, width, height)
    waterui_applied_filter_prepare_capture(filterState, width, height)
    guard let rawTexture = waterui_applied_filter_get_capture_metal_texture(filterState) else {
      fatalError("AppliedFilter capture texture is unavailable")
    }
    let object = Unmanaged<AnyObject>.fromOpaque(rawTexture).takeUnretainedValue()
    guard let texture = object as? MTLTexture else {
      fatalError("AppliedFilter capture texture is not an MTLTexture")
    }
    return WuiAppliedFilterCaptureFrame(texture: texture, width: width, height: height)
  }

  func renderCapturedFrame(_ frame: WuiAppliedFilterCaptureFrame) -> Bool {
    precondition(isReady, "AppliedFilter render requires completed asynchronous setup")
    return waterui_applied_filter_render(filterState, frame.width, frame.height)
  }

  func shutdown() {
    detachIfNeeded()
    waterui_applied_filter_drop(filterState)
  }
}

@MainActor
final class WuiAppliedFilter: PlatformView, WuiComponent, WuiFirstPaintReadyParticipant,
  WuiRenderedContentInvalidationSink
{
  static var rawId: CWaterUI.WuiTypeId { waterui_metadata_applied_filter_id() }

  private let contentView: any WuiComponent
  private let renderState: WuiAppliedFilterRenderState
  private let capturePipeline: WuiMetalViewCapture
  private var outputLayer: CAMetalLayer!
  private var frameDriver: WuiDisplayLinkDriver!
  private var currentScaleFactor: CGFloat = 1
  private var configuredDynamicRangeMode: WuiDynamicRangeMode?
  private var needsRender = false
  private var renderInFlight = false
  private var detachAfterCapture = false
  private var pendingDynamicRangeMode: WuiDynamicRangeMode?
  private var filteredOutputRevealed = false
  private var readyCompletions: [WuiAppliedFilterReadyCompletion] = []

  var stretchAxis: WuiStretchAxis { contentView.stretchAxis }

  required init(anyview: OpaquePointer, env: WuiEnvironment) {
    var metadata = waterui_force_as_metadata_applied_filter(anyview)
    guard let content = metadata.content else {
      fatalError("AppliedFilter requires a child view")
    }
    let contentView = WuiAnyView.resolve(anyview: content, env: env)
    let metalDevice = wuiMetalDevice(environment: env)
    self.contentView = contentView
    self.renderState = WuiAppliedFilterRenderState(ffiFilter: &metadata, env: env)
    self.capturePipeline = WuiMetalViewCapture(contentView: contentView)

    super.init(frame: .zero)

    self.frameDriver = WuiDisplayLinkDriver { [weak self] in
      self?.renderFrame()
    }

    #if canImport(AppKit)
      wantsLayer = true
    #endif
    setupOutputLayer(device: metalDevice)
    setupContentView()
    capturePipeline.onRedraw = { [weak self] in
      self?.requestRenderIfNeeded()
    }
    renderState.installRedrawCallback { [weak self] in
      self?.requestRenderIfNeeded()
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupOutputLayer(device: MTLDevice) {
    // Only properties wgpu does not own belong here: configuring the surface
    // overwrites `pixelFormat`, `colorspace`, `framebufferOnly`, `drawableSize`,
    // `maximumDrawableCount`, and `wantsExtendedDynamicRangeContent`.
    let outputLayer = CAMetalLayer()
    outputLayer.device = device
    outputLayer.isOpaque = false
    outputLayer.isHidden = true
    #if canImport(UIKit)
      outputLayer.backgroundColor = UIColor.clear.cgColor
      layer.addSublayer(outputLayer)
    #elseif canImport(AppKit)
      outputLayer.backgroundColor = NSColor.clear.cgColor
      guard let layer else {
        fatalError("AppliedFilter host view must be layer-backed")
      }
      layer.backgroundColor = NSColor.clear.cgColor
      layer.addSublayer(outputLayer)
    #endif
    self.outputLayer = outputLayer
  }

  private func setupContentView() {
    contentView.translatesAutoresizingMaskIntoConstraints = true
    addSubview(contentView)
    setCaptureContentLayerHidden(true)
    outputLayer.zPosition = 1
  }

  private func setCaptureContentLayerHidden(_ hidden: Bool) {
    #if canImport(UIKit)
      let layer = contentView.layer
    #elseif canImport(AppKit)
      contentView.wantsLayer = true
      guard let layer = contentView.layer else {
        fatalError("AppliedFilter child view must be layer-backed")
      }
    #endif
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.isHidden = hidden
    CATransaction.commit()
  }

  private func configureDynamicRange(_ mode: WuiDynamicRangeMode) {
    precondition(
      !renderState.isAttached, "AppliedFilter dynamic range cannot change while attached")
    applyDynamicRange(mode, to: self)
    configureMetalLayerDynamicRange(
      outputLayer,
      presentationMode: mode,
      rendererMode: .high
    )
    hideFilteredOutput()
    configuredDynamicRangeMode = mode
  }

  private func prepareDynamicRange(_ mode: WuiDynamicRangeMode) -> Bool {
    guard configuredDynamicRangeMode != mode else {
      pendingDynamicRangeMode = nil
      return true
    }
    guard !renderInFlight else {
      pendingDynamicRangeMode = mode
      return false
    }
    renderState.detachIfNeeded()
    configureDynamicRange(mode)
    return true
  }

  private func initializeGpuIfNeeded() {
    guard bounds.width > 0, bounds.height > 0 else {
      releasePresentation()
      return
    }
    #if canImport(UIKit)
      guard window != nil else { return }
    #elseif canImport(AppKit)
      guard let window else { return }
    #endif
    let dynamicRange = requireInheritedDynamicRange(for: self)
    guard prepareDynamicRange(dynamicRange) else { return }

    #if canImport(UIKit)
      currentScaleFactor = contentScaleFactor
    #elseif canImport(AppKit)
      currentScaleFactor = window.backingScaleFactor
    #endif

    let width = UInt32(bounds.width * currentScaleFactor)
    let height = UInt32(bounds.height * currentScaleFactor)
    renderState.updateSize(width: width, height: height)
    updateOutputLayerFrame()
    renderState.attachIfNeeded(
      outputLayer: outputLayer,
      width: width,
      height: height,
      prefersHDR: true
    )
  }

  private func startDisplayLink() {
    frameDriver.start(for: self)
  }

  private func stopDisplayLink() {
    frameDriver.stop()
  }

  private func requestRenderIfNeeded() {
    needsRender = true
    scheduleFrameIfNeeded()
  }

  func renderedContentDidInvalidate() {
    requestRenderIfNeeded()
    invalidateCapturedRendering()
  }

  /// Arms the frame clock when there is work for it.
  ///
  /// Only the window is required, not a display: `WuiDisplayLinkDriver` drives
  /// a window that is on no display — the preview renderer's offscreen capture
  /// window, or a window between displays — from the main run loop instead of a
  /// display link, so gating on `window.screen` here would strand those
  /// captures waiting for a frame that never comes.
  private func scheduleFrameIfNeeded() {
    guard
      renderState.isAttached, renderState.isReady, window != nil, needsRender, !renderInFlight
    else {
      stopDisplayLink()
      return
    }
    startDisplayLink()
  }

  private func renderFrame() {
    guard renderState.isReady, needsRender, !renderInFlight else {
      scheduleFrameIfNeeded()
      return
    }
    needsRender = false
    guard let frame = renderState.prepareCapture() else {
      return
    }
    renderInFlight = true
    stopDisplayLink()

    // Weak: a capture that lands after this view is gone has nothing to finish,
    // and the capture pipeline it runs on is owned by this view anyway.
    capturePipeline.capture(into: frame.texture) { [weak self] captured in
      self?.finishCapturedFrame(frame, captured: captured)
    }
  }

  private func finishCapturedFrame(_ frame: WuiAppliedFilterCaptureFrame, captured: Bool) {
    renderInFlight = false
    if detachAfterCapture {
      detachAfterCapture = false
      renderState.detachIfNeeded()
      completeReady(false)
      return
    }
    if pendingDynamicRangeMode != nil {
      pendingDynamicRangeMode = nil
      renderState.detachIfNeeded()
      initializeGpuIfNeeded()
      requestRenderIfNeeded()
      return
    }
    guard captured else {
      scheduleFrameIfNeeded()
      return
    }
    let needsAnotherFrame = renderState.renderCapturedFrame(frame)
    revealFilteredOutput()
    invalidateCapturedRendering()
    needsRender = needsRender || needsAnotherFrame
    completeReady(true)
    scheduleFrameIfNeeded()
  }

  private func requestReadyFrame(_ completion: @escaping WuiAppliedFilterReadyCompletion) {
    if filteredOutputRevealed {
      completion(true)
      return
    }
    readyCompletions.append(completion)
    prepareForReady()
    guard renderState.isAttached else {
      completeReady(false)
      return
    }
    scheduleFrameIfNeeded()
  }

  private func completeReady(_ result: Bool) {
    let completions = readyCompletions
    readyCompletions.removeAll()
    for completion in completions {
      completion(result)
    }
  }

  private func revealFilteredOutput() {
    guard !filteredOutputRevealed else { return }
    filteredOutputRevealed = true
    Logger.graphics.debug("AppliedFilter first filtered frame presented")
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    outputLayer.isHidden = false
    CATransaction.commit()
  }

  private func hideFilteredOutput() {
    filteredOutputRevealed = false
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    outputLayer.isHidden = true
    CATransaction.commit()
  }

  func prepareForReady() {
    #if canImport(UIKit)
      setNeedsLayout()
      layoutIfNeeded()
    #elseif canImport(AppKit)
      needsLayout = true
      layoutSubtreeIfNeeded()
    #endif
    initializeGpuIfNeeded()
    requestRenderIfNeeded()
  }

  func waitForReady() async -> Bool {
    await withCheckedContinuation { continuation in
      requestReadyFrame { result in
        continuation.resume(returning: result)
      }
    }
  }

  func participatesInFirstPaintReady() -> Bool {
    #if canImport(UIKit)
      window != nil && !isHidden && alpha > 0.01 && bounds.width > 0.5 && bounds.height > 0.5
    #elseif canImport(AppKit)
      window != nil && !isHidden && alphaValue > 0.01 && bounds.width > 0.5 && bounds.height > 0.5
    #endif
  }

  func layoutPriority() -> Int32 { contentView.layoutPriority() }

  func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
    contentView.sizeThatFits(proposal)
  }

  #if canImport(UIKit)
    override func layoutSubviews() {
      super.layoutSubviews()
      contentView.frame = bounds
      contentView.setNeedsLayout()
      contentView.layoutIfNeeded()
      updateOutputLayerFrame()
      initializeGpuIfNeeded()
      requestRenderIfNeeded()
    }

    override func didMoveToWindow() {
      super.didMoveToWindow()
      handleWindowChange()
    }
  #elseif canImport(AppKit)
    nonisolated override var isFlipped: Bool { true }

    override func layout() {
      super.layout()
      contentView.frame = bounds
      contentView.needsLayout = true
      contentView.layoutSubtreeIfNeeded()
      updateOutputLayerFrame()
      initializeGpuIfNeeded()
      requestRenderIfNeeded()
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      handleWindowChange()
    }

    override func viewDidChangeBackingProperties() {
      super.viewDidChangeBackingProperties()
      guard window != nil else { return }
      initializeGpuIfNeeded()
      requestRenderIfNeeded()
    }
  #endif

  private func handleWindowChange() {
    if window == nil {
      releasePresentation()
      return
    }
    detachAfterCapture = false
    initializeGpuIfNeeded()
    requestRenderIfNeeded()
  }

  /// Drops the attached output once the view can no longer present: it left
  /// the window, or layout gave it zero bounds. The capture pipeline requires
  /// non-zero content bounds, and a filter whose content measures empty (a
  /// photo that has not decoded yet) is laid out at zero after being attached
  /// at the size its host first offered, so an attached output over an empty
  /// layout would capture nothing and trap. A capture in flight finishes and
  /// detaches on completion; a later layout to a real size attaches again
  /// through `initializeGpuIfNeeded`.
  private func releasePresentation() {
    stopDisplayLink()
    needsRender = false
    pendingDynamicRangeMode = nil
    completeReady(false)
    if renderInFlight {
      detachAfterCapture = true
    } else {
      renderState.detachIfNeeded()
    }
  }

  /// Positions the presentation layer. Its drawable size belongs to wgpu, which
  /// sets it from the filter's resolved output size on every reconfiguration.
  private func updateOutputLayerFrame() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    outputLayer.frame = bounds
    outputLayer.contentsScale = currentScaleFactor
    CATransaction.commit()
  }

  @MainActor deinit {
    stopDisplayLink()
    capturePipeline.shutdown()
    renderState.shutdown()
  }
}
#endif  // !WATERUI_NO_GPU
