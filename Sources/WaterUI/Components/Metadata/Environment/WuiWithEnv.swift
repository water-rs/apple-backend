import CWaterUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

/// Component for WithEnv / Metadata<Environment>.
///
/// This component provides a new environment to its child view tree.
/// It extracts the environment from the metadata and uses it for inflating
/// the wrapped content.
@MainActor
final class WuiWithEnv: PlatformView, WuiComponent {
  static var rawId: CWaterUI.WuiTypeId { waterui_metadata_env_id() }

  private let contentView: any WuiComponent
  private let newEnv: WuiEnvironment
  #if canImport(UIKit)
    private var accentObservation: WuiComputedObservation<WuiResolvedColor>?
  #endif

  var stretchAxis: WuiStretchAxis {
    contentView.stretchAxis
  }

  required init(anyview: OpaquePointer, env: WuiEnvironment) {
    // Extract metadata (content + new environment)
    let metadata = waterui_force_as_metadata_env(anyview)

    // Create WuiEnvironment wrapper for the new environment pointer
    // This takes ownership of the env pointer
    self.newEnv = WuiEnvironment(metadata.value)

    // Resolve the content with the new environment
    self.contentView = WuiAnyView.resolve(anyview: metadata.content, env: newEnv)

    super.init(frame: .zero)

    // Embed the content view using manual frame layout
    contentView.translatesAutoresizingMaskIntoConstraints = true
    addSubview(contentView)

    #if canImport(UIKit)
      let accent = WuiComputedObservation(
        themeColor: WuiColorSlot_Accent,
        env: newEnv
      ) { [weak self] color, _ in
        self?.tintColor = color.toUIColor()
      }
      accentObservation = accent
      tintColor = accent.value.toUIColor()
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
