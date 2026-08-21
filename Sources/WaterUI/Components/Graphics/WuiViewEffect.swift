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

private struct WuiViewEffectCaptureFrame: @unchecked Sendable {
  let texture: MTLTexture
  let width: UInt32
  let height: UInt32
}

private typealias WuiViewEffectReadyCompletion = @MainActor @Sendable (Bool) -> Void

@MainActor
private final class WuiViewEffectRenderState {
  private let effectState: OpaquePointer
  private(set) var isAttached = false
  var isReady: Bool { waterui_view_effect_is_ready(effectState) }

  init(ffiEffect: inout CWaterUI.WuiViewEffect, env: WuiEnvironment) {
    guard let effectState = waterui_view_effect_create(&ffiEffect, env.inner) else {
      fatalError("waterui_view_effect_create returned null")
    }
    self.effectState = effectState
  }

  func installRedrawCallback(onRedraw: @escaping @MainActor @Sendable () -> Void) {
    let callback = WuiRedrawCallbackBox(wake: onRedraw)
    waterui_view_effect_set_redraw_callback(
      effectState,
      Unmanaged.passRetained(callback).toOpaque(),
      wuiRedrawWakeCallback,
      wuiRedrawDropCallback
    )
  }

  func attachIfNeeded(
    outputLayer: CAMetalLayer,
    width: UInt32,
    height: UInt32,
    prefersHDR: Bool
  ) {
    guard !isAttached else { return }
    waterui_view_effect_attach(
      effectState,
      Unmanaged.passUnretained(outputLayer).toOpaque(),
      width,
      height,
      prefersHDR
    )
    isAttached = true
    Logger.graphics.debug(
      "ViewEffect attached: \(width, privacy: .public)x\(height, privacy: .public)"
    )
  }

  func detachIfNeeded() {
    guard isAttached else { return }
    waterui_view_effect_detach(effectState)
    isAttached = false
    Logger.graphics.debug("ViewEffect detached")
  }

  func setInput(frame: WuiViewEffectCaptureFrame) {
    precondition(isAttached, "ViewEffect render requires an attached presentation target")
    waterui_view_effect_set_input_metal_texture(
      effectState,
      Unmanaged.passUnretained(frame.texture).toOpaque(),
      frame.width,
      frame.height
    )
  }

  func renderPreparedInput() -> Bool {
    precondition(isReady, "ViewEffect render requires completed asynchronous setup")
    return waterui_view_effect_render(effectState)
  }

  func shutdown() {
    detachIfNeeded()
    waterui_view_effect_drop(effectState)
  }
}

