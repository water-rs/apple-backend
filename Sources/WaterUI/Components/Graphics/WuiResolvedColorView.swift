import CWaterUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

@MainActor
class WuiColorViewBase: PlatformView, WuiGraphicsPrimitiveSizing {
  private(set) var stretchAxis: WuiStretchAxis

  init(stretchAxis: WuiStretchAxis) {
    self.stretchAxis = stretchAxis
    super.init(frame: .zero)
    #if canImport(AppKit)
      wantsLayer = true
    #endif
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func apply(_ color: WuiResolvedColor) {
    #if canImport(UIKit)
      backgroundColor = color.toUIColor()
    #elseif canImport(AppKit)
      layer?.backgroundColor = color.toNSColor().cgColor
    #endif
    invalidateCapturedRendering()
  }

  #if canImport(AppKit)
    nonisolated override var isFlipped: Bool { true }
  #endif
}

@MainActor
final class WuiColorView: WuiColorViewBase, WuiComponent {
  static var rawId: CWaterUI.WuiTypeId { waterui_color_id() }

  private var observation: WuiComputedObservation<WuiResolvedColor>?

  convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
    let stretchAxis = WuiStretchAxis(waterui_view_stretch_axis(anyview))
    guard let color = waterui_force_as_color(anyview) else {
      fatalError("waterui_force_as_color returned null")
    }
    let resolved = waterui_resolve_color(color, env.inner)
    waterui_drop_color(color)
    guard let resolved else {
      fatalError("waterui_resolve_color returned null")
    }
    self.init(
      stretchAxis: stretchAxis,
      resolved: WuiComputed<WuiResolvedColor>(resolved)
    )
  }

  private init(
    stretchAxis: WuiStretchAxis,
    resolved: WuiComputed<WuiResolvedColor>
  ) {
    super.init(stretchAxis: stretchAxis)
    let observation = WuiComputedObservation(resolved) { [weak self] color, _ in
      self?.apply(color)
    }
    self.observation = observation
    apply(observation.value)
  }

  // periphery:ignore - required by NSCoding; WaterUI never unarchives views
  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}

@MainActor
final class WuiResolvedColorView: WuiColorViewBase, WuiComponent {
  static var rawId: CWaterUI.WuiTypeId { waterui_resolved_color_id() }

  convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
    let stretchAxis = WuiStretchAxis(waterui_view_stretch_axis(anyview))
    self.init(color: waterui_force_as_resolved_color(anyview), stretchAxis: stretchAxis)
  }

  init(color: WuiResolvedColor, stretchAxis: WuiStretchAxis) {
    super.init(stretchAxis: stretchAxis)
    apply(color)
  }

  // periphery:ignore - required by NSCoding; WaterUI never unarchives views
  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}
