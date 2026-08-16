import CWaterUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

/// Component for `Metadata<LifecycleHook>`.
@MainActor
final class WuiLifecycleHook: PlatformView, WuiComponent {
  static var rawId: CWaterUI.WuiTypeId { waterui_metadata_lifecycle_hook_id() }

  private let contentView: any WuiComponent
  private let env: WuiEnvironment
  private let lifecycle: WuiLifecycle
  private var handler: OpaquePointer?

  var stretchAxis: WuiStretchAxis {
    contentView.stretchAxis
  }

  required init(anyview: OpaquePointer, env: WuiEnvironment) {
    let metadata = waterui_force_as_metadata_lifecycle_hook(anyview)
    self.env = env
    self.lifecycle = metadata.value.lifecycle
    self.handler = metadata.value.handler
    self.contentView = WuiAnyView.resolve(anyview: metadata.content, env: env)

    super.init(frame: .zero)

    contentView.translatesAutoresizingMaskIntoConstraints = true
    addSubview(contentView)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  #if canImport(UIKit)
    override func didMoveToWindow() {
      super.didMoveToWindow()
      handle(window == nil ? WuiLifecycle_Disappear : WuiLifecycle_Appear)
    }
  #elseif canImport(AppKit)
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      handle(window == nil ? WuiLifecycle_Disappear : WuiLifecycle_Appear)
    }
  #endif

  private func handle(_ event: WuiLifecycle) {
    guard lifecycle == event, let handler else { return }
    self.handler = nil
    waterui_call_lifecycle_hook(handler, env.inner)
  }

  @MainActor deinit {
    if let handler {
      waterui_drop_lifecycle_hook(handler)
    }
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
