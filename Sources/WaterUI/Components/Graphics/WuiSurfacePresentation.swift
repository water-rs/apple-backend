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

    private let device: MTLDevice
    private let layer: CALayer
    private var buffers: [Buffer] = []
    private var nextIndex = 0
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

    /// The format the current buffers carry, or `.invalid` before the first size.
    var currentPixelFormat: MTLPixelFormat { pixelFormat }

    /// Whether buffers exist for exactly this size and format.
    func matches(width: Int, height: Int, pixelFormat: MTLPixelFormat) -> Bool {
      !buffers.isEmpty && self.width == width && self.height == height
        && self.pixelFormat == pixelFormat
    }

    /// Makes the buffer pair for a size and format, replacing any earlier pair.
    ///
    /// Nothing is reused across a resize: an `IOSurface` is fixed at its
    /// creation size, and a half-sized frame shown scaled is worse than a frame
    /// not shown at all.
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
      setContents(nil)
    }

    /// The texture the next frame renders into: the one not being shown.
    func nextTexture() -> MTLTexture? {
      guard !buffers.isEmpty else { return nil }
      return buffers[nextIndex].texture
    }

    /// Shows the frame just rendered into `nextTexture()` and rotates the pair.
    ///
    /// Call this only from the completion of that frame's fence. Showing a
    /// surface the GPU is still writing composites a half-drawn frame.
    func presentRenderedTexture() {
      guard !buffers.isEmpty else { return }
      setContents(buffers[nextIndex].surface)
      nextIndex = (nextIndex + 1) % buffers.count
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

    /// The colour space the compositor must read the surface in.
    ///
    /// Core Animation has no other way to learn it: a plain `CALayer` carries no
    /// colour space of its own, so an extended-range surface left unlabelled is
    /// composited as if its values were display-referred sRGB and an HDR frame
    /// comes out clipped and dark.
    private func colorSpace(for pixelFormat: MTLPixelFormat) -> CGColorSpace {
      switch pixelFormat {
      case .rgba16Float:
        guard let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else {
          fatalError("Surface presenter could not create the extended linear sRGB color space")
        }
        return space
      default:
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else {
          fatalError("Surface presenter could not create the sRGB color space")
        }
        return space
      }
    }
  }
#endif
