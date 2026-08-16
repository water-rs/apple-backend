import CWaterUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

@MainActor
class WuiNavigationTransitionTaggedView: PlatformView {
  private let contentView: any WuiComponent

  var stretchAxis: WuiStretchAxis { contentView.stretchAxis }

  init(content: OpaquePointer, id: Int32, env: WuiEnvironment) {
    guard id != 0 else {
      fatalError("Navigation transition metadata requires a non-zero id")
    }
    self.contentView = WuiAnyView.resolve(anyview: content, env: env)
    super.init(frame: .zero)

    contentView.translatesAutoresizingMaskIntoConstraints = true
    addSubview(contentView)
    #if canImport(UIKit)
      tag = Int(id)
    #elseif canImport(AppKit)
      identifier = NSUserInterfaceItemIdentifier("dev.waterui.navigation.transition.\(id)")
    #endif
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

@MainActor
final class WuiNavigationTransitionSourceView: WuiNavigationTransitionTaggedView, WuiComponent {
  static var rawId: CWaterUI.WuiTypeId {
    waterui_metadata_navigation_transition_source_id()
  }

  required init(anyview: OpaquePointer, env: WuiEnvironment) {
    let metadata = waterui_force_as_metadata_navigation_transition_source(anyview)
    super.init(content: metadata.content, id: metadata.value.inner, env: env)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}

@MainActor
final class WuiNavigationTransitionDestinationView: WuiNavigationTransitionTaggedView,
  WuiComponent
{
  static var rawId: CWaterUI.WuiTypeId {
    waterui_metadata_navigation_transition_destination_id()
  }

  required init(anyview: OpaquePointer, env: WuiEnvironment) {
    let metadata = waterui_force_as_metadata_navigation_transition_destination(anyview)
    super.init(content: metadata.content, id: metadata.value.inner, env: env)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}
