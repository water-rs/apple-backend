// Compiled out when the app disables WaterUI's `gpu` feature: the
// `waterui_*` GPU symbols this file binds do not exist in that build.
#if !WATERUI_NO_GPU
import Foundation
import Metal
import OSLog
import QuartzCore

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

typealias WuiMetalViewCaptureCompletion = @MainActor @Sendable (Bool) -> Void

@MainActor
private final class WuiMetalFenceBatch {
  private var remaining: Int
  private let completion: @MainActor @Sendable () -> Void

  init(count: Int, completion: @escaping @MainActor @Sendable () -> Void) {
    precondition(count > 0, "A GPU fence batch must contain at least one submission")
    self.remaining = count
    self.completion = completion
  }

  func completeOne() {
    remaining -= 1
    precondition(remaining >= 0, "A GPU fence batch completed more than once")
    if remaining == 0 {
      completion()
    }
  }
}

/// Captures a native view subtree — and any `GpuSurface` nested inside it — into
/// a single Metal texture for the filter and view-effect pipelines.
///
/// # Orientation and scale contract
///
/// The destination texture is *top-down* (texel row 0 is the visually topmost
/// row) and sized in device pixels, so it can be handed straight to wgpu and
/// presented by a `CAMetalLayer` without any further flip or rescale. Neither
/// property comes for free:
///
/// - `CARenderer` renders a layer tree bottom-up: layer-space y grows with the
///   destination row index, which is the opposite of every other texture in this
///   pipeline.
/// - `CARenderer.bounds` is the destination rectangle in *pixels*, while the
///   layer tree is laid out in *points*. Left alone, a 100×100pt subtree renders
///   into the top-left 100×100 pixels of a 200×200px target on a 2× display.
///
/// Both are corrected in one step by `withCaptureTransform`, which mirrors and
/// scales the captured layer tree for the duration of the `CARenderer` frame.
/// Because the capture texture is then in the same orientation as a
/// wgpu-rendered `GpuSurface` texture, `CaptureComposite.metal` is a plain
/// identity copy for both of its inputs.
///
/// # Concurrency
///
/// View-tree state (`activeGpuSurfaces`, the `CARenderer`, the overlay texture)
/// is main-actor isolated. GPU composition state lives in `Compositor`, which
/// confines every one of its members to a private serial queue. The type is
/// `@unchecked Sendable` because Swift cannot express that split; nothing here
/// is shared without either the main actor or that serial queue mediating it.
final class WuiMetalViewCapture: @unchecked Sendable {
  private struct GpuSurfaceSnapshot: @unchecked Sendable {
    let surface: WuiGpuSurface
    let origin: MTLOrigin
    let size: MTLSize
    let pixelFormat: MTLPixelFormat
  }

  private struct Preparation: @unchecked Sendable {
    let device: MTLDevice
    let targetTexture: MTLTexture
    let overlayTexture: MTLTexture?
    let nativeCaptureFence: MTLCommandBuffer
    let snapshots: [GpuSurfaceSnapshot]
  }

  private struct SurfaceTextureEntry {
    let texture: MTLTexture
    let size: MTLSize
    let pixelFormat: MTLPixelFormat
  }

  private struct RenderedGpuSurface: @unchecked Sendable {
    let snapshot: GpuSurfaceSnapshot
    let texture: MTLTexture
  }

  /// Maps the captured layer tree's point space onto the pixel-sized destination.
  private struct CaptureGeometry {
    let scaleX: CGFloat
    let scaleY: CGFloat
    /// Destination height in pixels; the mirror axis of the capture transform.
    let targetHeight: CGFloat
  }

