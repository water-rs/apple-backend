import CWaterUI
import CoreGraphics
import Dispatch
import Metal
import OSLog
import QuartzCore

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

#if canImport(UIKit)
  private typealias WuiCaptureDisplay = UIWindowScene
#elseif canImport(AppKit)
  private typealias WuiCaptureDisplay = NSScreen
#endif

@MainActor
private func requireCaptureDisplay() -> WuiCaptureDisplay {
  #if canImport(UIKit)
    for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
      if scene.windows.contains(where: { $0.isKeyWindow }) {
        return scene
      }
    }
    fatalError("ViewRenderer requires a foreground UIWindowScene with a key window")
  #elseif canImport(AppKit)
    guard let screen = NSScreen.main else {
      fatalError("ViewRenderer requires an attached macOS display")
    }
    return screen
  #endif
}

@MainActor
private func captureScale(for display: WuiCaptureDisplay) -> CGFloat {
  #if canImport(UIKit)
    display.screen.scale
  #elseif canImport(AppKit)
    display.backingScaleFactor
  #endif
}

// MARK: - View Renderer Installation

/// Installs the native view renderer into the environment.
///
/// This allows the preview system to capture views as RGBA pixels.
@MainActor
func installViewRenderer(env: OpaquePointer, services: WuiNativeServices) {
  waterui_env_install_view_renderer(
    env,
    retainWuiNativeServices(services),
    renderViewImpl,
    dropWuiNativeServices
  )
}

/// Native implementation of ViewRenderFn.
///
/// Called by Rust to render a view to RGBA pixels.
/// Rust keeps the callback alive until this asynchronous render completes.
private final class WuiViewRenderRequest: @unchecked Sendable {
  let viewPtr: UnsafeMutableRawPointer?
  let size: WuiSize
  let callback: ViewRenderCallback
  let env: WuiEnvironment

  init(
    viewPtr: UnsafeMutableRawPointer?,
    size: WuiSize,
    callback: ViewRenderCallback,
    env: WuiEnvironment
  ) {
    self.viewPtr = viewPtr
    self.size = size
    self.callback = callback
    self.env = env
  }
}

private struct WuiViewRenderInvocation: @unchecked Sendable {
  let context: UnsafeMutableRawPointer?
  let viewPtr: UnsafeMutableRawPointer?
  let size: CWaterUI.WuiSize
  let callback: ViewRenderCallback
}

private let renderViewImpl: ViewRenderFn = { context, viewPtr, size, callback in
  precondition(Thread.isMainThread, "ViewRenderer must be invoked on WaterUI's UI executor")
  let invocation = WuiViewRenderInvocation(
    context: context,
    viewPtr: viewPtr,
    size: size,
    callback: callback
  )
  MainActor.assumeIsolated {
    guard let context = invocation.context else {
      fatalError("ViewRenderer received a null owner context")
    }
    let services = Unmanaged<WuiNativeServices>.fromOpaque(context).takeUnretainedValue()
    guard let env = services.environment else {
      fatalError("ViewRenderer outlived its application environment")
    }
    let request = WuiViewRenderRequest(
      viewPtr: invocation.viewPtr,
      size: WuiSize(width: invocation.size.width, height: invocation.size.height),
      callback: invocation.callback,
      env: env
    )
    Task { @MainActor in
      await renderViewToRGBA(
        viewPtr: request.viewPtr,
        size: request.size,
        callback: request.callback,
        env: request.env
      )
    }
  }
}

