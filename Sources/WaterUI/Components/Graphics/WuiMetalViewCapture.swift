import Foundation
import Metal
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

  private let contentView: PlatformView
  @MainActor var onRedraw: (() -> Void)?

  @MainActor private var activeGpuSurfaces: [ObjectIdentifier: WuiGpuSurface] = [:]
  @MainActor private var captureRenderer: CARenderer?
  @MainActor private var nativeCaptureQueue: MTLCommandQueue?
  @MainActor private var nativeCaptureDevice: MTLDevice?
  @MainActor private var nativeCapturePixelFormat: MTLPixelFormat = .invalid
  @MainActor private var overlayTexture: MTLTexture?

  private var commandQueue: MTLCommandQueue?
  private var surfaceTextures: [ObjectIdentifier: SurfaceTextureEntry] = [:]
  private var compositePipeline: MTLRenderPipelineState?
  private var compositePipelineFormat: MTLPixelFormat = .invalid
  private var compositeSampler: MTLSamplerState?

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
    preparation.nativeCaptureFence.addCompletedHandler { [self, preparation] commandBuffer in
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
      DispatchQueue.global(qos: .userInteractive).async { [self, preparation] in
        let rendered = prepareGpuSurfaceTextures(preparation)
        DispatchQueue.main.async { [self, preparation, rendered] in
          MainActor.assumeIsolated {
            submitGpuSurfaces(rendered, preparation: preparation, completion: completion)
          }
        }
      }
    }
  }

  @MainActor
  func shutdown() {
    for surface in activeGpuSurfaces.values {
      surface.endExternalRendering()
    }
    activeGpuSurfaces.removeAll()
    overlayTexture = nil
    captureRenderer = nil
    nativeCaptureQueue = nil
    nativeCaptureDevice = nil
    nativeCapturePixelFormat = .invalid
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
    let snapshots = collectGpuSurfaceSnapshots(targetTexture: targetTexture)
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
      nativeCaptureFence = renderNativeLayer(layer, into: nativeTarget)
    } else {
      for snapshot in snapshots {
        snapshot.surface.beginCaptureSuppression()
      }
      defer {
        for snapshot in snapshots.reversed() {
          snapshot.surface.endCaptureSuppression()
        }
      }
      nativeCaptureFence = renderNativeLayer(layer, into: nativeTarget)
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

  @MainActor
  private func renderNativeLayer(_ layer: CALayer, into texture: MTLTexture) -> MTLCommandBuffer {
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
    renderer.bounds = CGRect(x: 0, y: 0, width: texture.width, height: texture.height)
    let time = CACurrentMediaTime()
    renderer.beginFrame(atTime: time, timeStamp: nil)
    renderer.addUpdate(renderer.bounds)
    renderer.render()
    renderer.endFrame()

    guard let commandBuffer = queue.makeCommandBuffer() else {
      fatalError("Failed to create the native Metal capture command buffer")
    }
    commandBuffer.commit()
    return commandBuffer
  }

  @MainActor
  private func collectGpuSurfaceSnapshots(targetTexture: MTLTexture) -> [GpuSurfaceSnapshot] {
    var snapshots: [GpuSurfaceSnapshot] = []
    collectGpuSurfaceSnapshots(
      from: contentView,
      into: &snapshots,
      targetWidth: targetTexture.width,
      targetHeight: targetTexture.height
    )
    return snapshots
  }

  @MainActor
  private func collectGpuSurfaceSnapshots(
    from view: PlatformView,
    into snapshots: inout [GpuSurfaceSnapshot],
    targetWidth: Int,
    targetHeight: Int
  ) {
    if let surface = view as? WuiGpuSurface {
      let rect = surface.convert(surface.bounds, to: contentView)
      precondition(
        contentView.bounds.width > 0 && contentView.bounds.height > 0,
        "WaterUI capture content must have non-zero bounds"
      )
      let scaleX = CGFloat(targetWidth) / contentView.bounds.width
      let scaleY = CGFloat(targetHeight) / contentView.bounds.height
      let originX = max(0, Int((rect.minX * scaleX).rounded(.down)))
      let originY = max(0, Int((rect.minY * scaleY).rounded(.down)))
      let width = min(
        Int((rect.width * scaleX).rounded(.up)),
        targetWidth - originX
      )
      let height = min(
        Int((rect.height * scaleY).rounded(.up)),
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
      surface.endExternalRendering()
    }
    for (identifier, surface) in next where activeGpuSurfaces[identifier] == nil {
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

  private func prepareGpuSurfaceTextures(
    _ preparation: Preparation
  ) -> [RenderedGpuSurface] {
    var rendered: [RenderedGpuSurface] = []
    rendered.reserveCapacity(preparation.snapshots.count)
    let activeSurfaceIds = Set(preparation.snapshots.map { ObjectIdentifier($0.surface) })
    surfaceTextures = surfaceTextures.filter { activeSurfaceIds.contains($0.key) }

    for snapshot in preparation.snapshots {
      let texture = ensureSurfaceTexture(
        for: snapshot,
        device: preparation.device
      )
      rendered.append(RenderedGpuSurface(snapshot: snapshot, texture: texture))
    }
    return rendered
  }

  @MainActor
  private func submitGpuSurfaces(
    _ rendered: [RenderedGpuSurface],
    preparation: Preparation,
    completion: @escaping WuiMetalViewCaptureCompletion
  ) {
    for item in rendered {
      guard item.snapshot.surface.prepareExternalRender(texture: item.texture) else {
        completion(false)
        return
      }
    }

    let batch = WuiMetalFenceBatch(count: rendered.count) { [self, preparation, rendered] in
      compose(preparation, rendered: rendered, completion: completion)
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

  @MainActor
  private func compose(
    _ preparation: Preparation,
    rendered: [RenderedGpuSurface],
    completion: @escaping WuiMetalViewCaptureCompletion
  ) {
    DispatchQueue.global(qos: .userInteractive).async { [self, preparation, rendered] in
      let commandBuffer = makeCommandBuffer(device: preparation.device)
      encodeComposition(
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
        DispatchQueue.main.async {
          completion(true)
        }
      }
      commandBuffer.commit()
    }
  }

  private func ensureSurfaceTexture(
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

  private func makeCommandBuffer(device: MTLDevice) -> MTLCommandBuffer {
    if commandQueue == nil || commandQueue?.device !== device {
      commandQueue = device.makeCommandQueue()
    }
    guard let commandBuffer = commandQueue?.makeCommandBuffer() else {
      fatalError("Failed to create the Metal view composition command buffer")
    }
    return commandBuffer
  }

  private func encodeComposition(
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
      compositePipeline(device: device, format: targetTexture.pixelFormat)
    )
    encoder.setFragmentSamplerState(compositeSampler(device: device), index: 0)
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

  private func compositePipeline(
    device: MTLDevice,
    format: MTLPixelFormat
  ) -> MTLRenderPipelineState {
    if let compositePipeline, compositePipelineFormat == format {
      return compositePipeline
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
      let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
      compositePipeline = pipeline
      compositePipelineFormat = format
      return pipeline
    } catch {
      fatalError("Failed to compile the Metal capture composition pipeline: \(error)")
    }
  }

  private func compositeSampler(device: MTLDevice) -> MTLSamplerState {
    if let compositeSampler { return compositeSampler }
    let descriptor = MTLSamplerDescriptor()
    descriptor.minFilter = .linear
    descriptor.magFilter = .linear
    descriptor.sAddressMode = .clampToEdge
    descriptor.tAddressMode = .clampToEdge
    guard let sampler = device.makeSamplerState(descriptor: descriptor) else {
      fatalError("Failed to create the Metal capture composition sampler")
    }
    compositeSampler = sampler
    return sampler
  }
}