  /// GPU composition state, confined to `queue`.
  ///
  /// Every member is touched only from inside `perform`, so the serial queue
  /// supplies the mutual exclusion the type system cannot — hence
  /// `@unchecked Sendable`. Work enqueued during teardown is therefore ordered
  /// after any composition still in flight, and the queue's own strong
  /// reference keeps the resources alive until that work drains.
  private final class Compositor: @unchecked Sendable {
    private let queue = DispatchQueue(
      label: "dev.waterui.graphics.capture-composition",
      qos: .userInteractive
    )
    private var commandQueue: MTLCommandQueue?
    private var surfaceTextures: [ObjectIdentifier: SurfaceTextureEntry] = [:]
    private var pipeline: MTLRenderPipelineState?
    private var pipelineFormat: MTLPixelFormat = .invalid
    private var sampler: MTLSamplerState?

    func perform(_ body: @escaping @Sendable (Compositor) -> Void) {
      queue.async { [self] in
        body(self)
      }
    }

    /// Drops cached per-surface textures once all in-flight composition drains.
    func discardResources() {
      queue.async { [self] in
        surfaceTextures.removeAll()
      }
    }

    func prepareSurfaceTextures(
      snapshots: [GpuSurfaceSnapshot],
      device: MTLDevice
    ) -> [RenderedGpuSurface] {
      let activeSurfaceIds = Set(snapshots.lazy.map { ObjectIdentifier($0.surface) })
      surfaceTextures = surfaceTextures.filter { activeSurfaceIds.contains($0.key) }
      return snapshots.map { snapshot in
        RenderedGpuSurface(
          snapshot: snapshot,
          texture: surfaceTexture(for: snapshot, device: device)
        )
      }
    }

    func makeCommandBuffer(device: MTLDevice) -> MTLCommandBuffer {
      if commandQueue == nil || commandQueue?.device !== device {
        commandQueue = device.makeCommandQueue()
      }
      guard let commandBuffer = commandQueue?.makeCommandBuffer() else {
        fatalError("Failed to create the Metal view composition command buffer")
      }
      return commandBuffer
    }

    func encodeComposition(
      surfaces: [RenderedGpuSurface],
      overlayTexture: MTLTexture?,
      targetTexture: MTLTexture,
      commandBuffer: MTLCommandBuffer,
      device: MTLDevice
    ) {
      let descriptor = MTLRenderPassDescriptor()
      descriptor.colorAttachments[0].texture = targetTexture
      descriptor.colorAttachments[0].loadAction = .clear
      descriptor.colorAttachments[0].storeAction = .store
      descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
      guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
        fatalError("Failed to create the Metal capture composition encoder")
      }
      encoder.setRenderPipelineState(
        renderPipeline(device: device, format: targetTexture.pixelFormat)
      )
      encoder.setFragmentSamplerState(compositeSampler(device: device), index: 0)
      // GpuSurface contents first, then the native overlay blended on top: the
      // overlay is transparent wherever a surface's Metal layer was suppressed.
      // Viewport origins are top-down, which matches both the snapshot rects
      // (taken in flipped view coordinates) and the capture texture itself.
      for surface in surfaces {
        let snapshot = surface.snapshot
        encoder.setViewport(
          MTLViewport(
            originX: Double(snapshot.origin.x),
            originY: Double(snapshot.origin.y),
            width: Double(snapshot.size.width),
            height: Double(snapshot.size.height),
            znear: 0,
            zfar: 1
          )
        )
        encoder.setScissorRect(
          MTLScissorRect(
            x: snapshot.origin.x,
            y: snapshot.origin.y,
            width: snapshot.size.width,
            height: snapshot.size.height
          )
        )
        encoder.setFragmentTexture(surface.texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
      }
      if let overlayTexture {
        encoder.setViewport(
          MTLViewport(
            originX: 0,
            originY: 0,
            width: Double(targetTexture.width),
            height: Double(targetTexture.height),
            znear: 0,
            zfar: 1
          )
        )
        encoder.setScissorRect(
          MTLScissorRect(
            x: 0,
            y: 0,
            width: targetTexture.width,
            height: targetTexture.height
          )
        )
        encoder.setFragmentTexture(overlayTexture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
      }
      encoder.endEncoding()
    }

    private func surfaceTexture(
      for snapshot: GpuSurfaceSnapshot,
      device: MTLDevice
    ) -> MTLTexture {
      let identifier = ObjectIdentifier(snapshot.surface)
      if let entry = surfaceTextures[identifier],
        entry.size.width == snapshot.size.width,
        entry.size.height == snapshot.size.height,
        entry.pixelFormat == snapshot.pixelFormat
      {
        return entry.texture
      }
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: snapshot.pixelFormat,
        width: snapshot.size.width,
        height: snapshot.size.height,
        mipmapped: false
      )
      descriptor.usage = [.shaderRead, .renderTarget]
      descriptor.storageMode = .private
      guard let texture = device.makeTexture(descriptor: descriptor) else {
        fatalError("Failed to create a GpuSurface capture texture")
      }
      surfaceTextures[identifier] = SurfaceTextureEntry(
        texture: texture,
        size: snapshot.size,
        pixelFormat: snapshot.pixelFormat
      )
      return texture
    }

