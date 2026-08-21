// CEF renders into a GPU surface, so a build without WaterUI's `gpu`
// feature has no CEF either; compiled out with the same condition.
#if !WATERUI_NO_GPU
import CWaterUI
import Foundation
import WaterUI
import WaterUICEF

@MainActor
private final class CefWebViewComponent: CefSurfaceView, WuiComponent {
  static var rawId: CWaterUI.WuiTypeId {
    waterui_webview_id()
  }

  required init(anyview: OpaquePointer, env: WuiEnvironment) {
    super.init(surface: waterui_force_as_cef_webview(anyview), env: env)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("CefWebViewComponent does not support NSCoder initialization")
  }
}

/// Registers the CEF-backed standard WebView with WaterUI's Apple renderer.
@MainActor
public func installWaterUICefWebView() {
  registerComponent(CefWebViewComponent.self)
}
#endif  // !WATERUI_NO_GPU
