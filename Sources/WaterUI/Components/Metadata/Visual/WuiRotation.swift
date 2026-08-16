import CWaterUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
  import QuartzCore
#endif

/// Component for Metadata<Rotation>.
///
/// Applies a rotation transform to the wrapped view around the specified anchor point.
/// Rotations are purely visual and do not affect layout.
@MainActor
final class WuiRotation: PlatformView, WuiComponent {
  static var rawId: CWaterUI.WuiTypeId { waterui_metadata_rotation_id() }

  private let contentView: any WuiComponent
  private var rotationObservation: WuiComputedObservation<Float>?

  // Current transform value
  private var currentRotation: CGFloat = 0.0
  private let anchor: CGPoint
  private var lastBoundsSize: CGSize = .zero

  var stretchAxis: WuiStretchAxis {
    contentView.stretchAxis
  }

  required init(anyview: OpaquePointer, env: WuiEnvironment) {
    let metadata = waterui_force_as_metadata_rotation(anyview)

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

    // Setup watcher for reactive rotation property
    setupWatcher(metadata.value)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupWatcher(_ rotation: WuiRotation_Struct) {
    let observation = WuiComputedObservation(WuiComputed<Float>(rotation.angle)) {
      [weak self] value, metadata in
      guard let self else { return }
      self.currentRotation = CGFloat(value)
      #if canImport(UIKit)
        withPlatformAnimation(metadata) {
          self.applyTransform()
        }
      #elseif canImport(AppKit)
        let animation = parseAnimation(metadata.getAnimation())
        self.applyTransform(animation: animation)
      #endif
    }
    rotationObservation = observation
    currentRotation = CGFloat(observation.value)
    applyTransform()
  }

  private func applyTransform() {
    let radians = currentRotation * .pi / 180.0

    #if canImport(UIKit)
      let transform = CGAffineTransform(rotationAngle: radians)
      contentView.transform = transform

    #elseif canImport(AppKit)
      let layer = transformedContentLayer()
      let transform = CATransform3DMakeRotation(radians, 0, 0, 1)
      wuiSetLayerTransformWithoutImplicitAnimation(layer, transform)
    #endif
    invalidateCapturedRendering()
  }

  #if canImport(AppKit)
    private func applyTransform(animation: Animation) {
      let radians = currentRotation * .pi / 180.0
      let layer = transformedContentLayer()
      let toTransform = CATransform3DMakeRotation(radians, 0, 0, 1)
      wuiApplyLayerTransform(layer, to: toTransform, animation: animation, key: "wuiRotation")
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
        fatalError("WuiRotation content must be layer-backed after transformed layout")
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
      // Set anchorPoint and position for proper rotation pivot
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

// Type alias for the FFI rotation struct
private typealias WuiRotation_Struct = CWaterUI.WuiRotation
