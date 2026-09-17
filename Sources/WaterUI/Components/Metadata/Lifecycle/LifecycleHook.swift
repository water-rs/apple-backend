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
      windowMembershipChanged()
    }
  #elseif canImport(AppKit)
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      windowMembershipChanged()
    }
  #endif

  private func windowMembershipChanged() {
    if window == nil {
      handle(WuiLifecycle_Disappear)
    } else {
      scheduleAppear()
    }
  }

  /// `Appear` means the view has been presented, so it fires after the
  /// transaction that inserted the view into the window commits, never inside
  /// it. Core Animation creates no implicit animation for a layer during the
  /// transaction that adds it to the tree, so a hook that animates a property
  /// away from its initial value — a snackbar fading in from opacity 0 and
  /// sliding in from its hidden offset — ran its animation before the first
  /// frame and landed on screen already at its end state, while the exit,
  /// fired on a committed layer, animated. The completion block of the current
  /// implicit transaction is the commit boundary itself.
  private func scheduleAppear() {
    guard lifecycle == WuiLifecycle_Appear, handler != nil else { return }
    CATransaction.setCompletionBlock { [weak self] in
      guard let self, self.window != nil else { return }
      self.handle(WuiLifecycle_Appear)
    }
  }

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

  /// Transparent for layout: the proposal selected for this
  /// wrapper is the proposal its content was negotiated with.
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
