import CWaterUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

/// Component for `Metadata<LayoutPriority>` — `.layout_priority(_)` in Rust.
///
/// Transparent for geometry: measurement, placement, and stretch belong to
/// the content. Only the priority reported to the parent's layout differs —
/// the metadata value replaces the child's own when space is distributed
/// between siblings.
@MainActor
final class WuiLayoutPriority: PlatformView, WuiComponent {
  static var rawId: CWaterUI.WuiTypeId { waterui_metadata_layout_priority_id() }

  private let contentView: any WuiComponent
  private let priority: Int32

  var stretchAxis: WuiStretchAxis {
    contentView.stretchAxis
  }

  required convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
    let metadata = waterui_force_as_metadata_layout_priority(anyview)
    self.init(
      contentView: WuiAnyView.resolve(anyview: metadata.content, env: env),
      priority: metadata.value
    )
  }

  init(contentView: any WuiComponent, priority: Int32) {
    self.contentView = contentView
    self.priority = priority
    super.init(frame: .zero)

    contentView.translatesAutoresizingMaskIntoConstraints = true
    addSubview(contentView)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// The override, not the content's own priority: `.layout_priority(n)`
  /// exists to win or yield space on the child's behalf.
  func layoutPriority() -> Int32 {
    priority
  }

  /// Transparent for layout: the proposal selected for this wrapper is the
  /// proposal its content was negotiated with.
  func setPlacementProposal(_ proposal: WuiProposalSize) {
    contentView.setPlacementProposal(proposal)
  }

  func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
    contentView.sizeThatFits(proposal)
  }

  func measure(_ proposal: WuiProposalSize) -> WuiViewDimensions {
    contentView.measure(proposal)
  }

  #if canImport(UIKit)
    override func layoutSubviews() {
      super.layoutSubviews()
      contentView.frame = bounds
    }
  #elseif canImport(AppKit)
    nonisolated override var isFlipped: Bool { true }

    override func layout() {
      super.layout()
      contentView.frame = bounds
    }
  #endif
}