    private func renderPipeline(
      device: MTLDevice,
      format: MTLPixelFormat
    ) -> MTLRenderPipelineState {
      if let pipeline, pipelineFormat == format {
        return pipeline
      }
      let library: MTLLibrary
      do {
        library = try device.makeDefaultLibrary(bundle: Bundle.module)
      } catch {
        fatalError("Failed to load WaterUI's precompiled Metal library: \(error)")
      }
      guard let vertex = library.makeFunction(name: "capture_composite_vertex"),
        let fragment = library.makeFunction(name: "capture_composite_fragment")
      else {
        fatalError("CaptureComposite.metal is missing required entry points")
      }
      let descriptor = MTLRenderPipelineDescriptor()
      descriptor.vertexFunction = vertex
      descriptor.fragmentFunction = fragment
      descriptor.colorAttachments[0].pixelFormat = format
      descriptor.colorAttachments[0].isBlendingEnabled = true
      descriptor.colorAttachments[0].rgbBlendOperation = .add
      descriptor.colorAttachments[0].alphaBlendOperation = .add
      descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
      descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
      descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
      descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
      do {
        let compiled = try device.makeRenderPipelineState(descriptor: descriptor)
        pipeline = compiled
        pipelineFormat = format
        return compiled
      } catch {
        fatalError("Failed to compile the Metal capture composition pipeline: \(error)")
      }
    }

    private func compositeSampler(device: MTLDevice) -> MTLSamplerState {
      if let sampler { return sampler }
      let descriptor = MTLSamplerDescriptor()
      descriptor.minFilter = .linear
      descriptor.magFilter = .linear
      descriptor.sAddressMode = .clampToEdge
      descriptor.tAddressMode = .clampToEdge
      guard let created = device.makeSamplerState(descriptor: descriptor) else {
        fatalError("Failed to create the Metal capture composition sampler")
      }
      sampler = created
      return created
    }
  }

  private let contentView: PlatformView
  @MainActor var onRedraw: (() -> Void)?

  @MainActor private var activeGpuSurfaces: [ObjectIdentifier: WuiGpuSurface] = [:]
  @MainActor private var captureRenderer: CARenderer?
  @MainActor private var nativeCaptureQueue: MTLCommandQueue?
  @MainActor private var nativeCaptureDevice: MTLDevice?
  @MainActor private var nativeCapturePixelFormat: MTLPixelFormat = .invalid
  @MainActor private var overlayTexture: MTLTexture?

  private let compositor = Compositor()

  @MainActor
  init(contentView: PlatformView) {
    self.contentView = contentView
  }

