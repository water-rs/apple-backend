@_exported import CWaterUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

/// Component for Metadata<OnKeyPress>.
///
/// Carries a key handler that runs when an unconsumed key press bubbles up
/// through this view. The wrapper is transparent: it draws nothing, sizes
/// itself to its content, and only participates in the responder chain —
/// on macOS via `keyDown`, on iOS via `pressesBegan`. `Handled` from the
/// Rust side stops the bubble here; `Ignored` keeps it moving.
@MainActor
final class WuiOnKeyPress: PlatformView, WuiComponent {
  static var rawId: CWaterUI.WuiTypeId { waterui_metadata_on_key_press_id() }

  private let contentView: any WuiComponent
  private let env: WuiEnvironment
  private let handlerPtr: OpaquePointer

  var stretchAxis: WuiStretchAxis {
    contentView.stretchAxis
  }

  required init(anyview: OpaquePointer, env: WuiEnvironment) {
    let metadata = waterui_force_as_metadata_on_key_press(anyview)

    self.env = env
    guard let handler = metadata.value else {
      fatalError("OnKeyPress metadata is missing its handler")
    }
    self.handlerPtr = handler

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

  /// Runs the Rust handler for one key press; true means it consumed the key
  /// and the bubble stops at this view.
  private func handle(key: String, code: String, modifiers: UInt32, isRepeat: Bool) -> Bool {
    let press = WuiKeyPress(
      key: WuiStr(string: key).intoInner(),
      code: WuiStr(string: code).intoInner(),
      modifiers: modifiers,
      repeat: isRepeat
    )
    return waterui_call_on_key_press(handlerPtr, env.inner, press) == WuiKeyHandling_Handled
  }

  #if canImport(AppKit)
    nonisolated override var isFlipped: Bool { true }

    override func layout() {
      super.layout()
      contentView.frame = wuiContentFrame(of: contentView, in: self)
    }

    override func keyDown(with event: NSEvent) {
      let code = wuiSurfaceCode(event)
      if handle(
        key: wuiSurfaceKey(event, code: code),
        code: code,
        modifiers: wuiSurfaceModifiers(event.modifierFlags),
        isRepeat: event.isARepeat
      ) {
        return
      }
      super.keyDown(with: event)
    }
  #elseif canImport(UIKit)
    override func layoutSubviews() {
      super.layoutSubviews()
      contentView.frame = wuiContentFrame(of: contentView, in: self)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
      var unconsumed = presses
      for press in presses {
        guard let key = press.key else { continue }
        let code = wuiSurfaceCode(key)
        if handle(
          key: wuiSurfaceKey(key),
          code: code,
          modifiers: wuiSurfaceModifiers(key.modifierFlags),
          isRepeat: false
        ) {
          unconsumed.remove(press)
        }
      }
      if !unconsumed.isEmpty {
        super.pressesBegan(unconsumed, with: event)
      }
    }
  #endif

  @MainActor deinit {
    waterui_drop_on_key_press(handlerPtr)
  }
}