/// Renders a view to RGBA pixels and calls the callback.
/// Runs on the main actor because native view creation and layout are UI operations.
@preconcurrency @MainActor
private func renderViewToRGBA(
  viewPtr: UnsafeMutableRawPointer?,
  size: WuiSize,
  callback: ViewRenderCallback,
  env: WuiEnvironment
) async {
  Logger.waterui.info("ViewRenderer: starting render, size=\(size.width)x\(size.height)")

  guard let complete = callback.call else {
    fatalError("ViewRenderer received a callback without a completion function")
  }

  guard let viewPtr else {
    fatalError("ViewRenderer received a null view pointer")
  }

  // Cast the pointer to AnyView opaque pointer
  let anyviewPtr = OpaquePointer(viewPtr)

  // Create the native view from the AnyView
  let view = WuiAnyView(anyview: anyviewPtr, env: env)

  Logger.waterui.info("ViewRenderer: WuiAnyView created, subviews=\(view.subviews.count)")

  let display = requireCaptureDisplay()
  let scale = captureScale(for: display)
  #if canImport(UIKit)
    let dynamicRange = resolveDynamicRange(for: display.screen)
  #elseif canImport(AppKit)
    let dynamicRange = resolveDynamicRange(for: display)
  #endif

  // Proposed size (max bounds for layout)
  let proposedSize = CGSize(width: CGFloat(size.width), height: CGFloat(size.height))

  guard let backgroundSignal = waterui_theme_color(env.inner, WuiColorSlot_Background) else {
    fatalError("ViewRenderer requires the theme Background color")
  }
  let background = WuiComputed<WuiResolvedColor>(backgroundSignal).value

  // Render the view to RGBA, getting actual content size
  let (rgbaData, actualWidth, actualHeight) = await captureViewToRGBA(
    view: view,
    proposedSize: proposedSize,
    display: display,
    scale: scale,
    dynamicRange: dynamicRange,
    background: background
  )
  rgbaData.withUnsafeBytes { buffer in
    guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
      fatalError("ViewRenderer produced an empty pixel buffer for a non-empty image")
    }
    complete(
      callback.data,
      ptr,
      UInt(buffer.count),
      UInt32(actualWidth),
      UInt32(actualHeight)
    )
  }
}

@preconcurrency @MainActor
private func withPreviewGpuSurfaceCaptureMode<T>(
  in view: PlatformView,
  _ body: () async -> T
) async -> T {
  let surfaces = collectPreviewGpuSurfaces(in: view)
  for surface in surfaces {
    surface.beginExternalRendering()
    surface.beginCaptureSuppression()
  }
  defer {
    for surface in surfaces.reversed() {
      surface.endCaptureSuppression()
      surface.endExternalRendering(resumingPresentation: false)
    }
  }
  return await body()
}

@preconcurrency @MainActor
private func collectPreviewGpuSurfaces(in view: PlatformView) -> [WuiGpuSurface] {
  var surfaces: [WuiGpuSurface] = []
  collectPreviewGpuSurfaces(in: view, into: &surfaces)
  return surfaces
}

@preconcurrency @MainActor
private func collectPreviewGpuSurfaces(
  in view: PlatformView,
  into surfaces: inout [WuiGpuSurface]
) {
  if let surface = view as? WuiGpuSurface {
    surfaces.append(surface)
  }
  for subview in view.subviews {
    collectPreviewGpuSurfaces(in: subview, into: &surfaces)
  }
}

@preconcurrency @MainActor
private func renderPreviewGpuSurfaceFirstFrames(in view: PlatformView, scale: CGFloat) async {
  for surface in collectPreviewGpuSurfaces(in: view) {
    let pixelWidth = UInt32(surface.bounds.width * scale)
    let pixelHeight = UInt32(surface.bounds.height * scale)
    if pixelWidth > 0, pixelHeight > 0 {
      _ = await surface.renderExternalTexture(width: pixelWidth, height: pixelHeight)
    }
  }
}

/// Renders a view into a template image, for chrome that takes an image, not a view.
///
/// A tab bar item is an image beside a title, so an icon that is a view has to
/// become one. The view goes through the same offscreen capture the preview
/// renderer uses, which is what makes a `WaterUI` icon work at all: icons are
/// SVG, an SVG is a scene on a Metal surface, and a Metal surface draws nothing
/// into `cacheDisplay`. Only this path attaches the view to a window, drives its
/// first frame and composites the surface.
///
/// The result is a template image so the bar keeps tinting it with its own
/// selection colour.
@preconcurrency @MainActor
func renderViewToTemplateImage(
  _ view: WuiAnyView,
  maxSide: CGFloat
) async -> PlatformImage? {
  let display = requireCaptureDisplay()
  let scale = captureScale(for: display)
  #if canImport(UIKit)
    let dynamicRange = resolveDynamicRange(for: display.screen)
  #elseif canImport(AppKit)
    let dynamicRange = resolveDynamicRange(for: display)
  #endif

  // Transparent, so only the icon itself lands in the image.
  let background = WuiResolvedColor(red: 0, green: 0, blue: 0, opacity: 0, headroom: 1)
  let (rgba, width, height) = await captureViewToRGBA(
    view: view,
    proposedSize: CGSize(width: maxSide, height: maxSide),
    display: display,
    scale: scale,
    dynamicRange: dynamicRange,
    background: background
  )
  guard width > 0, height > 0 else { return nil }

  let provider: CGDataProvider? = rgba.withUnsafeBytes { buffer in
    guard let base = buffer.baseAddress else { return nil }
    return CGDataProvider(data: Data(bytes: base, count: buffer.count) as CFData)
  }
  guard
    let provider,
    let cgImage = CGImage(
      width: width,
      height: height,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider,
      decode: nil,
      shouldInterpolate: true,
      intent: .defaultIntent
    )
  else { return nil }

  let pointSize = CGSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale)
  #if canImport(UIKit)
    return UIImage(cgImage: cgImage, scale: scale, orientation: .up)
      .withRenderingMode(.alwaysTemplate)
  #elseif canImport(AppKit)
    let image = NSImage(cgImage: cgImage, size: pointSize)
    image.isTemplate = true
    return image
  #endif
}

