import CWaterUI
import Foundation
import WaterUI
import WaterUICEF

@MainActor
private final class ChromiumComponent: CefSurfaceView, WuiComponent {
  static var rawId: CWaterUI.WuiTypeId {
    waterui_chromium_id()
  }

  required init(anyview: OpaquePointer, env: WuiEnvironment) {
    super.init(surface: waterui_force_as_chromium(anyview), env: env)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("ChromiumComponent does not support NSCoder initialization")
  }
}

/// Registers the independent Chromium component with WaterUI's Apple renderer.
@MainActor
public func installWaterUIChromium() {
  registerComponent(ChromiumComponent.self)
}
