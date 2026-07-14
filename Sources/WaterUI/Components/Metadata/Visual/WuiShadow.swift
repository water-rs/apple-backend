import CWaterUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

/// Component for Metadata<Shadow>.
///
/// Applies a shadow effect to the wrapped view.
@MainActor
final class WuiShadow: PlatformView, WuiComponent {
  static var rawId: CWaterUI.WuiTypeId { waterui_metadata_shadow_id() }

  private let contentView: any WuiComponent
  private let shadowStyle: WuiShadow_Struct
  private let shadowColor: WuiColor
  private var colorObservation: WuiComputedObservation<WuiResolvedColor>?

  var stretchAxis: WuiStretchAxis {
    contentView.stretchAxis
  }

  required init(anyview: OpaquePointer, env: WuiEnvironment) {
    let metadata = waterui_force_as_metadata_shadow(anyview)
    guard let shadowColor = metadata.value.color else {
      fatalError("WaterUI shadow color pointer is null")
    }

    self.contentView = WuiAnyView.resolve(anyview: metadata.content, env: env)
    self.shadowStyle = metadata.value
    self.shadowColor = WuiColor(shadowColor)

    super.init(frame: .zero)

    contentView.translatesAutoresizingMaskIntoConstraints = true
    addSubview(contentView)

    configureShadow()
    colorObservation = WuiComputedObservation(self.shadowColor.resolve(in: env)) {
      [weak self] color, _ in
      self?.applyShadowColor(color)
    }
    if let color = colorObservation?.value {
      applyShadowColor(color)
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func configureShadow() {
    #if canImport(UIKit)
      layer.shadowOffset = CGSize(
        width: CGFloat(shadowStyle.offset_x), height: CGFloat(shadowStyle.offset_y))
      layer.shadowRadius = CGFloat(shadowStyle.radius)
      layer.masksToBounds = false
    #elseif canImport(AppKit)
      wantsLayer = true
      layer?.shadowOffset = CGSize(
        width: CGFloat(shadowStyle.offset_x), height: CGFloat(shadowStyle.offset_y))
      layer?.shadowRadius = CGFloat(shadowStyle.radius)
      layer?.masksToBounds = false
    #endif
  }

  private func applyShadowColor(_ color: WuiResolvedColor) {
    #if canImport(UIKit)
      layer.shadowColor = color.toUIColor().withAlphaComponent(1).cgColor
      layer.shadowOpacity = color.opacity
    #elseif canImport(AppKit)
      layer?.shadowColor = color.toNSColor().withAlphaComponent(1).cgColor
      layer?.shadowOpacity = color.opacity
    #endif
    invalidateCapturedRendering()
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
    }
  #elseif canImport(AppKit)
    override var isFlipped: Bool { true }

    override func layout() {
      super.layout()
      contentView.frame = bounds
    }
  #endif
}

// Type alias for the FFI shadow struct
private typealias WuiShadow_Struct = CWaterUI.WuiShadow
