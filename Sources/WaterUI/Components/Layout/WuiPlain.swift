// WuiPlain.swift
// Plain text component (simple unstyled text) - uses WuiTextBase for shared functionality

import CWaterUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

@MainActor
final class WuiPlain: WuiTextBase, WuiComponent {
  static var rawId: CWaterUI.WuiTypeId { waterui_plain_id() }

  private let text: String
  private var bodyFontObservation: WuiComputedObservation<WuiResolvedFontValue>?
  private var foregroundObservation: WuiComputedObservation<WuiResolvedColor>?

  // MARK: - WuiComponent Init

  convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
    let ffiStr: CWaterUI.WuiStr = waterui_force_as_plain(anyview)
    let text = WuiStr(ffiStr).toString()
    self.init(text: text, env: env)
  }

  // MARK: - Designated Init

  init(text: String, env: WuiEnvironment) {
    self.text = text
    #if canImport(AppKit)
      super.init(initialText: text)
    #else
      super.init(frame: .zero)
    #endif
    installTheme(env)
  }

  // MARK: - WuiComponent

  override func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
    super.sizeThatFits(proposal)
  }

  // MARK: - Font Setup

  private func installTheme(_ env: WuiEnvironment) {
    let bodyFont = WuiComputedObservation(
      themeFont: WuiFontSlot_Body,
      env: env
    ) {
      [weak self] _, _ in
      self?.render()
    }
    let foreground = WuiComputedObservation(
      themeColor: WuiColorSlot_Foreground,
      env: env
    ) { [weak self] _, _ in
      self?.render()
    }
    bodyFontObservation = bodyFont
    foregroundObservation = foreground
    render()
  }

  /// A plain string is body text in the foreground colour, rendered through
  /// the same attributed form as styled text so the body slot's line pitch
  /// and letter spacing reach it.
  private func render() {
    guard let bodyFontObservation, let foregroundObservation else {
      fatalError("WuiPlain renders before its theme observations are installed")
    }
    setAttributedText(
      NSAttributedString.wui(
        text,
        font: bodyFontObservation.value,
        foreground: foregroundObservation.value.toPlatformColor(),
        background: nil
      ))
    invalidateCapturedRendering()
  }
}