/// Captures a view to RGBA pixel data.
/// Returns the data along with actual pixel dimensions (width, height).
@preconcurrency @MainActor
private func captureViewToRGBA(
  view: WuiAnyView,
  proposedSize: CGSize,
  display: WuiCaptureDisplay,
  scale: CGFloat,
  dynamicRange: WuiDynamicRangeMode,
  background: WuiResolvedColor
) async -> (Data, Int, Int) {
  precondition(
    proposedSize.width.isFinite && proposedSize.width > 0
      && proposedSize.height.isFinite && proposedSize.height > 0,
    "ViewRenderer requires a finite, non-zero proposed size"
  )
  precondition(scale.isFinite && scale > 0, "ViewRenderer requires a positive display scale")

  // Measure with the proposed size so stretchable views render correctly.
  #if canImport(UIKit)
    let measuredSize = view.sizeThatFits(proposedSize)
  #elseif canImport(AppKit)
    view.frame = CGRect(origin: .zero, size: proposedSize)
    view.layoutSubtreeIfNeeded()
    let measuredSize = view.fittingSize
  #endif

  func resolvedDimension(_ measured: CGFloat, proposed: CGFloat) -> CGFloat {
    if measured.isFinite, measured > 0, measured != PlatformView.noIntrinsicMetric {
      return measured
    }
    return proposed
  }

  let actualSize = CGSize(
    width: resolvedDimension(measuredSize.width, proposed: proposedSize.width),
    height: resolvedDimension(measuredSize.height, proposed: proposedSize.height)
  )

  // Layout the view at actual content size
  view.frame = CGRect(origin: .zero, size: actualSize)

  #if canImport(UIKit)
    view.setNeedsLayout()
    view.layoutIfNeeded()
  #elseif canImport(AppKit)
    view.needsLayout = true
    view.layoutSubtreeIfNeeded()
  #endif

  Logger.waterui.info(
    "ViewRenderer: proposedSize=\(proposedSize.width)x\(proposedSize.height), measuredSize=\(measuredSize.width)x\(measuredSize.height), actualSize=\(actualSize.width)x\(actualSize.height)"
  )

  // Calculate pixel dimensions
  let width = Int(ceil(actualSize.width * scale))
  let height = Int(ceil(actualSize.height * scale))

  // Create RGBA bitmap context at actual content size
  let bytesPerPixel = 4
  let bytesPerRow = width * bytesPerPixel
  var pixelData = Data(count: width * height * bytesPerPixel)

  let colorSpace = CGColorSpaceCreateDeviceRGB()
  let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

  guard
    let context = pixelData.withUnsafeMutableBytes({ buffer -> CGContext? in
      CGContext(
        data: buffer.baseAddress,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: bitmapInfo.rawValue
      )
    })
  else {
    fatalError("ViewRenderer failed to create its RGBA bitmap context")
  }

  // Scale context for retina
  context.scaleBy(x: scale, y: scale)
  #if canImport(UIKit)
    context.setFillColor(background.toUIColor().cgColor)
  #elseif canImport(AppKit)
    context.setFillColor(background.toNSColor().cgColor)
  #endif
  context.fill(CGRect(origin: .zero, size: actualSize))

  #if canImport(UIKit)
    let tempWindow = UIWindow(windowScene: display)
    tempWindow.frame = CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: actualSize)
    let viewController = UIViewController()
    viewController.view.frame = tempWindow.bounds
    applyDynamicRange(dynamicRange, to: viewController.view)
    viewController.view.addSubview(view)
    tempWindow.rootViewController = viewController
    tempWindow.isHidden = false
    tempWindow.layoutIfNeeded()
    view.layoutIfNeeded()

    await withPreviewGpuSurfaceCaptureMode(in: view) {
      await renderPreviewGpuSurfaceFirstFrames(in: view, scale: scale)
      await view.ready()

      context.saveGState()
      context.translateBy(x: 0, y: actualSize.height)
      context.scaleBy(x: 1, y: -1)

      UIGraphicsPushContext(context)
      view.layer.render(in: context)
      UIGraphicsPopContext()
      context.restoreGState()

      context.saveGState()
      context.setBlendMode(.destinationOver)
      await captureGpuSurfaces(in: view, rootView: view, to: context, scale: scale)
      context.restoreGState()
    }
    tempWindow.isHidden = true

  #elseif canImport(AppKit)
    // AppKit rendering - headless capture using cacheDisplay

    // Resize view to actual content size
    view.frame = CGRect(origin: .zero, size: actualSize)
    view.layoutSubtreeIfNeeded()

    // Create an offscreen window (positioned far offscreen for headless rendering)
    let tempWindow = NSWindow(
      contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: actualSize),
      styleMask: .borderless,
      backing: .buffered,
      defer: false
    )
    tempWindow.backgroundColor = background.toNSColor()
    tempWindow.isReleasedWhenClosed = false

    let captureRoot = NSView(frame: NSRect(origin: .zero, size: actualSize))
    applyDynamicRange(dynamicRange, to: captureRoot)
    let captureContent = NSView(frame: captureRoot.bounds)
    captureRoot.addSubview(captureContent)
    captureContent.addSubview(view)
    tempWindow.contentView = captureRoot

    // Force layer-backing for proper rendering
    view.wantsLayer = true

    // Force layout
    view.layoutSubtreeIfNeeded()

    // Display window (offscreen) to trigger rendering and attach GPU surfaces.
    tempWindow.orderFrontRegardless()
    tempWindow.display()
    forceTextFieldsToDisplay(in: view)
    await withPreviewGpuSurfaceCaptureMode(in: view) {
      await renderPreviewGpuSurfaceFirstFrames(in: view, scale: scale)
      await view.ready()

      // Capture using cacheDisplay for text rendering
      if let bitmapRep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: bitmapRep)
        if let textImage = bitmapRep.cgImage {
          context.draw(textImage, in: CGRect(origin: .zero, size: actualSize))
        }
      }

      // Draw GPU surfaces behind AppKit-rendered content
      context.saveGState()
      context.setBlendMode(.destinationOver)
      await captureGpuSurfaces(in: view, to: context, rootBounds: view.bounds, scale: scale)
      context.restoreGState()
    }
    tempWindow.orderOut(nil)
  #endif

  return (pixelData, width, height)
}

