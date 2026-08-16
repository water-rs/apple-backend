import CWaterUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

/// Component for Metadata<Border>.
///
/// Applies a border effect to the wrapped view.
@MainActor
final class WuiBorder: PlatformView, WuiComponent {
  static var rawId: CWaterUI.WuiTypeId { waterui_metadata_border_id() }

  private let contentView: any WuiComponent
  private let border: WuiBorder_Struct
  private let borderColor: WuiColor
  private var colorObservation: WuiComputedObservation<WuiResolvedColor>?
  private var borderLayer: CAShapeLayer?

  var stretchAxis: WuiStretchAxis {
    contentView.stretchAxis
  }

  required init(anyview: OpaquePointer, env: WuiEnvironment) {
    let metadata = waterui_force_as_metadata_border(anyview)
    guard let borderColor = metadata.value.color else {
      fatalError("WaterUI border color pointer is null")
    }

    self.contentView = WuiAnyView.resolve(anyview: metadata.content, env: env)
    self.border = metadata.value
    self.borderColor = WuiColor(borderColor)

    super.init(frame: .zero)

    contentView.translatesAutoresizingMaskIntoConstraints = true
    addSubview(contentView)

    configureBorderLayer()
    colorObservation = WuiComputedObservation(self.borderColor.resolve(in: env)) {
      [weak self] color, _ in
      self?.applyBorderColor(color)
    }
    if let color = colorObservation?.value {
      applyBorderColor(color)
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func configureBorderLayer() {
    let edges = border.edges
    let drawsAllEdges = edges.top && edges.leading && edges.bottom && edges.trailing
    #if canImport(UIKit)
      if drawsAllEdges {
        layer.borderWidth = CGFloat(border.width)
        layer.cornerRadius = CGFloat(border.corner_radius)
        layer.masksToBounds = border.corner_radius > 0
      }
    #elseif canImport(AppKit)
      wantsLayer = true
      if drawsAllEdges {
        layer?.borderWidth = CGFloat(border.width)
        layer?.cornerRadius = CGFloat(border.corner_radius)
        layer?.masksToBounds = border.corner_radius > 0
      }
    #endif

    guard !drawsAllEdges else { return }
    let shapeLayer = CAShapeLayer()
    shapeLayer.fillColor = nil
    shapeLayer.lineWidth = CGFloat(border.width)
    shapeLayer.lineCap = .butt
    borderLayer = shapeLayer
    #if canImport(UIKit)
      layer.addSublayer(shapeLayer)
    #elseif canImport(AppKit)
      layer?.addSublayer(shapeLayer)
    #endif
  }

  private func applyBorderColor(_ color: WuiResolvedColor) {
    #if canImport(UIKit)
      let platformColor = color.toUIColor().cgColor
      layer.borderColor = platformColor
    #elseif canImport(AppKit)
      let platformColor = color.toNSColor().cgColor
      layer?.borderColor = platformColor
    #endif
    borderLayer?.strokeColor = platformColor
    invalidateCapturedRendering()
  }

  private func updateBorderPath() {
    guard let shapeLayer = borderLayer else { return }
    let path = CGMutablePath()
    let halfWidth = CGFloat(border.width) / 2
    let rect = bounds.insetBy(dx: halfWidth, dy: halfWidth)
    guard !rect.isEmpty else {
      shapeLayer.path = path
      return
    }
    let radius = min(
      max(CGFloat(border.corner_radius) - halfWidth, 0),
      min(rect.width, rect.height) / 2
    )
    let edges = border.edges

    if edges.top {
      path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
      path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
      if radius > 0 {
        path.addArc(
          center: CGPoint(x: rect.maxX - radius, y: rect.minY + radius),
          radius: radius,
          startAngle: -.pi / 2,
          endAngle: 0,
          clockwise: false
        )
      }
    }
    if edges.trailing {
      path.move(to: CGPoint(x: rect.maxX, y: rect.minY + radius))
      path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
      if radius > 0 {
        path.addArc(
          center: CGPoint(x: rect.maxX - radius, y: rect.maxY - radius),
          radius: radius,
          startAngle: 0,
          endAngle: .pi / 2,
          clockwise: false
        )
      }
    }
    if edges.bottom {
      path.move(to: CGPoint(x: rect.maxX - radius, y: rect.maxY))
      path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
      if radius > 0 {
        path.addArc(
          center: CGPoint(x: rect.minX + radius, y: rect.maxY - radius),
          radius: radius,
          startAngle: .pi / 2,
          endAngle: .pi,
          clockwise: false
        )
      }
    }
    if edges.leading {
      path.move(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
      path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
      if radius > 0 {
        path.addArc(
          center: CGPoint(x: rect.minX + radius, y: rect.minY + radius),
          radius: radius,
          startAngle: .pi,
          endAngle: .pi * 3 / 2,
          clockwise: false
        )
      }
    }

    shapeLayer.path = path
  }

  func layoutPriority() -> Int32 {
    contentView.layoutPriority()
  }

  func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
    contentView.sizeThatFits(proposal)
  }

  #if canImport(UIKit)
    override func layoutSubviews() {
      super.layoutSubviews()
      contentView.frame = bounds
      borderLayer?.frame = bounds
      updateBorderPath()
    }
  #elseif canImport(AppKit)
    nonisolated override var isFlipped: Bool { true }

    override func layout() {
      super.layout()
      contentView.frame = bounds
      borderLayer?.frame = bounds
      updateBorderPath()
    }
  #endif
}

// Type alias for the FFI border struct
private typealias WuiBorder_Struct = CWaterUI.WuiBorder
