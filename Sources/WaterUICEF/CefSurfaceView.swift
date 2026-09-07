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
@MainActor
open class CefSurfaceView: NSView {
  public let stretchAxis: WaterUI.WuiStretchAxis = .both

  private let cefState: OpaquePointer

  public init(surface: CWaterUI.WuiCefSurface, env: WuiEnvironment) {
    guard let state = surface.state else {
      fatalError("CEF surface was created without input state")
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

  public func goBack() {
    waterui_cef_surface_go_back(cefState)
  }

  public func goForward() {
    waterui_cef_surface_go_forward(cefState)
  }

  public func executeEditCommand(_ command: CWaterUI.WuiCefEditCommand) {
    waterui_cef_surface_edit(cefState, command)
  }

  // MARK: - Standard Edit Menu Actions

  @objc open func copy(_ sender: Any?) {
    waterui_cef_surface_edit(cefState, WuiCefEditCommand_Copy)
  }

  @objc open func cut(_ sender: Any?) {
    waterui_cef_surface_edit(cefState, WuiCefEditCommand_Cut)
  }

  @objc open func paste(_ sender: Any?) {
    waterui_cef_surface_edit(cefState, WuiCefEditCommand_Paste)
  }

  open override func selectAll(_ sender: Any?) {
    waterui_cef_surface_edit(cefState, WuiCefEditCommand_SelectAll)
  }

  @objc open func undo(_ sender: Any?) {
    waterui_cef_surface_edit(cefState, WuiCefEditCommand_Undo)
  }

  @objc open func redo(_ sender: Any?) {
    waterui_cef_surface_edit(cefState, WuiCefEditCommand_Redo)
  }
}
#endif  // !WATERUI_NO_GPU
