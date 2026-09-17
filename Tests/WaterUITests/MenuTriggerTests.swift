import CWaterUI
import Testing

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

@testable import WaterUI

/// A label stand-in for trigger tests — the assertions observe the trigger
/// control, not the label's own rendering.
@MainActor
private final class EmptyLabel: PlatformView, WuiComponent {
  static var rawId: WuiTypeId { WuiTypeId() }

  init() {
    super.init(frame: .zero)
  }

  init(anyview: OpaquePointer, env: WuiEnvironment) {
    fatalError("EmptyLabel is constructed for tests only")
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func sizeThatFits(_ proposal: WaterUI.WuiProposalSize) -> CGSize { .zero }
}

@MainActor
private func makeMenu(accent: WuiResolvedColor) -> WaterUI.WuiMenu {
  let store = FakeSignalStore(accent)
  return WaterUI.WuiMenu(
    label: EmptyLabel(),
    accent: WuiComputed(
      inner: makeFakeInner(),
      read: store.read,
      watch: store.watch,
      drop: store.drop
    ),
    accessibilityLabel: nil,
    items: nil,
    callAction: { _ in }
  )
}

/// SwiftUI presents a menu trigger in the accent colour on iOS and as a slim
/// pull-down popup button on macOS — never the bordered bold button WaterUI
/// used before.
@Test("Menu trigger tint and presentation match the platform")
@MainActor
func menuTriggerStyle() {
  #if canImport(UIKit)
    let accent = WuiResolvedColor.fromUIColor(.systemRed)
  #elseif canImport(AppKit)
    let accent = WuiResolvedColor.fromNSColor(.systemRed)
  #endif
  let menu = makeMenu(accent: accent)

  #if canImport(UIKit)
    // The trigger draws its label and indicator in the installed accent.
    #expect(menu.button.tintColor == accent.toUIColor())
  #elseif canImport(AppKit)
    // SwiftUIPopupButton is a pull-down NSPopUpButton with the rounded
    // bezel and an untinted face.
    #expect(menu.popUp.pullsDown)
    #expect(menu.popUp.bezelStyle == .rounded)
    #expect(menu.popUp.contentTintColor == nil)
  #endif
}