#if canImport(UIKit)
  /// Recursively finds and captures all GPU surfaces in the view hierarchy.
  @preconcurrency @MainActor
  private func captureGpuSurfaces(
    in view: UIView,
    rootView: UIView,
    to context: CGContext,
    scale: CGFloat
  ) async {
    if let gpuSurface = view as? WuiGpuSurface {
      let frameInRoot = view.convert(view.bounds, to: rootView)

      let pixelWidth = UInt32(frameInRoot.width * scale)
      let pixelHeight = UInt32(frameInRoot.height * scale)

      if pixelWidth > 0 && pixelHeight > 0 {
        let drawRect = CGRect(
          x: frameInRoot.origin.x,
          y: frameInRoot.origin.y,
          width: frameInRoot.width,
          height: frameInRoot.height
        )

        await drawGpuSurface(
          gpuSurface: gpuSurface,
          pixelWidth: pixelWidth,
          pixelHeight: pixelHeight,
          drawRect: drawRect,
          context: context
        )
      } else {
        Logger.waterui.info("ViewRenderer: GPU surface has zero size, skipping")
      }
    }

    for subview in view.subviews {
      await captureGpuSurfaces(in: subview, rootView: rootView, to: context, scale: scale)
    }
  }
#endif

#if canImport(AppKit)
  /// Recursively finds and captures all GPU surfaces in the view hierarchy.
  @preconcurrency @MainActor
  private func captureGpuSurfaces(
    in view: NSView,
    to context: CGContext,
    rootBounds: NSRect,
    scale: CGFloat
  ) async {
    // Check if this view is a WuiGpuSurface
    if let gpuSurface = view as? WuiGpuSurface {
      // Get the frame in root view coordinates
      let frameInRoot = view.convert(view.bounds, to: view.window?.contentView)

      // Get pixel dimensions
      let pixelWidth = UInt32(frameInRoot.width * scale)
      let pixelHeight = UInt32(frameInRoot.height * scale)

      if pixelWidth > 0 && pixelHeight > 0 {
        let drawRect = CGRect(
          x: frameInRoot.origin.x,
          y: rootBounds.height - frameInRoot.origin.y - frameInRoot.height,
          width: frameInRoot.width,
          height: frameInRoot.height
        )

        await drawGpuSurface(
          gpuSurface: gpuSurface,
          pixelWidth: pixelWidth,
          pixelHeight: pixelHeight,
          drawRect: drawRect,
          context: context
        )

        Logger.waterui.info(
          "ViewRenderer: captured GPU surface \(pixelWidth)x\(pixelHeight) at \(NSStringFromRect(frameInRoot))"
        )
      } else {
        Logger.waterui.info("ViewRenderer: GPU surface has zero size, skipping")
      }
    }

    // Recursively process subviews
    for subview in view.subviews {
      await captureGpuSurfaces(
        in: subview,
        to: context,
        rootBounds: rootBounds,
        scale: scale
      )
    }
  }

