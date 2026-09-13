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
    width: UInt32,
    height: UInt32,
    prefersHDR: Bool
  ) {
    guard !isAttached else { return }
    waterui_view_effect_attach_host_textures(effectState, width, height, prefersHDR)
    isAttached = true
    Logger.graphics.debug(
      "ViewEffect attached: \(width, privacy: .public)x\(height, privacy: .public)"
    )
  }

  /// The Metal format the attached effect renders its output in.
  ///
  /// The host creates its `IOSurface` pair and its capture texture in this
  /// format: the effect decided it at attach from the dynamic-range preference,
  /// and a surface in any other format would be a silent mismatch between what
  /// wgpu writes and what Core Animation samples.
  var outputPixelFormat: MTLPixelFormat {
    let raw = UInt(waterui_view_effect_output_metal_pixel_format(effectState))
    guard let format = MTLPixelFormat(rawValue: raw) else {
      fatalError("ViewEffect reported an output format Metal does not know")
    }
    return format
  }

  /// The output size this effect resolves an input size to.
  ///
  /// The host allocates the textures it presents from, so unlike the swapchain
  /// path the size cannot stay entirely on the Rust side.
  func resolveOutputSize(width: UInt32, height: UInt32) -> WuiViewEffectOutputSize {
    waterui_view_effect_resolve_output_size(effectState, width, height)
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

  /// Runs the effect over the prepared input, into a host-owned texture.
  ///
  /// The fence is that frame's: the texture is only safe to show once it
  /// completes, so it is handed back rather than consumed here.
  func renderPreparedInput(
    into texture: MTLTexture,
    width: UInt32,
    height: UInt32
  ) -> (fence: OpaquePointer, needsRedraw: Bool) {
    precondition(isReady, "ViewEffect render requires completed asynchronous setup")
    var needsRedraw = false
    guard
      let fence = waterui_view_effect_render_to_metal_texture(
        effectState,
        Unmanaged.passUnretained(texture).toOpaque(),
        width,
        height,
        &needsRedraw
      )
    else {
      fatalError("waterui_view_effect_render_to_metal_texture returned no fence")
    }
    return (fence, needsRedraw)
  }

  func shutdown() {
    detachIfNeeded()
    waterui_view_effect_drop(effectState)
  }
}