@MainActor
final class WuiViewEffect: PlatformView, WuiComponent, WuiFirstPaintReadyParticipant,
  WuiRenderedContentInvalidationSink
{
  static var rawId: CWaterUI.WuiTypeId { waterui_view_effect_id() }

  private(set) var stretchAxis: WuiStretchAxis
  private let childView: WuiAnyView
  private let renderState: WuiViewEffectRenderState
  private let capturePipeline: WuiMetalViewCapture
  private let metalDevice: MTLDevice
  private var outputLayer: CAMetalLayer!
  private var captureTexture: MTLTexture?
  private var frameDriver: WuiDisplayLinkDriver!
  private var currentScaleFactor: CGFloat = 1
  private var configuredDynamicRangeMode: WuiDynamicRangeMode?
  private var needsRender = false
  private var renderInFlight = false
  private var detachAfterCapture = false
  private var pendingDynamicRangeMode: WuiDynamicRangeMode?
  private var pendingSetupFrame: WuiViewEffectCaptureFrame?
  private var outputRevealed = false
  private var readyCompletions: [WuiViewEffectReadyCompletion] = []

  convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
    let stretchAxis = WuiStretchAxis(waterui_view_stretch_axis(anyview))
    let effect = waterui_force_as_view_effect(anyview)
    self.init(stretchAxis: stretchAxis, ffiEffect: effect, env: env)
  }

  init(stretchAxis: WuiStretchAxis, ffiEffect: CWaterUI.WuiViewEffect, env: WuiEnvironment) {
    var effect = ffiEffect
    guard let content = effect.content else {
      fatalError("ViewEffect requires a child view")
    }
    let metalDevice = wuiMetalDevice(environment: env)
    let childView = WuiAnyView(anyview: content, env: env)
    self.stretchAxis = stretchAxis
    self.childView = childView
    self.renderState = WuiViewEffectRenderState(ffiEffect: &effect, env: env)
    self.capturePipeline = WuiMetalViewCapture(contentView: childView)
    self.metalDevice = metalDevice

    super.init(frame: .zero)

    self.frameDriver = WuiDisplayLinkDriver { [weak self] in
      self?.renderFrame()
    }

    #if canImport(AppKit)
      wantsLayer = true
    #endif
    setupOutputLayer()
    setupChildView()
    capturePipeline.onRedraw = { [weak self] in
      self?.requestRenderIfNeeded()
    }
    renderState.installRedrawCallback { [weak self] in
      self?.handleRendererRedraw()
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupOutputLayer() {
    // Only properties wgpu does not own belong here: configuring the surface
    // overwrites `pixelFormat`, `colorspace`, `framebufferOnly`, `drawableSize`,
    // `maximumDrawableCount`, and `wantsExtendedDynamicRangeContent`.
    let outputLayer = CAMetalLayer()
    outputLayer.device = metalDevice
    outputLayer.isOpaque = false
    outputLayer.isHidden = true
    #if canImport(UIKit)
      outputLayer.backgroundColor = UIColor.clear.cgColor
      layer.addSublayer(outputLayer)
    #elseif canImport(AppKit)
      outputLayer.backgroundColor = NSColor.clear.cgColor
      guard let layer else {
        fatalError("ViewEffect host view must be layer-backed")
      }
      layer.backgroundColor = NSColor.clear.cgColor
      layer.addSublayer(outputLayer)
    #endif
    self.outputLayer = outputLayer
  }

  private func setupChildView() {
    #if canImport(UIKit)
      insertSubview(childView, at: 0)
      childView.layer.isHidden = true
    #elseif canImport(AppKit)
      addSubview(childView, positioned: .below, relativeTo: nil)
      childView.wantsLayer = true
      guard let layer = childView.layer else {
        fatalError("ViewEffect child view must be layer-backed")
      }
      layer.isHidden = true
    #endif
  }

  private func configureDynamicRange(_ mode: WuiDynamicRangeMode) {
    precondition(!renderState.isAttached, "ViewEffect dynamic range cannot change while attached")
    applyDynamicRange(mode, to: self)
    configureMetalLayerDynamicRange(
      outputLayer,
      presentationMode: mode,
      rendererMode: .high
    )
    captureTexture = nil
    pendingSetupFrame = nil
    hideOutput()
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
    guard bounds.width > 0, bounds.height > 0 else { return }
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
    _ = ensureCaptureTexture(width: width, height: height)
    updateOutputLayerFrame()
    renderState.attachIfNeeded(
      outputLayer: outputLayer,
      width: width,
      height: height,
      prefersHDR: true
    )
  }

  private func ensureCaptureTexture(width: UInt32, height: UInt32) -> MTLTexture {
    if let captureTexture,
      captureTexture.width == Int(width),
      captureTexture.height == Int(height),
      captureTexture.pixelFormat == outputLayer.pixelFormat
    {
      return captureTexture
    }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: outputLayer.pixelFormat,
      width: Int(width),
      height: Int(height),
      mipmapped: false
    )
    descriptor.usage = [.shaderRead, .renderTarget]
    descriptor.storageMode = .private
    guard let texture = metalDevice.makeTexture(descriptor: descriptor) else {
      fatalError("Failed to create the ViewEffect capture texture")
    }
    captureTexture = texture
    return texture
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
      renderState.isAttached, window != nil, needsRender, !renderInFlight,
      pendingSetupFrame == nil
    else {
      stopDisplayLink()
      return
    }
    startDisplayLink()
  }

  private func renderFrame() {
    guard needsRender, !renderInFlight, pendingSetupFrame == nil else {
      scheduleFrameIfNeeded()
      return
    }
    let width = UInt32(bounds.width * currentScaleFactor)
    let height = UInt32(bounds.height * currentScaleFactor)
    guard width > 0, height > 0 else { return }
    needsRender = false
    renderInFlight = true
    stopDisplayLink()
    let frame = WuiViewEffectCaptureFrame(
      texture: ensureCaptureTexture(width: width, height: height),
      width: width,
      height: height
    )

    // Weak: a capture that lands after this view is gone has nothing to finish,
    // and the capture pipeline it runs on is owned by this view anyway.
    capturePipeline.capture(into: frame.texture) { [weak self] captured in
      self?.finishCapturedFrame(frame, captured: captured)
    }
  }

  private func finishCapturedFrame(_ frame: WuiViewEffectCaptureFrame, captured: Bool) {
    renderInFlight = false
    if detachAfterCapture {
      detachAfterCapture = false
      renderState.detachIfNeeded()
      completeReady(false)
      return
    }
    if pendingDynamicRangeMode != nil {
      self.pendingDynamicRangeMode = nil
      renderState.detachIfNeeded()
      initializeGpuIfNeeded()
      requestRenderIfNeeded()
      return
    }
    guard captured else {
      scheduleFrameIfNeeded()
      return
    }
    renderState.setInput(frame: frame)
    guard renderState.isReady else {
      pendingSetupFrame = frame
      return
    }
    finishPreparedFrame()
  }

  private func finishPreparedFrame() {
    let needsAnotherFrame = renderState.renderPreparedInput()
    revealOutput()
    invalidateCapturedRendering()
    needsRender = needsRender || needsAnotherFrame
    completeReady(true)
    scheduleFrameIfNeeded()
  }

  private func handleRendererRedraw() {
    if renderState.isReady, pendingSetupFrame != nil {
      pendingSetupFrame = nil
      finishPreparedFrame()
    } else {
      requestRenderIfNeeded()
    }
  }

  private func requestReadyFrame(_ completion: @escaping WuiViewEffectReadyCompletion) {
    if outputRevealed {
      completion(true)
      return
    }
    readyCompletions.append(completion)
    prepareForReady()
    guard renderState.isAttached else {
      completeReady(false)
      return
    }
    renderFrame()
  }

  private func completeReady(_ result: Bool) {
    let completions = readyCompletions
    readyCompletions.removeAll()
    for completion in completions {
      completion(result)
    }
  }

  private func revealOutput() {
    guard !outputRevealed else { return }
    outputRevealed = true
    Logger.graphics.debug("ViewEffect first filtered frame presented")
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    outputLayer.isHidden = false
    CATransaction.commit()
  }

  private func hideOutput() {
    outputRevealed = false
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

  func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
    childView.sizeThatFits(proposal)
  }

  #if canImport(UIKit)
    override func layoutSubviews() {
      super.layoutSubviews()
      childView.frame = bounds
      childView.setNeedsLayout()
      childView.layoutIfNeeded()
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
      childView.frame = bounds
      childView.needsLayout = true
      childView.layoutSubtreeIfNeeded()
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
      stopDisplayLink()
      pendingSetupFrame = nil
      pendingDynamicRangeMode = nil
      completeReady(false)
      if renderInFlight {
        detachAfterCapture = true
      } else {
        renderState.detachIfNeeded()
      }
      return
    }
    detachAfterCapture = false
    initializeGpuIfNeeded()
    requestRenderIfNeeded()
  }

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