  @MainActor
  func capture(
    into targetTexture: MTLTexture,
    completion: @escaping WuiMetalViewCaptureCompletion
  ) {
    let preparation = prepareCapture(into: targetTexture)
    Logger.graphics.debug(
      """
      Capture started: \(targetTexture.width, privacy: .public)\
      x\(targetTexture.height, privacy: .public), \
      gpuSurfaces=\(preparation.snapshots.count, privacy: .public)
      """
    )
    let compositor = self.compositor
    preparation.nativeCaptureFence.addCompletedHandler { [weak self] commandBuffer in
      guard commandBuffer.status == .completed else {
        fatalError(
          "Native Metal capture failed: \(String(describing: commandBuffer.error))"
        )
      }
      guard !preparation.snapshots.isEmpty else {
        DispatchQueue.main.async {
          completion(true)
        }
        return
      }
      compositor.perform { compositor in
        let rendered = compositor.prepareSurfaceTextures(
          snapshots: preparation.snapshots,
          device: preparation.device
        )
        DispatchQueue.main.async {
          MainActor.assumeIsolated {
            // The capture pipeline outlives no one: it is owned by the effect
            // view that requested this frame, so if it is gone the frame has
            // nowhere to land and dropping it is the whole of the work left.
            guard let self else {
              Logger.graphics.debug("Native capture completed after teardown; frame dropped")
              return
            }
            self.submitGpuSurfaces(rendered, preparation: preparation, completion: completion)
          }
        }
      }
    }
  }

  @MainActor
  func shutdown() {
    Logger.graphics.debug(
      "Capture pipeline shutting down, externalSurfaces=\(self.activeGpuSurfaces.count, privacy: .public)"
    )
    for surface in activeGpuSurfaces.values {
      surface.endExternalRendering(resumingPresentation: true)
    }
    activeGpuSurfaces.removeAll()
    overlayTexture = nil
    captureRenderer = nil
    nativeCaptureQueue = nil
    nativeCaptureDevice = nil
    nativeCapturePixelFormat = .invalid
    compositor.discardResources()
  }

  @MainActor deinit {
    precondition(
      activeGpuSurfaces.isEmpty,
      "WuiMetalViewCapture must be shut down before deinitialization"
    )
  }

  @MainActor
  private func prepareCapture(into targetTexture: MTLTexture) -> Preparation {
    prepareCaptureView(contentView)
    let layer = resolveCaptureLayer(from: contentView)
    let geometry = captureGeometry(for: targetTexture)
    let snapshots = collectGpuSurfaceSnapshots(
      targetTexture: targetTexture,
      geometry: geometry
    )
    updateExternalGpuSurfaces(snapshots)

    let nativeTarget: MTLTexture
    if snapshots.isEmpty {
      nativeTarget = targetTexture
    } else {
      nativeTarget = ensureOverlayTexture(
        device: targetTexture.device,
        pixelFormat: targetTexture.pixelFormat,
        width: targetTexture.width,
        height: targetTexture.height
      )
    }

    let wasHidden = layer.isHidden
    setLayer(layer, hidden: false)
    defer { setLayer(layer, hidden: wasHidden) }

    let nativeCaptureFence: MTLCommandBuffer
    if snapshots.isEmpty {
      nativeCaptureFence = renderNativeLayer(layer, into: nativeTarget, geometry: geometry)
    } else {
      for snapshot in snapshots {
        snapshot.surface.beginCaptureSuppression()
      }
      defer {
        for snapshot in snapshots.reversed() {
          snapshot.surface.endCaptureSuppression()
        }
      }
      nativeCaptureFence = renderNativeLayer(layer, into: nativeTarget, geometry: geometry)
    }

    return Preparation(
      device: targetTexture.device,
      targetTexture: targetTexture,
      overlayTexture: snapshots.isEmpty ? nil : nativeTarget,
      nativeCaptureFence: nativeCaptureFence,
      snapshots: snapshots
    )
  }

