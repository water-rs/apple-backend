import CWaterUI
import SwiftUI
import Testing

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

@testable import WaterUI

/// A resolved text leaf standing in for a `WuiAnyView` label — measures
/// through the same platform text view `WuiText` uses.
@MainActor
private final class TextLabel: WuiTextBase, WuiComponent {
  static var rawId: WuiTypeId { WuiTypeId() }

  init(_ text: String) {
    #if canImport(AppKit)
      super.init(initialText: "")
    #else
      super.init(frame: .zero)
    #endif
    setAttributedText(
      NSAttributedString(
        string: text,
        attributes: [.font: PlatformFont.preferredFont(forTextStyle: .body)]
      ))
  }

  init(anyview: OpaquePointer, env: WuiEnvironment) {
    fatalError("TextLabel is constructed for tests only")
  }
}

@MainActor
private func makeComputed<T>(_ store: FakeSignalStore<T>) -> WuiComputed<T> {
  WuiComputed(
    inner: makeFakeInner(),
    read: store.read,
    watch: store.watch,
    drop: store.drop
  )
}

@MainActor
private func makeButton(style: WuiButtonStyle, label: String) -> WaterUI.WuiButton {
  #if canImport(UIKit)
    let accent = WuiResolvedColor.fromUIColor(.systemBlue)
  #elseif canImport(AppKit)
    let accent = WuiResolvedColor.fromNSColor(.systemBlue)
  #endif
  return WuiButton(
    label: TextLabel(label),
    action: Action(call: {}),
    style: style,
    disabled: makeComputed(FakeSignalStore(false)),
    accent: makeComputed(FakeSignalStore(accent)),
    accessibilityLabel: makeComputed(FakeSignalStore(WaterUI.WuiStyledStr(chunks: [])))
  )
}

/// SwiftUI's borderless button is the label and nothing else — a chrome-less
/// WaterUI button must report the same intrinsic width.
@Test("Chrome-less button styles match SwiftUI's borderless width")
@MainActor
func borderlessButtonWidthParity() {
  let waterUI = makeButton(style: WuiButtonStyle_Plain, label: "x")
    .sizeThatFits(WuiProposalSize()).width

  #if canImport(UIKit)
    let swiftUI = UIHostingController(
      rootView: Button("x") {}.buttonStyle(.borderless)
    ).sizeThatFits(in: UIView.layoutFittingCompressedSize).width
  #elseif canImport(AppKit)
    let swiftUI = NSHostingView(
      rootView: Button("x") {}.buttonStyle(.borderless)
    ).fittingSize.width
  #endif

  #expect(abs(waterUI - swiftUI) <= 0.5)
}
