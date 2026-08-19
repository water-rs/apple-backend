import CWaterUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

/// Component for `IgnorableMetadata<NavigationLinkHint>`.
///
/// A navigation link renders and behaves as its content — a plain button.
/// This wrapper only carries the link's identity, so a list row can draw the
/// platform's destination-following affordance around it: iOS shows the
/// disclosure chevron, a Mac shows nothing. See `WuiList`.
@MainActor
final class WuiNavigationLinkHint: PlatformView, WuiComponent {
  static var rawId: CWaterUI.WuiTypeId { waterui_ignorable_metadata_navigation_link_hint_id() }

  private let contentView: any WuiComponent

  var stretchAxis: WuiStretchAxis {
    contentView.stretchAxis
  }

  required init(anyview: OpaquePointer, env: WuiEnvironment) {
    let metadata = waterui_force_as_ignorable_metadata_navigation_link_hint(anyview)
    self.contentView = WuiAnyView.resolve(anyview: metadata.content, env: env)

    super.init(frame: .zero)

    contentView.translatesAutoresizingMaskIntoConstraints = true
    addSubview(contentView)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func layoutPriority() -> Int32 {
    contentView.layoutPriority()
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

extension WuiNavigationLinkHint: WuiPrimaryContentProviding {
  var wuiPrimaryContent: PlatformView? { contentView }
}