  @MainActor
  private func captureGeometry(for targetTexture: MTLTexture) -> CaptureGeometry {
    precondition(
      contentView.bounds.width > 0 && contentView.bounds.height > 0,
      "WaterUI capture content must have non-zero bounds"
    )
    return CaptureGeometry(
      scaleX: CGFloat(targetTexture.width) / contentView.bounds.width,
      scaleY: CGFloat(targetTexture.height) / contentView.bounds.height,
      targetHeight: CGFloat(targetTexture.height)
    )
  }

  @MainActor
  private func prepareCaptureView(_ view: PlatformView) {
    #if canImport(AppKit)
      ensureLayerBacked(view)
      view.needsLayout = true
      view.layoutSubtreeIfNeeded()
      view.layer?.setNeedsLayout()
      view.layer?.layoutIfNeeded()
      view.needsDisplay = true
      view.displayIfNeeded()
    #elseif canImport(UIKit)
      view.setNeedsLayout()
      view.layoutIfNeeded()
    #endif
  }

  #if canImport(AppKit)
    @MainActor
    private func ensureLayerBacked(_ view: PlatformView) {
      if view.layer == nil {
        view.wantsLayer = true
      }
      for subview in view.subviews {
        ensureLayerBacked(subview)
      }
    }
  #endif

  @MainActor
  private func resolveCaptureLayer(from view: PlatformView) -> CALayer {
    if let component = view as? WuiComponent,
      isMetadataComponent(component),
      let contentSubview = view.subviews.first(where: { $0 is WuiComponent })
    {
      return resolveCaptureLayer(from: contentSubview)
    }

    #if canImport(AppKit)
      ensureLayerBacked(view)
    #endif
    #if canImport(UIKit)
      return view.layer
    #elseif canImport(AppKit)
      guard let layer = view.layer else {
        fatalError("WaterUI capture view is not layer-backed")
      }
      return layer
    #endif
  }

  @MainActor
  private func setLayer(_ layer: CALayer, hidden: Bool) {
    guard layer.isHidden != hidden else { return }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.isHidden = hidden
    CATransaction.commit()
  }

  /// Runs `body` with `layer` mapped onto the pixel-sized capture destination.
  ///
  /// `CARenderer` takes its destination rectangle in pixels but reads the layer
  /// tree in points, and its destination row index grows with layer-space y —
  /// the opposite of every other texture in this pipeline. One transform fixes
  /// both: scale by the backing factor, mirror vertically, and translate the
  /// mirrored tree back down onto the destination.
  ///
  /// Deriving the position from the layer's own position keeps the mapping
  /// independent of its anchor point (AppKit uses `(0, 0)`, UIKit `(0.5, 0.5)`),
  /// and concatenating onto the existing transform keeps any transform the view
  /// already carries.
  ///
  /// The mutation is restored before this call returns, so no Core Animation
  /// commit ever sees the capture geometry — the same contract the surrounding
  /// `isHidden` dance relies on.
  @MainActor
  private func withCaptureTransform<T>(
    _ layer: CALayer,
    geometry: CaptureGeometry,
    _ body: () -> T
  ) -> T {
    let savedTransform = layer.transform
    let savedPosition = layer.position

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.transform = CATransform3DConcat(
      savedTransform,
      CATransform3DMakeScale(geometry.scaleX, -geometry.scaleY, 1)
    )
    layer.position = CGPoint(
      x: savedPosition.x * geometry.scaleX,
      y: geometry.targetHeight - savedPosition.y * geometry.scaleY
    )
    CATransaction.commit()

    defer {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      layer.transform = savedTransform
      layer.position = savedPosition
      CATransaction.commit()
    }

    return body()
  }

