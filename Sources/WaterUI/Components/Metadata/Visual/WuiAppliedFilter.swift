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
  /// Where the filtered result goes, which a filter may size differently from
  /// what it captured — a blur grows its output to hold the spread.
  let outputWidth: UInt32
  let outputHeight: UInt32
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
    width: UInt32,
    height: UInt32,
    prefersHDR: Bool
  ) {
    updateSize(width: width, height: height)
    guard !isAttached else { return }
    waterui_applied_filter_attach_host_textures(filterState, width, height, prefersHDR)
    waterui_applied_filter_setup(filterState)
    isAttached = true
    Logger.graphics.debug(
      "AppliedFilter attached: \(width, privacy: .public)x\(height, privacy: .public)"
    )
  }

  /// The Metal format the attached filter renders its output in.
  ///
  /// The host creates its `IOSurface` pair in this format: the filter decided it
  /// at attach from the dynamic-range preference, and a surface in any other
  /// format would be a silent mismatch between what wgpu writes and what Core
  /// Animation samples.
  var outputPixelFormat: MTLPixelFormat {
    let raw = UInt(waterui_applied_filter_output_metal_pixel_format(filterState))
    guard let format = MTLPixelFormat(rawValue: raw) else {
      fatalError("AppliedFilter reported an output format Metal does not know")
    }
    return format
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
  /// output must be, and the answer comes back with the frame: the host
  /// allocates the surfaces it presents from, so unlike the swapchain path the
  /// size cannot stay entirely on the Rust side.
  func prepareCapture() -> WuiAppliedFilterCaptureFrame? {
    guard isAttached, width > 0, height > 0 else { return nil }
    precondition(isReady, "AppliedFilter capture requires completed asynchronous setup")
    let outputSize = waterui_applied_filter_resolve_output_size(filterState, width, height)
    waterui_applied_filter_prepare_capture(filterState, width, height)
    guard let rawTexture = waterui_applied_filter_get_capture_metal_texture(filterState) else {
      fatalError("AppliedFilter capture texture is unavailable")
    }
    let object = Unmanaged<AnyObject>.fromOpaque(rawTexture).takeUnretainedValue()
    guard let texture = object as? MTLTexture else {
      fatalError("AppliedFilter capture texture is not an MTLTexture")
    }
    return WuiAppliedFilterCaptureFrame(
      texture: texture,
      width: width,
      height: height,
      outputWidth: outputSize.width,
      outputHeight: outputSize.height
    )
  }

  /// Filters one captured frame into a host-owned texture.
  ///
  /// The fence is that frame's: the texture is only safe to show once it
  /// completes, so it is handed back rather than consumed here.
  func renderCapturedFrame(
    _ frame: WuiAppliedFilterCaptureFrame,
    into texture: MTLTexture
  ) -> (fence: OpaquePointer, needsRedraw: Bool) {
    precondition(isReady, "AppliedFilter render requires completed asynchronous setup")
    var needsRedraw = false
    guard
      let fence = waterui_applied_filter_render_to_metal_texture(
        filterState,
        Unmanaged.passUnretained(texture).toOpaque(),
        frame.width,
        frame.height,
        &needsRedraw
      )
    else {
      fatalError("waterui_applied_filter_render_to_metal_texture returned no fence")
    }
    return (fence, needsRedraw)
  }

  func shutdown() {
    detachIfNeeded()
    waterui_applied_filter_drop(filterState)
  }
}

