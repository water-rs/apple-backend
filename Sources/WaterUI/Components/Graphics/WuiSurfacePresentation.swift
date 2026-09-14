// Compiled out when the app disables WaterUI's `gpu` feature: the
// `waterui_*` GPU symbols the presenting hosts bind do not exist in that build.
#if !WATERUI_NO_GPU
  import Foundation
  import IOSurface
  import Metal
  import OSLog
  import QuartzCore

  #if canImport(UIKit)
    import UIKit
  #elseif canImport(AppKit)
    import AppKit
  #endif

  /// The view whose backing layer shows a presenter's frames.
  ///
  /// A view of its own, not a bare sublayer of the host: `cacheDisplay(in:to:)`
  /// draws a view's whole layer tree before any of its subviews, so a bare
  /// sublayer lands underneath the host's content whatever its `zPosition` —
  /// which Core Animation honours and the snapshot ignores. As the last subview
  /// it is drawn last by both.
  @MainActor
  final class WuiSurfacePresentationView: PlatformView {
    #if canImport(AppKit)
      nonisolated override var isFlipped: Bool { true }
    #endif
  }

  /// Presents rendered frames through `IOSurface`-backed textures on a plain
  /// `CALayer`, instead of a `CAMetalLayer` swapchain.
  ///
  /// # Why not a swapchain
  ///
  /// A `CAMetalLayer`'s drawable can only be read by the pipeline that presented
  /// it. That is invisible to `CALayer.render(in:)` and to AppKit's
  /// `cacheDisplay(in:to:)` — which is how `water preview` snapshots a view — and
  /// invisible to `CARenderer`, which is how a filter captures the subtree
  /// underneath it. So a filter's own output could not be seen by the preview or
  /// by an enclosing filter: the snapshot showed the *unfiltered* content, and a
  /// nested filter pair captured nothing (waterui#519, waterui#521).
  ///
  /// An `IOSurface` handed to `CALayer.contents` is composited in place, and both
  /// capture paths read it. Measured before this was built, on a layer whose
  /// contents was an `IOSurface` filled with (220, 30, 30):
  /// `cacheDisplay` read back (220, 31, 30) and `layer.render(in:)` (220, 30, 30).
  ///
  /// It is also what removes the per-view drawable pool: a surface that did not
  /// change costs nothing, and there is no `present` to schedule.
  ///
  /// # Double buffering
  ///
  /// Two surfaces, never one. `contents` keeps whichever frame the compositor is
  /// showing, so the next frame renders into the other one and swaps only after
  /// its fence completes — a frame in flight is never on screen.
  @MainActor
  final class WuiSurfacePresenter {
    /// One `IOSurface` and the Metal texture that renders into it.
    private struct Buffer {
      let surface: IOSurfaceRef
      let texture: MTLTexture
    }

    /// A buffer handed out to render into, and the pair it came from.
    ///
    /// The generation is what ties a frame to the buffers that existed when it
    /// started. A frame's fence can land after a resize replaced the pair, and
    /// presenting "the current back buffer" at that point would show an
    /// `IOSurface` nothing has ever drawn into.
    struct PendingFrame {
      let texture: MTLTexture
      fileprivate let index: Int
      fileprivate let generation: Int
    }

    private let device: MTLDevice
    private let layer: CALayer
    private var buffers: [Buffer] = []
    private var nextIndex = 0
    private var generation = 0
    /// Whether a rendered frame is on the layer right now.
    ///
    /// A resize keeps it: the previous frame stays on `contents`, scaled, until
    /// one at the new size arrives. Only `release` takes it back down, because
    /// only `release` takes the frame off the layer.
    private(set) var hasPresentedFrame = false
    private var pixelFormat: MTLPixelFormat = .invalid
    private var width = 0
    private var height = 0

    /// The layer the presenter shows its frames on.
    ///
    /// A plain `CALayer`: everything a `CAMetalLayer` was here for — the device,
    /// the drawable pool, the present — belongs to the surfaces instead.
    init(device: MTLDevice, layer: CALayer) {
      self.device = device
      self.layer = layer
    }

    /// Whether buffers exist for exactly this size and format.
    func matches(width: Int, height: Int, pixelFormat: MTLPixelFormat) -> Bool {
      !buffers.isEmpty && self.width == width && self.height == height
        && self.pixelFormat == pixelFormat
    }

    /// Makes the buffer pair for a size and format, replacing any earlier pair.
    ///
    /// Nothing is reused across a resize: an `IOSurface` is fixed at its
    /// creation size, so a new size means a new pair. Whatever the layer is
    /// showing stays on it, scaled by `contentsGravity`, until a frame at the
    /// new size is ready — the last good frame stretched for a moment is what
    /// a resizing view should show, where clearing `contents` would punch a
    /// hole through the window for that same moment.
    func configure(width: Int, height: Int, pixelFormat: MTLPixelFormat) {
      precondition(width > 0 && height > 0, "A presented surface must have a non-zero size")
      if matches(width: width, height: height, pixelFormat: pixelFormat) { return }

      buffers = (0 ..< 2).map { _ in
        makeBuffer(width: width, height: height, pixelFormat: pixelFormat)
      }
      self.width = width
      self.height = height
      self.pixelFormat = pixelFormat
      nextIndex = 0
      generation &+= 1
      Logger.graphics.debug(
        "Surface presenter configured \(width, privacy: .public)x\(height, privacy: .public)"
      )
    }

    /// Drops the buffers and whatever the layer is showing.
    func release() {
      buffers.removeAll()
      width = 0
      height = 0
      pixelFormat = .invalid
      nextIndex = 0
      generation &+= 1
      hasPresentedFrame = false
      setContents(nil)
    }

    /// The buffer the next frame renders into: the one not being shown.
    func nextFrame() -> PendingFrame? {
      guard !buffers.isEmpty else { return nil }
      return PendingFrame(
        texture: buffers[nextIndex].texture,
        index: nextIndex,
        generation: generation
      )
    }

    /// Shows a frame once its fence says the GPU has finished writing it, and
    /// reports whether it reached the layer.
    ///
    /// Call this only from the completion of that frame's fence: showing a
    /// surface the GPU is still writing composites a half-drawn frame. A frame
    /// whose buffers have since been replaced is dropped rather than shown —
    /// its `IOSurface` is gone, and the buffer now in its place holds nothing.
    /// The caller is told, because a dropped frame is one the surface still
    /// owes and nothing else will ask for it again.
    @discardableResult
    func present(_ frame: PendingFrame) -> Bool {
      guard frame.generation == generation, frame.index < buffers.count else {
        Logger.graphics.debug("Surface presenter dropped a frame from a replaced buffer pair")
        return false
      }
      setContents(buffers[frame.index].surface)
      hasPresentedFrame = true
      nextIndex = (frame.index + 1) % buffers.count
      return true
    }

    private func setContents(_ contents: IOSurfaceRef?) {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      layer.contents = contents
      CATransaction.commit()
    }

    private func makeBuffer(width: Int, height: Int, pixelFormat: MTLPixelFormat) -> Buffer {
      let surface = makeSurface(width: width, height: height, pixelFormat: pixelFormat)
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: pixelFormat,
        width: width,
        height: height,
        mipmapped: false
      )
      descriptor.usage = [.renderTarget, .shaderRead]
      descriptor.storageMode = .shared
      guard let texture = device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0)
      else {
        fatalError("Surface presenter could not make a Metal texture for its IOSurface")
      }
      return Buffer(surface: surface, texture: texture)
    }

    private func makeSurface(width: Int, height: Int, pixelFormat: MTLPixelFormat) -> IOSurfaceRef {
      let (fourCC, bytesPerElement) = surfaceFormat(for: pixelFormat)
      // `IOSurface` wants its row bytes aligned to the device's own alignment;
      // an unaligned surface is either rejected or silently padded, and a padded
      // one read as tightly packed is sheared.
      let alignment = 16
      let rowBytes = ((width * bytesPerElement) + alignment - 1) / alignment * alignment
      // The C constructor, not `IOSurface(properties:)`: `MTLDevice`'s
      // `makeTexture(descriptor:iosurface:plane:)` takes an `IOSurfaceRef`, and
      // the class and the Core Foundation type do not bridge to each other.
      let properties: [CFString: Any] = [
        kIOSurfaceWidth: width,
        kIOSurfaceHeight: height,
        kIOSurfaceBytesPerElement: bytesPerElement,
        kIOSurfaceBytesPerRow: rowBytes,
        kIOSurfaceAllocSize: rowBytes * height,
        kIOSurfacePixelFormat: fourCC,
      ]
      guard let surface = IOSurfaceCreate(properties as CFDictionary) else {
        fatalError("Surface presenter could not create an IOSurface")
      }
      IOSurfaceSetValue(surface, kIOSurfaceColorSpace, colorSpace(for: pixelFormat))
      return surface
    }

    /// The `IOSurface` pixel format and element size matching a Metal format.
    ///
    /// Only the two formats the renderer presents in are mapped: the extended
    /// half-float target an HDR presentation uses, and the sRGB-encoded 8-bit
    /// one everything else uses. A third would be a silent mismatch between what
    /// wgpu renders and what Core Animation samples, so it is a crash instead.
    private func surfaceFormat(for pixelFormat: MTLPixelFormat) -> (UInt32, Int) {
      switch pixelFormat {
      case .bgra8Unorm, .bgra8Unorm_srgb:
        return (0x4247_5241, 4)  // 'BGRA'
      case .rgba16Float:
        return (0x5247_6841, 8)  // 'RGhA'
      default:
        fatalError("Surface presenter cannot present Metal format \(pixelFormat.rawValue)")
      }
    }

    /// The colour space the compositor must read the surface in, serialized
    /// for `IOSurfaceSetValue`.
    ///
    /// Core Animation has no other way to learn it: a plain `CALayer` carries no
    /// colour space of its own, so an extended-range surface left unlabelled is
    /// composited as if its values were display-referred sRGB and an HDR frame
    /// comes out clipped and dark. `kIOSurfaceColorSpace` requires the
    /// serialized form — `CGColorSpaceCopyPropertyList`, per IOSurfaceRef.h —
    /// because every value attached to a surface must be plist-serializable;
    /// handing over the `CGColorSpace` object itself fails every frame with
    /// `typeID 0x49 not serializable` and leaves the surface unlabelled.
    private func colorSpace(for pixelFormat: MTLPixelFormat) -> CFPropertyList {
      let name = pixelFormat == .rgba16Float
        ? CGColorSpace.extendedLinearSRGB : CGColorSpace.sRGB
      guard let space = CGColorSpace(name: name),
        let serialized = space.copyPropertyList()
      else {
        fatalError("Surface presenter could not serialize the surface color space")
      }
      return serialized
    }
  }
#endif
