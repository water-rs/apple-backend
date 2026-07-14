import CWaterUI
import QuartzCore

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

@MainActor
final class WuiResolvedGradientView: PlatformView, WuiComponent, WuiGraphicsPrimitiveSizing {
  static var rawId: CWaterUI.WuiTypeId { waterui_resolved_gradient_id() }

  private let gradientLayer = CAGradientLayer()
  private let gradient: WuiResolvedGradient
  private(set) var stretchAxis: WuiStretchAxis

  required init(anyview: OpaquePointer, env: WuiEnvironment) {
    stretchAxis = WuiStretchAxis(waterui_view_stretch_axis(anyview))
    gradient = waterui_force_as_resolved_gradient(anyview)

    super.init(frame: .zero)

    #if canImport(UIKit)
      backgroundColor = .clear
      layer.addSublayer(gradientLayer)
    #elseif canImport(AppKit)
      wantsLayer = true
      layer?.addSublayer(gradientLayer)
    #endif

    configureGradientLayer()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  #if canImport(UIKit)
    override func layoutSubviews() {
      super.layoutSubviews()
      gradientLayer.frame = bounds
    }
  #elseif canImport(AppKit)
    override var isFlipped: Bool { true }

    override func layout() {
      super.layout()
      gradientLayer.frame = bounds
    }
  #endif

  private func configureGradientLayer() {
    let stops = WuiArray<CWaterUI.WuiResolvedGradientStop>(gradient.stops).toArray()
    gradientLayer.colors = stops.map { stop in stop.color.toPlatformCGColor() }
    gradientLayer.locations = stops.map { stop in NSNumber(value: stop.position) }

    switch gradient.gradient_type {
    case WuiGradientType_Linear:
      gradientLayer.type = .axial
      gradientLayer.startPoint = CGPoint(x: CGFloat(gradient.start_x), y: CGFloat(gradient.start_y))
      gradientLayer.endPoint = CGPoint(x: CGFloat(gradient.end_x), y: CGFloat(gradient.end_y))
    case WuiGradientType_Radial:
      gradientLayer.type = .radial
      let center = CGPoint(x: CGFloat(gradient.start_x), y: CGFloat(gradient.start_y))
      gradientLayer.startPoint = center
      gradientLayer.endPoint = CGPoint(
        x: center.x + CGFloat(gradient.end_value),
        y: center.y
      )
    case WuiGradientType_Angular:
      gradientLayer.type = .conic
      gradientLayer.startPoint = CGPoint(x: CGFloat(gradient.start_x), y: CGFloat(gradient.start_y))
      gradientLayer.endPoint = gradientLayer.startPoint
    case WuiGradientType_Mesh:
      fatalError("WaterUI Apple backend received mesh data through ResolvedGradient")
    default:
      fatalError("WaterUI Apple backend received an unknown WuiGradientType")
    }
  }
}

extension WuiResolvedColor {
  fileprivate func toPlatformCGColor() -> CGColor {
    #if canImport(UIKit)
      return toUIColor().cgColor
    #elseif canImport(AppKit)
      return toNSColor().cgColor
    #endif
  }
}