@MainActor
final class WuiViewEffect: PlatformView, WuiComponent, WuiPresentsOwnContent, WuiFirstPaintReadyParticipant,
  WuiRenderedContentInvalidationSink
{
  static var rawId: CWaterUI.WuiTypeId { waterui_view_effect_id() }

  private(set) var stretchAxis: WuiStretchAxis
  private let childView: WuiAnyView
  private let renderState: WuiViewEffectRenderState
  private let capturePipeline: WuiMetalViewCapture
  private let metalDevice: MTLDevice
  private var outputView: PlatformView!
  private var outputLayer: CALayer!
  private var presenter: WuiSurfacePresenter!
  private var captureTexture: MTLTexture?
  private var framePresentationInFlight = false
  private var frameDriver: WuiDisplayLinkDriver!
  #if canImport(AppKit)
    private var occlusionObserver: WuiWindowOcclusionObserver!
  #endif
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
      occlusionObserver = WuiWindowOcclusionObserver { [weak self] in
        guard let self else { return }
        // Attaching waits for a window that can present, so an uncovered window
        // is where the deferred attach happens as well as the deferred frame.
        self.initializeGpuIfNeeded()
        self.scheduleFrameIfNeeded()
      }
    #endif
    setupChildView()
    setupOutputView(device: metalDevice)
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

  /// Builds the view the effect's frames are shown on.
  ///
  /// A plain `CALayer`, not the `CAMetalLayer` this used to present through:
  /// the frames arrive as `IOSurface` contents, which Core Animation composites
  /// in place and — unlike a Metal drawable, readable only by the pipeline that
  /// presented it — every capture path can read. A `ViewEffect`'s output was
  /// invisible to the preview snapshot, to `WuiViewRenderer` and to an
  /// enclosing filter, and was composited under the content it draws over
  /// (#579).
  ///
  /// It is the backing layer of a *view* of its own rather than a bare sublayer
  /// of this host, because `cacheDisplay(in:to:)` draws a view's whole layer
  /// tree before any of its subviews: a bare sublayer lands underneath the
  /// content no matter its `zPosition`, which Core Animation honours and the
  /// snapshot ignores. As the last subview it is drawn last in both.
  private func setupOutputView(device: MTLDevice) {
    let outputView = WuiSurfacePresentationView(frame: .zero)
    #if canImport(UIKit)
      let outputLayer = outputView.layer
    #elseif canImport(AppKit)
      outputView.wantsLayer = true
      guard let outputLayer = outputView.layer else {
        fatalError("ViewEffect output view must be layer-backed")
      }
    #endif
    outputView.isHidden = true
    outputLayer.isOpaque = false
    // The frames are rendered at device-pixel size, so the layer must not
    // rescale them; `contentsScale` is what tells Core Animation that.
    outputLayer.contentsGravity = .resize
    #if canImport(UIKit)
      outputLayer.backgroundColor = UIColor.clear.cgColor
    #elseif canImport(AppKit)
      outputLayer.backgroundColor = NSColor.clear.cgColor
      guard let layer else {
        fatalError("ViewEffect host view must be layer-backed")
      }
      layer.backgroundColor = NSColor.clear.cgColor
    #endif
    outputView.translatesAutoresizingMaskIntoConstraints = true
    addSubview(outputView)
    self.outputView = outputView
    self.outputLayer = outputLayer
    self.presenter = WuiSurfacePresenter(device: device, layer: outputLayer)
  }

  /// Adds the unfiltered child and takes it out of every drawing path.
  ///
  /// Hidden as a *view*, not as a layer: `cacheDisplay(in:to:)` walks the view
  /// tree and asks each view to draw, so a view's own backing layer being
  /// hidden means nothing to it and the unfiltered child came back in every
  /// preview snapshot (waterui#519). `WuiMetalViewCapture` un-hides the backing
  /// layer for the duration of its `CARenderer` frame, so the child is captured
  /// exactly as before.
  private func setupChildView() {
    #if canImport(UIKit)
      insertSubview(childView, at: 0)
    #elseif canImport(AppKit)
      addSubview(childView, positioned: .below, relativeTo: nil)
      childView.wantsLayer = true
    #endif
    childView.isHidden = true
  }

  /// Records the dynamic range this effect presents in.
  ///
  /// Nothing is configured on the layer: an `IOSurface` carries its own pixel
  /// format and colour space, so the presenter applies both when it allocates
  /// the pair for the format the effect chose at attach.
  private func configureDynamicRange(_ mode: WuiDynamicRangeMode) {
    precondition(!renderState.isAttached, "ViewEffect dynamic range cannot change while attached")
    applyDynamicRange(mode, to: self)
    presenter.release()
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
    guard !renderInFlight, !framePresentationInFlight else {
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
      guard let window else { return }
    #elseif canImport(AppKit)
      guard let window else { return }
    #endif
    let dynamicRange = requireInheritedDynamicRange(for: self)
    guard prepareDynamicRange(dynamicRange) else { return }

    #if canImport(UIKit)
      currentScaleFactor = window.screen.scale
    #elseif canImport(AppKit)
      currentScaleFactor = window.backingScaleFactor
    #endif

    let width = UInt32(bounds.width * currentScaleFactor)
    let height = UInt32(bounds.height * currentScaleFactor)
    updateOutputLayerFrame()

    // Everything above is geometry, which layout is the only place to learn.
    // Attaching is not: it allocates what a capture needs, and an effect in a
    // covered window never captures anything — `scheduleFrameIfNeeded` refuses
    // the frame on the same condition (#576).
    guard canAttachNow() else { return }

    // Always the half-float target, as the `CAMetalLayer` path was: it set
    // `rendererMode: .high` unconditionally, so the effect has always rendered
    // in extended-range linear and only the *presentation* followed the
    // inherited mode.
    renderState.attachIfNeeded(width: width, height: height, prefersHDR: true)
    // After the attach, which is what decides the format both the capture
    // texture and the presented pair are made in.
    _ = ensureCaptureTexture(width: width, height: height)
  }

  /// Whether this effect's window could show a frame it captured.
  ///
  /// The same condition `scheduleFrameIfNeeded` puts on the frame clock, so the
  /// resources a capture needs are allocated exactly when a capture could
  /// happen. It is narrow on purpose: being covered is a state a window leaves
  /// and announces leaving, which is what makes deferring on it safe.
  private func canAttachNow() -> Bool {
    window != nil && !isPresentationOccluded
  }

  private func ensureCaptureTexture(width: UInt32, height: UInt32) -> MTLTexture {
    let pixelFormat = renderState.outputPixelFormat
    if let captureTexture,
      captureTexture.width == Int(width),
      captureTexture.height == Int(height),
      captureTexture.pixelFormat == pixelFormat
    {
      return captureTexture
    }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: pixelFormat,
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
  ///
  /// An occluded window is a different matter: wgpu skips its frames and
  /// reports them pending, so the clock stays stopped until the occlusion
  /// observer re-arms it (#353).
  private func scheduleFrameIfNeeded() {
    guard
      renderState.isAttached, window != nil, needsRender, !renderInFlight,
      !framePresentationInFlight, pendingSetupFrame == nil, !isPresentationOccluded
    else {
      stopDisplayLink()
      return
    }
    startDisplayLink()
  }

  private func renderFrame() {
    guard needsRender, !renderInFlight, !framePresentationInFlight, pendingSetupFrame == nil
    else {
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
      presenter.release()
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
    finishPreparedFrame(frame)
  }

  /// Runs the effect over the captured input and shows the result.
  ///
  /// The output goes into one of the presenter's `IOSurface`-backed textures,
  /// not into a Metal drawable: a drawable is readable only by the pipeline
  /// that presented it, so an effect's output was invisible to the preview
  /// snapshot, to `WuiViewRenderer`, and to an enclosing filter (#579).
  private func finishPreparedFrame(_ frame: WuiViewEffectCaptureFrame) {
    let output = renderState.resolveOutputSize(width: frame.width, height: frame.height)
    presenter.configure(
      width: Int(output.width),
      height: Int(output.height),
      pixelFormat: renderState.outputPixelFormat
    )
    guard let pending = presenter.nextFrame() else {
      fatalError("ViewEffect presenter has no texture to render into")
    }
    let rendered = renderState.renderPreparedInput(
      into: pending.texture,
      width: output.width,
      height: output.height
    )

    // The frame stays in flight until its fence: showing the surface before the
    // GPU has finished writing it composites a half-drawn frame, and starting
    // the next frame before then would render into the surface being shown.
    framePresentationInFlight = true
    observeGpuCaptureFence(rendered.fence) { [weak self] in
      guard let self else { return }
      self.framePresentationInFlight = false
      // The view stopped being able to present between this frame's render and
      // its fence — it left the window. `handleWindowChange` deferred the
      // teardown to whichever half of the frame was still in flight, and this
      // is that half.
      if self.detachAfterCapture {
        self.detachAfterCapture = false
        self.renderState.detachIfNeeded()
        self.presenter.release()
        self.completeReady(false)
        return
      }
      // A dynamic-range change asked for while this frame was in flight was
      // parked rather than applied, because reconfiguring under a running
      // render would pull the target out from under it. This is where the frame
      // ends, so this is where it is taken up.
      if self.pendingDynamicRangeMode != nil {
        self.pendingDynamicRangeMode = nil
        self.renderState.detachIfNeeded()
        self.initializeGpuIfNeeded()
        self.requestRenderIfNeeded()
        return
      }
      self.presenter.present(pending)
      self.revealOutput()
      // Only now has this host's presentation changed, so only now may an
      // enclosing filter be told to capture again.
      self.invalidateCapturedRendering()
      self.needsRender = self.needsRender || rendered.needsRedraw
      self.completeReady(true)
      self.scheduleFrameIfNeeded()
    }
  }

  private func handleRendererRedraw() {
    if renderState.isReady, let frame = pendingSetupFrame {
      pendingSetupFrame = nil
      finishPreparedFrame(frame)
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
    outputView.isHidden = false
  }

  private func hideOutput() {
    outputRevealed = false
    outputView.isHidden = true
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

  /// Whether the first paint should wait for this effect.
  ///
  /// An effect whose window cannot present has no first frame to wait for, and
  /// saying otherwise is not a delay but a crash: the waiter treats a
  /// participant that answers "not ready" as a failure to render. Since
  /// `initializeGpuIfNeeded` attaches nothing for such an effect, the two have
  /// to agree on the same condition.
  func participatesInFirstPaintReady() -> Bool {
    #if canImport(UIKit)
      window != nil && !isHidden && alpha > 0.01 && bounds.width > 0.5 && bounds.height > 0.5
        && canAttachNow()
    #elseif canImport(AppKit)
      window != nil && !isHidden && alphaValue > 0.01 && bounds.width > 0.5 && bounds.height > 0.5
        && canAttachNow()
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

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
      super.traitCollectionDidChange(previousTraitCollection)
      guard traitCollection.displayScale != previousTraitCollection?.displayScale else {
        return
      }
      initializeGpuIfNeeded()
      requestRenderIfNeeded()
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
      occlusionObserver.observe(window: window)
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
      if renderInFlight || framePresentationInFlight {
        detachAfterCapture = true
      } else {
        renderState.detachIfNeeded()
        presenter.release()
      }
      return
    }
    detachAfterCapture = false
    initializeGpuIfNeeded()
    requestRenderIfNeeded()
  }

  /// Positions the presentation view and its layer. The presented surfaces are
  /// allocated at the effect's resolved output size by the next rendered frame,
  /// so nothing here decides how large they are.
  private func updateOutputLayerFrame() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    outputView.frame = bounds
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