#endif

/// Draw a GPU surface into the given context.
@MainActor
private func drawGpuSurface(
  gpuSurface: WuiGpuSurface,
  pixelWidth: UInt32,
  pixelHeight: UInt32,
  drawRect: CGRect,
  context: CGContext
) async {
  let captureTexture = await gpuSurface.renderExternalTexture(
    width: pixelWidth,
    height: pixelHeight
  )
  let pixelFormat = captureTexture.pixelFormat

  var pixelBytes = [UInt8](repeating: 0, count: Int(pixelWidth) * Int(pixelHeight) * 4)
  switch pixelFormat {
  case .rgba16Float:
    let bytesPerRow = Int(pixelWidth) * MemoryLayout<UInt16>.stride * 4
    var floatPixels = [UInt16](
      repeating: 0,
      count: Int(pixelWidth) * Int(pixelHeight) * 4
    )
    captureTexture.getBytes(
      &floatPixels,
      bytesPerRow: bytesPerRow,
      from: MTLRegionMake2D(0, 0, Int(pixelWidth), Int(pixelHeight)),
      mipmapLevel: 0
    )
    for index in 0..<(Int(pixelWidth) * Int(pixelHeight)) {
      for channel in 0..<4 {
        let value = Float(Float16(bitPattern: floatPixels[index * 4 + channel]))
        pixelBytes[index * 4 + channel] = UInt8(clamping: Int(value * 255))
      }
    }
  case .bgra8Unorm, .bgra8Unorm_srgb:
    let bytesPerRow = Int(pixelWidth) * 4
    var bgraPixels = [UInt8](
      repeating: 0,
      count: Int(pixelWidth) * Int(pixelHeight) * 4
    )
    captureTexture.getBytes(
      &bgraPixels,
      bytesPerRow: bytesPerRow,
      from: MTLRegionMake2D(0, 0, Int(pixelWidth), Int(pixelHeight)),
      mipmapLevel: 0
    )
    for index in 0..<(Int(pixelWidth) * Int(pixelHeight)) {
      pixelBytes[index * 4] = bgraPixels[index * 4 + 2]
      pixelBytes[index * 4 + 1] = bgraPixels[index * 4 + 1]
      pixelBytes[index * 4 + 2] = bgraPixels[index * 4]
      pixelBytes[index * 4 + 3] = bgraPixels[index * 4 + 3]
    }
  default:
    fatalError("ViewRenderer cannot read Metal pixel format \(pixelFormat.rawValue)")
  }

  let bytesPerRow = Int(pixelWidth) * 4
  let colorSpace = CGColorSpaceCreateDeviceRGB()
  guard let dataProvider = CGDataProvider(data: Data(pixelBytes) as CFData) else {
    fatalError("ViewRenderer failed to create the GPU capture data provider")
  }
  guard
    let cgImage = CGImage(
      width: Int(pixelWidth),
      height: Int(pixelHeight),
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: bytesPerRow,
      space: colorSpace,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: dataProvider,
      decode: nil,
      shouldInterpolate: true,
      intent: .defaultIntent
    )
  else {
    fatalError("ViewRenderer failed to create the GPU capture image")
  }
  context.saveGState()
  context.draw(cgImage, in: drawRect)
  context.restoreGState()
}

#if canImport(AppKit)
  /// Ensure text fields render their content before capturing.
  @preconcurrency @MainActor
  private func forceTextFieldsToDisplay(in view: NSView) {
    if let textField = view as? NSTextField {
      textField.needsDisplay = true
      textField.displayIfNeeded()
    }

    for subview in view.subviews {
      forceTextFieldsToDisplay(in: subview)
    }
  }
#endif
