// CEF renders into a GPU surface, so a build without WaterUI's `gpu`
// feature has no CEF either; compiled out with the same condition.
#if !WATERUI_NO_GPU
@preconcurrency import AppKit
import CWaterUI
import WaterUI

/// Installs CEF's AppKit integration before `NSApplication.shared` is accessed.
@MainActor
public func prepareWaterUICEFApplication() {
  waterui_cef_prepare_macos_application()
}

/// Shared AppKit host for WaterUI's CEF-backed Chromium and WebView components.
///
/// The page is drawn and driven by WaterUI's generic GPU surface. The view
/// behind `surface.gpu_surface` takes its own input, so the surface host
/// installs its input responder and routes pointer, keyboard, scroll and
/// composition events to Chromium with nothing CEF-specific in between; the
/// viewport and device scale travel with every frame the surface renders. What
/// is left for this class is to fill the box layout gives the page and to keep
/// the semantic view behind it alive for as long as the surface is.
@MainActor
open class CefSurfaceView: NSView {
  public let stretchAxis: WaterUI.WuiStretchAxis = .both

  private let cefState: OpaquePointer

  public init(surface: CWaterUI.WuiCefSurface, env: WuiEnvironment) {
    guard let state = surface.state else {
      fatalError("CEF surface was created without its retained state")
    }
    self.cefState = state
    let gpuView = makeWaterUIGpuSurface(
      stretchAxis: .both,
      ffiSurface: surface.gpu_surface,
      env: env
    )
    super.init(frame: .zero)
    gpuView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(gpuView)
    NSLayoutConstraint.activate([
      gpuView.leadingAnchor.constraint(equalTo: leadingAnchor),
      gpuView.trailingAnchor.constraint(equalTo: trailingAnchor),
      gpuView.topAnchor.constraint(equalTo: topAnchor),
      gpuView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  @available(*, unavailable)
  public required init?(coder: NSCoder) {
    fatalError("CEF surfaces do not support NSCoder initialization")
  }

  @MainActor deinit {
    waterui_cef_surface_drop(cefState)
  }

  open func layoutPriority() -> Int32 { 0 }

  open func sizeThatFits(_ proposal: WaterUI.WuiProposalSize) -> CGSize {
    CGSize(
      width: CGFloat(proposal.width ?? 0),
      height: CGFloat(proposal.height ?? 0)
    )
  }
}
#endif  // !WATERUI_NO_GPU