@MainActor
final class WuiAppliedFilter: PlatformView, WuiComponent, WuiPresentsOwnContent, WuiFirstPaintReadyParticipant,
  WuiRenderedContentInvalidationSink
{
  static var rawId: CWaterUI.WuiTypeId { waterui_metadata_applied_filter_id() }

  private let contentView: any WuiComponent
  private let renderState: WuiAppliedFilterRenderState
  private let capturePipeline: WuiMetalViewCapture
  private var outputView: PlatformView!
  private var outputLayer: CALayer!
  private var presenter: WuiSurfacePresenter!
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
  private var filteredOutputRevealed = false
  /// Whether the content changed after the frame in flight captured it.
  ///
  /// A filter is only ready once it has shown a frame of the content as it
  /// actually stands. Nested, the inner host presents after the outer has
  /// already captured it, so the outer's first frame is of an empty
  /// presentation; completing readiness on that frame is what let the preview
  /// snapshot be taken before the real one arrived (waterui#521).
  private var contentChangedSinceCapture = false
  /// The geometry the last layout pass settled on.
  ///
  /// A layout pass is not by itself a reason to render: an enclosing capture
  /// lays this subtree out on every one of its own frames, so requesting a
  /// frame from every `layout()` made two nested filters drive each other at
  /// full speed forever — thousands of captures a second over a static view.
  /// Content changes arrive through `renderedContentDidInvalidate` instead, so
  /// layout only has to speak up when the geometry it produced is new.
  private var laidOutGeometry: CGRect?
  private var readyCompletions: [WuiAppliedFilterReadyCompletion] = []

  var stretchAxis: WuiStretchAxis { contentView.stretchAxis }

  required init(anyview: OpaquePointer, env: WuiEnvironment) {
    var metadata = waterui_force_as_metadata_applied_filter(anyview)
    let content = Self.fuseEnclosedFilters(into: &metadata, env: env)
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
      occlusionObserver = WuiWindowOcclusionObserver { [weak self] in
        guard let self else { return }
        // Attaching waits for a window that can present, so an uncovered window
        // is where the deferred attach happens as well as the deferred frame.
        self.initializeGpuIfNeeded()
        self.scheduleFrameIfNeeded()
      }
    #endif
    #if canImport(UIKit)
      registerForTraitChanges([UITraitDisplayScale.self]) {
        (view: WuiAppliedFilter, _: UITraitCollection) in
        view.initializeGpuIfNeeded()
        view.requestRenderIfNeeded()
      }
    #endif
    setupOutputView(device: metalDevice)
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

  /// Folds the filters this one directly encloses into `metadata`, and returns
  /// the view the fused filter captures.
  ///
  /// A component that filters its own body, filtered again by its caller, is
  /// two filters over one subtree with an `impl View` boundary between them, so
  /// nothing at the authoring layer fuses them the way a chain written in one
  /// expression is fused. Hosted as written they cost a capture, a presentation
  /// target and a full-size intermediate each, and the inner host has to finish
  /// a frame before the outer can capture one (#521).
  ///
  /// Whether there is anything to fuse is answered by the resolve walk each
  /// backend already runs, and the combining is Rust's, which is where the
  /// filters live: `waterui_applied_filter_chain` returns one descriptor that
  /// captures what the inner filter captured and runs both filters over it.
  private static func fuseEnclosedFilters(
    into metadata: inout CWaterUI.WuiAppliedFilter,
    env: WuiEnvironment
  ) -> OpaquePointer {
    while true {
      guard let content = metadata.content else {
        fatalError("AppliedFilter requires a child view")
      }
      // The walk consumes what it steps through, this descriptor's content
      // among it, so the descriptor stops claiming it before the walk starts.
      metadata.content = nil
      let resolved = wuiResolvedViewPointer(content, env: env)
      guard WuiViewId(waterui_view_id(resolved)) == Self.viewId else {
        return resolved
      }
      var inner = waterui_force_as_metadata_applied_filter(resolved)
      metadata = waterui_applied_filter_chain(&inner, &metadata)
    }
  }

  /// Builds the view the filtered frames are shown on.
  ///
  /// A plain `CALayer`, not a `CAMetalLayer`: the frames arrive as `IOSurface`
  /// contents, which Core Animation composites in place and — unlike a Metal
  /// drawable — every capture path can read, so a filtered subtree is finally
  /// visible to the preview snapshot and to an enclosing filter (#519).
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
        fatalError("AppliedFilter output view must be layer-backed")
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
        fatalError("AppliedFilter host view must be layer-backed")
      }
      layer.backgroundColor = NSColor.clear.cgColor
    #endif
    self.outputView = outputView
    self.outputLayer = outputLayer
    self.presenter = WuiSurfacePresenter(device: device, layer: outputLayer)
  }

  private func setupContentView() {
    contentView.translatesAutoresizingMaskIntoConstraints = true
    addSubview(contentView)
    hideUnfilteredContent()
    outputView.translatesAutoresizingMaskIntoConstraints = true
    addSubview(outputView)
  }

  /// Takes the unfiltered content out of every drawing path, leaving the
  /// filtered output as the only thing this host shows.
  ///
  /// The content is hidden as a *view*, not as a layer, and the difference is
  /// the whole reason a preview snapshot used to come back unfiltered. Measured
  /// on an `NSView` whose red subview was hidden and read back at its centre:
  /// with `subview.layer.isHidden = true`, `cacheDisplay(in:to:)` returned red —
  /// it walks the view tree and asks each view to draw, so a view's own backing
  /// layer being hidden means nothing to it. With `subview.isHidden = true` it
  /// returned the white background. `isHidden` on the standalone output layer
  /// *is* honoured (measured the same way), because that layer belongs to no
  /// view and is only ever reached through the layer tree.
  ///
  /// `WuiMetalViewCapture` still un-hides the backing layer for the duration of
  /// its `CARenderer` frame, so the content is captured exactly as before.
  private func hideUnfilteredContent() {
    #if canImport(AppKit)
      contentView.wantsLayer = true
    #endif
    contentView.isHidden = true
  }

  /// Records the dynamic range this filter presents in.
  ///
  /// Nothing is configured on the layer: an `IOSurface` carries its own pixel
  /// format and colour space, so the presenter applies both when it allocates
  /// the pair for the format the filter chose at attach.
  private func configureDynamicRange(_ mode: WuiDynamicRangeMode) {
    precondition(
      !renderState.isAttached, "AppliedFilter dynamic range cannot change while attached")
    applyDynamicRange(mode, to: self)
    presenter.release()
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
    renderState.updateSize(width: width, height: height)
    updateOutputLayerFrame()

    // Everything above is geometry, which layout is the only place to learn.
    // Attaching is not: it allocates a full-size capture texture and clears it
    // through a render pass, and a filter in a covered window never captures
    // anything — `scheduleFrameIfNeeded` refuses the frame on the same
    // condition. Laying out 144 filters in a window nobody could see bought 144
    // capture textures and 144 clearing passes for frames that never came
    // (#576). The occlusion observer runs this again when the window comes
    // back.
    guard canAttachNow() else { return }
    // Always the half-float target, as the `CAMetalLayer` path was: it set
    // `rendererMode: .high` unconditionally, so the filter has always rendered
    // in extended-range linear and only the *presentation* followed the
    // inherited mode. Narrowing that here would quietly cost filtered content
    // its precision on every standard-range display.
    renderState.attachIfNeeded(
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

  /// Asks for a frame only when this layout pass produced new geometry.
  ///
  /// See `laidOutGeometry`: a pass that changed nothing must not arm the frame
  /// clock, because captures provoke layout passes of their own.
  private func requestRenderIfGeometryChanged() {
    let geometry = bounds
    guard laidOutGeometry != geometry else {
      scheduleFrameIfNeeded()
      return
    }
    laidOutGeometry = geometry
    requestRenderIfNeeded()
  }

  func renderedContentDidInvalidate() {
    contentChangedSinceCapture = true
    requestRenderIfNeeded()
    invalidateCapturedRendering()
  }

  /// Whether this filter's window could show a frame it captured.
  ///
  /// The same condition `scheduleFrameIfNeeded` puts on the frame clock, so what
  /// a capture needs is allocated exactly when a capture could happen. It is
  /// narrow on purpose: being covered is a state a window leaves and announces
  /// leaving, which is what makes deferring on it safe.
  private func canAttachNow() -> Bool {
    window != nil && !isPresentationOccluded
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
      renderState.isAttached, renderState.isReady, window != nil, needsRender, !renderInFlight,
      !isPresentationOccluded
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
    contentChangedSinceCapture = false
    renderInFlight = true
    stopDisplayLink()

    // Weak: a capture that lands after this view is gone has nothing to finish,
    // and the capture pipeline it runs on is owned by this view anyway.
    capturePipeline.capture(into: frame.texture) { [weak self] captured in
      self?.finishCapturedFrame(frame, captured: captured)
    }
  }

  private func finishCapturedFrame(_ frame: WuiAppliedFilterCaptureFrame, captured: Bool) {
    if detachAfterCapture {
      renderInFlight = false
      detachAfterCapture = false
      renderState.detachIfNeeded()
      presenter.release()
      completeReady(false)
      return
    }
    if pendingDynamicRangeMode != nil {
      renderInFlight = false
      pendingDynamicRangeMode = nil
      renderState.detachIfNeeded()
      initializeGpuIfNeeded()
      requestRenderIfNeeded()
      return
    }
    guard captured else {
      renderInFlight = false
      scheduleFrameIfNeeded()
      return
    }

    presenter.configure(
      width: Int(frame.outputWidth),
      height: Int(frame.outputHeight),
      pixelFormat: renderState.outputPixelFormat
    )
    guard let pending = presenter.nextFrame() else {
      fatalError("AppliedFilter presenter has no texture to render into")
    }
    let rendered = renderState.renderCapturedFrame(frame, into: pending.texture)

    // The frame stays in flight until its fence: showing the surface before the
    // GPU has finished writing it composites a half-drawn frame, and starting
    // the next frame before then would render into the surface being shown.
    observeGpuCaptureFence(rendered.fence) { [weak self] in
      guard let self else { return }
      self.renderInFlight = false
      // The view stopped being able to present while this frame was between
      // its render and its fence — it left the window, or layout gave it zero
      // bounds. `releasePresentation` deferred the teardown to whichever half
      // of the frame was still in flight, and this is that half: showing the
      // frame now would reveal output on a view that is gone and leave the
      // Rust filter attached with its surfaces allocated.
      if self.detachAfterCapture {
        self.detachAfterCapture = false
        self.renderState.detachIfNeeded()
        self.presenter.release()
        self.completeReady(false)
        return
      }
      // A dynamic-range change asked for while this frame was in flight was
      // parked rather than applied, because reconfiguring under a running
      // render would pull the target out from under it. This is where the
      // frame ends, so this is where it is taken up — without it the surface
      // keeps rendering in the old range until some unrelated layout happens
      // to ask again.
      if self.pendingDynamicRangeMode != nil {
        self.pendingDynamicRangeMode = nil
        self.renderState.detachIfNeeded()
        self.initializeGpuIfNeeded()
        self.requestRenderIfNeeded()
        return
      }
      self.presenter.present(pending)
      self.revealFilteredOutput()
      // Only now has this host's presentation changed, so only now may an
      // enclosing filter be told to capture again. Signalling it before the
      // fence — as this did — made a filter inside a filter capture the outer
      // host's empty presentation and never hear about the real one, which is
      // the whole of waterui#521.
      self.invalidateCapturedRendering()
      self.needsRender = self.needsRender || rendered.needsRedraw
      if self.contentChangedSinceCapture {
        // What this frame shows is already out of date; readiness waits for the
        // one that captures the change.
        self.needsRender = true
      } else {
        self.completeReady(true)
      }
      self.scheduleFrameIfNeeded()
    }
  }

  private func requestReadyFrame(_ completion: @escaping WuiAppliedFilterReadyCompletion) {
    if filteredOutputRevealed {
      completion(true)
      return
    }
    readyCompletions.append(completion)
    prepareForReady()
    // Somebody is waiting on this filter's first frame, so this is a moment to
    // take up an attach that was deferred for a window that could not present:
    // `prepareForReady` only runs layout when the geometry needs it, and
    // becoming presentable changes no geometry.
    initializeGpuIfNeeded()
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
    outputView.isHidden = false
  }

  private func hideFilteredOutput() {
    filteredOutputRevealed = false
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

  /// Whether the first paint should wait for this filter.
  ///
  /// A filter whose window cannot present has no first frame to wait for, and
  /// saying otherwise is not a delay but a crash: the waiter treats a
  /// participant that answers "not ready" as a failure to render. Since
  /// `initializeGpuIfNeeded` attaches nothing for such a filter, the two have to
  /// agree on the same condition.
  func participatesInFirstPaintReady() -> Bool {
    #if canImport(UIKit)
      window != nil && !isHidden && alpha > 0.01 && bounds.width > 0.5 && bounds.height > 0.5
        && canAttachNow()
    #elseif canImport(AppKit)
      window != nil && !isHidden && alphaValue > 0.01 && bounds.width > 0.5 && bounds.height > 0.5
        && canAttachNow()
    #endif
  }

  func layoutPriority() -> Int32 { contentView.layoutPriority() }

  /// Transparent for layout: the proposal selected for this
  /// wrapper is the proposal its content was negotiated with.
  func setPlacementProposal(_ proposal: WuiProposalSize) {
    contentView.setPlacementProposal(proposal)
  }

  func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
    contentView.sizeThatFits(proposal)
  }

  func measure(_ proposal: WuiProposalSize) -> WuiViewDimensions {
    contentView.measure(proposal)
  }

  #if canImport(UIKit)
    override func layoutSubviews() {
      super.layoutSubviews()
      contentView.frame = bounds
      contentView.setNeedsLayout()
      contentView.layoutIfNeeded()
      updateOutputLayerFrame()
      initializeGpuIfNeeded()
      requestRenderIfGeometryChanged()
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
      requestRenderIfGeometryChanged()
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
      presenter.release()
    }
  }

  /// Positions the presentation view and its layer. The presented surfaces are
  /// allocated at the filter's resolved output size by the next rendered frame,
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
