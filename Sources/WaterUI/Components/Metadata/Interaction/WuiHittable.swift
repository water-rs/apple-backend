import CWaterUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

/// Component for Metadata<Hittable>.
///
/// Controls whether a view responds to hit testing (touch/click events).
/// When disabled, touch events pass through the view to views behind it.
@MainActor
final class WuiHittable: PlatformView, WuiComponent {
  static var rawId: CWaterUI.WuiTypeId { waterui_metadata_hittable_id() }

  private let contentView: any WuiComponent
  private var enabledObservation: WuiComputedObservation<Bool>?
  private var currentEnabled: Bool = true

  var stretchAxis: WuiStretchAxis {
    contentView.stretchAxis
  }

  required init(anyview: OpaquePointer, env: WuiEnvironment) {
    let metadata = waterui_force_as_metadata_hittable(anyview)

    // Resolve the content
    self.contentView = WuiAnyView.resolve(anyview: metadata.content, env: env)

    super.init(frame: .zero)

    contentView.translatesAutoresizingMaskIntoConstraints = true
    addSubview(contentView)

    // Setup watcher for reactive enabled state
    setupWatcher(metadata.value)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupWatcher(_ hittable: WuiHittable_Struct) {
    let observation = WuiComputedObservation(WuiComputed<Bool>(hittable.enabled)) {
      [weak self] value, _ in
      guard let self else { return }
      self.currentEnabled = value
      self.applyHitTesting()
    }
    enabledObservation = observation
    currentEnabled = observation.value
    applyHitTesting()
  }

  private func applyHitTesting() {
    #if canImport(UIKit)
      contentView.isUserInteractionEnabled = currentEnabled
    #endif
    // On macOS, hit testing is handled via hitTest override
  }

  func layoutPriority() -> Int32 {
    contentView.layoutPriority()
  }

  func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
    contentView.sizeThatFits(proposal)
  }

  #if canImport(UIKit)
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
      guard currentEnabled else { return nil }
      return super.hitTest(point, with: event)
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      contentView.frame = bounds
    }
  #elseif canImport(AppKit)
    nonisolated override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
      guard currentEnabled else { return nil }
      return super.hitTest(point)
    }

    override func layout() {
      super.layout()
      contentView.frame = bounds
    }
  #endif
}

private typealias WuiHittable_Struct = CWaterUI.WuiHittable