  @MainActor
  private func renderNativeLayer(
    _ layer: CALayer,
    into texture: MTLTexture,
    geometry: CaptureGeometry
  ) -> MTLCommandBuffer {
    let device = texture.device
    if nativeCaptureQueue == nil || nativeCaptureDevice !== device
      || nativeCapturePixelFormat != texture.pixelFormat
    {
      nativeCaptureDevice = device
      nativeCapturePixelFormat = texture.pixelFormat
      nativeCaptureQueue = device.makeCommandQueue()
      captureRenderer = nil
    }
    guard let queue = nativeCaptureQueue else {
      fatalError("Failed to create the native Metal capture command queue")
    }

    let colorSpace: CGColorSpace? =
      texture.pixelFormat == .rgba16Float
      ? CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
      : CGColorSpace(name: CGColorSpace.sRGB)
    let renderer: CARenderer
    if let existing = captureRenderer {
      renderer = existing
      renderer.setDestination(texture)
    } else {
      renderer = CARenderer(
        mtlTexture: texture,
        options: [
          kCARendererColorSpace as String: colorSpace as Any,
          kCARendererMetalCommandQueue as String: queue,
        ]
      )
      captureRenderer = renderer
    }

    renderer.layer = layer
    // The destination rectangle is in pixels; `withCaptureTransform` brings the
    // point-space layer tree into that same space.
    renderer.bounds = CGRect(x: 0, y: 0, width: texture.width, height: texture.height)
    withCaptureTransform(layer, geometry: geometry) {
      let time = CACurrentMediaTime()
      renderer.beginFrame(atTime: time, timeStamp: nil)
      renderer.addUpdate(renderer.bounds)
      renderer.render()
      renderer.endFrame()
    }

    // `CARenderer` encodes its work onto `queue` during `render()` but hands
    // back no completion signal, so an empty command buffer committed right
    // afterwards stands in as the fence: command buffers in one Metal queue
    // execute in commit order, so this one completes only once the capture has.
    // That is load-bearing, and it holds because `nativeCaptureQueue` is created
    // here, handed to nothing but this `CARenderer`, and only ever driven from
    // the main actor — never share this queue with other work.
    guard let commandBuffer = queue.makeCommandBuffer() else {
      fatalError("Failed to create the native Metal capture command buffer")
    }
    commandBuffer.commit()
    return commandBuffer
  }

  @MainActor
  private func collectGpuSurfaceSnapshots(
    targetTexture: MTLTexture,
    geometry: CaptureGeometry
  ) -> [GpuSurfaceSnapshot] {
    var snapshots: [GpuSurfaceSnapshot] = []
    collectGpuSurfaceSnapshots(
      from: contentView,
      into: &snapshots,
      geometry: geometry,
      targetWidth: targetTexture.width,
      targetHeight: targetTexture.height
    )
    return snapshots
  }

  @MainActor
  private func collectGpuSurfaceSnapshots(
    from view: PlatformView,
    into snapshots: inout [GpuSurfaceSnapshot],
    geometry: CaptureGeometry,
    targetWidth: Int,
    targetHeight: Int
  ) {
    if let surface = view as? WuiGpuSurface {
      let rect = surface.convert(surface.bounds, to: contentView)
      let originX = max(0, Int((rect.minX * geometry.scaleX).rounded(.down)))
      let originY = max(0, Int((rect.minY * geometry.scaleY).rounded(.down)))
      let width = min(
        Int((rect.width * geometry.scaleX).rounded(.up)),
        targetWidth - originX
      )
      let height = min(
        Int((rect.height * geometry.scaleY).rounded(.up)),
        targetHeight - originY
      )
      if width > 0, height > 0 {
        snapshots.append(
          GpuSurfaceSnapshot(
            surface: surface,
            origin: MTLOrigin(x: originX, y: originY, z: 0),
            size: MTLSize(width: width, height: height, depth: 1),
            pixelFormat: surface.capturePixelFormat
          )
        )
      }
      return
    }

    for subview in view.subviews where subview is WuiComponent {
      collectGpuSurfaceSnapshots(
        from: subview,
        into: &snapshots,
        geometry: geometry,
        targetWidth: targetWidth,
        targetHeight: targetHeight
      )
    }
  }

