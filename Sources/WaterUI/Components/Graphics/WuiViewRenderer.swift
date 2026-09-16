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

#if canImport(UIKit)
  /// Capture windows never appear on a display, so the device safe area
  /// (notch, home indicator) does not apply. Reporting `.zero` keeps a
  /// snapshot view smaller than those insets from seeing a negative
  /// safe-area rect.
  private final class WuiCaptureWindow: UIWindow {
    override var safeAreaInsets: UIEdgeInsets { .zero }
  }
#endif

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

  // Layout the view at actual content size. The render boundary's offer is
  // the proposed size the view was measured under — delivered so a container
  // subtree does not infer a different proposal from the stamped frame.
  view.setPlacementProposal(WuiProposalSize(size: proposedSize))
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
    let tempWindow = WuiCaptureWindow(windowScene: display)
    tempWindow.frame = CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: actualSize)
    let viewController = UIViewController()
    viewController.view.frame = tempWindow.bounds
    applyDynamicRange(dynamicRange, to: viewController.view)
    viewController.view.addSubview(view)
    tempWindow.rootViewController = viewController
    tempWindow.isHidden = false
    tempWindow.layoutIfNeeded()
    view.layoutIfNeeded()

    // A GPU surface presents through an `IOSurface` on its layer's `contents`,
    // which `layer.render(in:)` draws like any other layer content — so waiting
    // for the first frame to be presented is the whole of it, and the surfaces
    // land in their real place in the tree rather than behind everything.
    await view.ready()

    context.saveGState()
    context.translateBy(x: 0, y: actualSize.height)
    context.scaleBy(x: 1, y: -1)

    UIGraphicsPushContext(context)
    view.layer.render(in: context)
    UIGraphicsPopContext()
    context.restoreGState()
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
    // A GPU surface presents through an `IOSurface` on its layer's `contents`,
    // which `cacheDisplay(in:to:)` draws like any other layer content — so
    // waiting for the first frame to be presented is the whole of it, and the
    // surfaces land in their real place in the tree rather than behind
    // everything, which is all the old `.destinationOver` pass could manage.
    await view.ready()

    if let bitmapRep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
      view.cacheDisplay(in: view.bounds, to: bitmapRep)
      if let textImage = bitmapRep.cgImage {
        context.draw(textImage, in: CGRect(origin: .zero, size: actualSize))
      }
    }
    tempWindow.orderOut(nil)
  #endif

  return (pixelData, width, height)
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
