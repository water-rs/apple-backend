import CWaterUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
  import QuartzCore
#endif

/// Component for Metadata<Scale>.
///
/// Applies a scale transform to the wrapped view around the specified anchor point.
/// Scales are purely visual and do not affect layout.
@MainActor
final class WuiScale: PlatformView, WuiComponent {
  static var rawId: CWaterUI.WuiTypeId { waterui_metadata_scale_id() }

  private let contentView: any WuiComponent
  private var scaleXObservation: WuiComputedObservation<Float>?
  private var scaleYObservation: WuiComputedObservation<Float>?

  // Current transform values
  private var currentScaleX: CGFloat = 1.0
  private var currentScaleY: CGFloat = 1.0
  private let anchor: CGPoint
  private var lastBoundsSize: CGSize = .zero

  var stretchAxis: WuiStretchAxis {
    contentView.stretchAxis
  }

  required init(anyview: OpaquePointer, env: WuiEnvironment) {
    let metadata = waterui_force_as_metadata_scale(anyview)

    // Convert anchor from normalized (0-1) to CGPoint
    self.anchor = CGPoint(
      x: CGFloat(metadata.value.anchor.x),
      y: CGFloat(metadata.value.anchor.y)
    )

    // Resolve the content
    self.contentView = WuiAnyView.resolve(anyview: metadata.content, env: env)

    super.init(frame: .zero)

    // Enable layer for transforms
    #if canImport(AppKit)
      wantsLayer = true
      contentView.wantsLayer = true
    #endif

    contentView.translatesAutoresizingMaskIntoConstraints = true
    addSubview(contentView)

    // Setup watchers for reactive transform properties
    setupWatchers(metadata.value)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupWatchers(_ scale: WuiScale_Struct) {
    let xObservation = WuiComputedObservation(WuiComputed<Float>(scale.x)) {
      [weak self] value, metadata in
      guard let self else { return }
      self.currentScaleX = CGFloat(value)
      #if canImport(UIKit)
        withPlatformAnimation(metadata) {
          self.applyTransform()
        }
      #elseif canImport(AppKit)
        let animation = parseAnimation(metadata.getAnimation())
        self.applyTransform(animation: animation)
      #endif
    }

    let yObservation = WuiComputedObservation(WuiComputed<Float>(scale.y)) {
      [weak self] value, metadata in
      guard let self else { return }
      self.currentScaleY = CGFloat(value)
      #if canImport(UIKit)
        withPlatformAnimation(metadata) {
          self.applyTransform()
        }
      #elseif canImport(AppKit)
        let animation = parseAnimation(metadata.getAnimation())
        self.applyTransform(animation: animation)
      #endif
    }
    scaleXObservation = xObservation
    scaleYObservation = yObservation
    currentScaleX = CGFloat(xObservation.value)
    currentScaleY = CGFloat(yObservation.value)
    applyTransform()
  }

  private func applyTransform() {
    #if canImport(UIKit)
      let transform = CGAffineTransform(scaleX: currentScaleX, y: currentScaleY)
      contentView.transform = transform
    #elseif canImport(AppKit)
      let layer = transformedContentLayer()
      let transform = CATransform3DMakeScale(currentScaleX, currentScaleY, 1.0)
      wuiSetLayerTransformWithoutImplicitAnimation(layer, transform)
    #endif
    invalidateCapturedRendering()
  }

  #if canImport(AppKit)
    private func applyTransform(animation: Animation) {
      let layer = transformedContentLayer()
      let toTransform = CATransform3DMakeScale(currentScaleX, currentScaleY, 1.0)
      wuiApplyLayerTransform(layer, to: toTransform, animation: animation, key: "wuiScale")
      invalidateCapturedRendering()
    }

    private func transformedContentLayer() -> CALayer {
      wuiLayoutTransformedContent(
        contentView,
        in: bounds,
        anchor: anchor,
        lastBoundsSize: &lastBoundsSize
      )
      guard let layer = contentView.layer else {
        fatalError("WuiScale content must be layer-backed after transformed layout")
      }
      return layer
    }
  #endif

  func layoutPriority() -> Int32 {
    contentView.layoutPriority()
  }

  func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
    // Transform doesn't affect layout size
    contentView.sizeThatFits(proposal)
  }

  #if canImport(UIKit)
    override func layoutSubviews() {
      super.layoutSubviews()
      // Set anchorPoint and position for proper scale pivot
      contentView.layer.anchorPoint = anchor
      contentView.bounds = CGRect(origin: .zero, size: bounds.size)
      contentView.center = CGPoint(
        x: bounds.width * anchor.x,
        y: bounds.height * anchor.y
      )
    }
  #elseif canImport(AppKit)
    nonisolated override var isFlipped: Bool { true }

    override func layout() {
      super.layout()

      if wuiLayoutTransformedContent(
        contentView,
        in: bounds,
        anchor: anchor,
        lastBoundsSize: &lastBoundsSize
      ) {
        applyTransform()
      }
    }
  #endif
}

// Type alias for the FFI scale struct
private typealias WuiScale_Struct = CWaterUI.WuiScale