  @MainActor
  private func updateExternalGpuSurfaces(_ snapshots: [GpuSurfaceSnapshot]) {
    guard let onRedraw else {
      fatalError("WuiMetalViewCapture redraw handler was not installed")
    }
    var next: [ObjectIdentifier: WuiGpuSurface] = [:]
    for snapshot in snapshots {
      next[ObjectIdentifier(snapshot.surface)] = snapshot.surface
    }

    for (identifier, surface) in activeGpuSurfaces where next[identifier] == nil {
      Logger.graphics.debug("GpuSurface left the captured subtree; presentation resumed")
      surface.endExternalRendering(resumingPresentation: true)
    }
    for (identifier, surface) in next where activeGpuSurfaces[identifier] == nil {
      Logger.graphics.debug("GpuSurface joined the captured subtree; presentation suspended")
      surface.beginExternalRendering(onRedraw: onRedraw)
    }
    activeGpuSurfaces = next
  }

  @MainActor
  private func ensureOverlayTexture(
    device: MTLDevice,
    pixelFormat: MTLPixelFormat,
    width: Int,
    height: Int
  ) -> MTLTexture {
    if let overlayTexture,
      overlayTexture.width == width,
      overlayTexture.height == height,
      overlayTexture.pixelFormat == pixelFormat
    {
      return overlayTexture
    }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: pixelFormat,
      width: width,
      height: height,
      mipmapped: false
    )
    descriptor.usage = [.shaderRead, .renderTarget]
    descriptor.storageMode = .private
    guard let texture = device.makeTexture(descriptor: descriptor) else {
      fatalError("Failed to create the native capture overlay texture")
    }
    overlayTexture = texture
    return texture
  }

  @MainActor
  private func submitGpuSurfaces(
    _ rendered: [RenderedGpuSurface],
    preparation: Preparation,
    completion: @escaping WuiMetalViewCaptureCompletion
  ) {
    for item in rendered {
      guard item.snapshot.surface.prepareExternalRender(texture: item.texture) else {
        Logger.graphics.debug("GpuSurface setup still pending; capture frame deferred")
        completion(false)
        return
      }
    }

    let batch = WuiMetalFenceBatch(count: rendered.count) { [compositor = self.compositor] in
      Self.compose(
        compositor,
        preparation: preparation,
        rendered: rendered,
        completion: completion
      )
    }
    for item in rendered {
      item.snapshot.surface.renderPreparedExternalTexture(
        texture: item.texture,
        width: UInt32(item.snapshot.size.width),
        height: UInt32(item.snapshot.size.height)
      ) {
        batch.completeOne()
      }
    }
  }

  /// Encodes the final composition off the main thread.
  ///
  /// Deliberately free of `self`: once the surfaces have rendered, the pass
  /// depends on nothing but the compositor and the prepared textures, so it
  /// completes correctly even if the owning view is torn down meanwhile.
  private static func compose(
    _ compositor: Compositor,
    preparation: Preparation,
    rendered: [RenderedGpuSurface],
    completion: @escaping WuiMetalViewCaptureCompletion
  ) {
    compositor.perform { compositor in
      let commandBuffer = compositor.makeCommandBuffer(device: preparation.device)
      compositor.encodeComposition(
        surfaces: rendered,
        overlayTexture: preparation.overlayTexture,
        targetTexture: preparation.targetTexture,
        commandBuffer: commandBuffer,
        device: preparation.device
      )
      commandBuffer.addCompletedHandler { commandBuffer in
        guard commandBuffer.status == .completed else {
          fatalError(
            "Metal view composition failed: \(String(describing: commandBuffer.error))"
          )
        }
        Logger.graphics.debug("Capture composition complete")
        DispatchQueue.main.async {
          completion(true)
        }
      }
      commandBuffer.commit()
    }
  }
}
#endif  // !WATERUI_NO_GPU
