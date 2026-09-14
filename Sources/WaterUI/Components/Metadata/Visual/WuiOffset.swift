import CWaterUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

/// Component for Metadata<Offset>.
///
/// Applies a translation (offset) transform to the wrapped view.
/// Offsets are purely visual and do not affect layout.
@MainActor
final class WuiOffset: PlatformView, WuiComponent {
  static var rawId: CWaterUI.WuiTypeId { waterui_metadata_offset_id() }

  private let contentView: any WuiComponent
  private var offsetXObservation: WuiComputedObservation<Float>?
  private var offsetYObservation: WuiComputedObservation<Float>?

  // Current transform values
  private var currentOffsetX: CGFloat = 0.0
  private var currentOffsetY: CGFloat = 0.0

  var stretchAxis: WuiStretchAxis {
    contentView.stretchAxis
  }

  required init(anyview: OpaquePointer, env: WuiEnvironment) {
    let metadata = waterui_force_as_metadata_offset(anyview)

    // Resolve the content
    self.contentView = WuiAnyView.resolve(anyview: metadata.content, env: env)

    super.init(frame: .zero)

    // A layer keeps the offset content composited rather than redrawn.
    #if canImport(AppKit)
      wantsLayer = true
    #endif

    contentView.translatesAutoresizingMaskIntoConstraints = true
    addSubview(contentView)

    // Setup watchers for reactive offset properties
    setupWatchers(metadata.value)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupWatchers(_ offset: WuiOffset_Struct) {
    let xObservation = WuiComputedObservation(WuiComputed<Float>(offset.x)) {
      [weak self] value, metadata in
      guard let self else { return }
      self.currentOffsetX = CGFloat(value)
      withPlatformAnimation(metadata) {
        self.applyTransform()
      }
    }

    let yObservation = WuiComputedObservation(WuiComputed<Float>(offset.y)) {
      [weak self] value, metadata in
      guard let self else { return }
      self.currentOffsetY = CGFloat(value)
      withPlatformAnimation(metadata) {
        self.applyTransform()
      }
    }
    offsetXObservation = xObservation
    offsetYObservation = yObservation
    currentOffsetX = CGFloat(xObservation.value)
    currentOffsetY = CGFloat(yObservation.value)
    applyTransform()
  }

  private func applyTransform() {
    #if canImport(UIKit)
      // UIKit: Simple translation transform
      contentView.transform = CGAffineTransform(translationX: currentOffsetX, y: currentOffsetY)

    #elseif canImport(AppKit)
      // AppKit owns the geometry of a layer-backed view's layer and rewrites it
      // whenever the view is laid out, so a transform set on the layer does
      // not survive the next layout pass. Moving the content's frame inside
      // this view is the translation that does: this view keeps its own
      // frame, so the offset stays purely visual, and `NSAnimationContext`
      // animates the frame change implicitly.
      contentView.frame = bounds.offsetBy(dx: currentOffsetX, dy: currentOffsetY)
    #endif
    invalidateCapturedRendering()
  }

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
      // Set bounds and center to match our bounds
      contentView.bounds = CGRect(origin: .zero, size: bounds.size)
      contentView.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }
  #elseif canImport(AppKit)
    nonisolated override var isFlipped: Bool { true }

    override func layout() {
      super.layout()
      applyTransform()
    }
  #endif
}

// Type alias for the FFI offset struct
private typealias WuiOffset_Struct = CWaterUI.WuiOffset
