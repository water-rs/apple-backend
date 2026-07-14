import CWaterUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

/// Component for Metadata<Opacity>.
///
/// Applies compositor opacity to the wrapped view hierarchy.
@MainActor
final class WuiOpacity: PlatformView, WuiComponent {
  static var rawId: CWaterUI.WuiTypeId { waterui_metadata_opacity_id() }

  private let contentView: any WuiComponent
  private var opacityObservation: WuiComputedObservation<Float>?

  var stretchAxis: WuiStretchAxis {
    contentView.stretchAxis
  }

  required init(anyview: OpaquePointer, env: WuiEnvironment) {
    let metadata = waterui_force_as_metadata_opacity(anyview)
    self.contentView = WuiAnyView.resolve(anyview: metadata.content, env: env)

    super.init(frame: .zero)

    contentView.translatesAutoresizingMaskIntoConstraints = true
    addSubview(contentView)
    setupWatcher(metadata.value)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupWatcher(_ opacity: WuiOpacity_Struct) {
    let observation = WuiComputedObservation(WuiComputed<Float>(opacity.value)) {
      [weak self] nextValue, metadata in
      guard let self else { return }
      withPlatformAnimation(metadata) {
        self.applyOpacity(nextValue)
      }
    }
    opacityObservation = observation
    applyOpacity(observation.value)
  }

  private func applyOpacity(_ alpha: Float) {
    precondition(
      (0.0...1.0).contains(alpha),
      "Metadata<Opacity> value out of range: \(alpha)"
    )

    #if canImport(UIKit)
      self.alpha = CGFloat(alpha)
    #elseif canImport(AppKit)
      self.alphaValue = CGFloat(alpha)
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

private typealias WuiOpacity_Struct = CWaterUI.WuiOpacity
