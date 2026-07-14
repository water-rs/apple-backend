import CWaterUI
import QuartzCore

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

@MainActor
final class WuiResolvedShape: PlatformView, WuiComponent, WuiGraphicsPrimitiveSizing {
  static var rawId: CWaterUI.WuiTypeId { waterui_resolved_shape_id() }

  private let pathCommands: [WuiPathCommand]
  private let shapeLayer = CAShapeLayer()
  private var fillObservation: WuiComputedObservation<WuiResolvedColor>?
  private(set) var stretchAxis: WuiStretchAxis

  required init(anyview: OpaquePointer, env: WuiEnvironment) {
    stretchAxis = WuiStretchAxis(waterui_view_stretch_axis(anyview))

    let shape = waterui_force_as_resolved_shape(anyview)
    pathCommands = WuiShapePath.commands(from: shape.commands)
    guard let fill = shape.fill else {
      fatalError("ResolvedShape fill computed pointer is null")
    }

    super.init(frame: .zero)

    #if canImport(UIKit)
      backgroundColor = .clear
      layer.addSublayer(shapeLayer)
    #elseif canImport(AppKit)
      wantsLayer = true
      layer?.addSublayer(shapeLayer)
    #endif

    let fillObservation = WuiComputedObservation(WuiComputed<WuiResolvedColor>(fill)) {
      [weak self] color, _ in
      self?.applyFill(color)
    }
    self.fillObservation = fillObservation
    applyFill(fillObservation.value)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  #if canImport(UIKit)
    override func layoutSubviews() {
      super.layoutSubviews()
      updateShapeLayer()
    }
  #elseif canImport(AppKit)
    override var isFlipped: Bool { true }

    override func layout() {
      super.layout()
      updateShapeLayer()
    }
  #endif

  private func updateShapeLayer() {
    guard !bounds.isEmpty else { return }
    shapeLayer.frame = bounds
    shapeLayer.path = WuiShapePath.makePath(commands: pathCommands, in: bounds)
  }

  private func applyFill(_ color: WuiResolvedColor) {
    #if canImport(UIKit)
      shapeLayer.fillColor = color.toUIColor().cgColor
    #elseif canImport(AppKit)
      shapeLayer.fillColor = color.toNSColor().cgColor
    #endif
    invalidateCapturedRendering()
  }
}
