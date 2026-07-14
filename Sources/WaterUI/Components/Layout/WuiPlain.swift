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
    #if canImport(AppKit)
      super.init(initialText: text)
    #else
      super.init(frame: .zero)
      label.text = text
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
      [weak self] font, _ in
      self?.applyFont(font)
    }
    let foreground = WuiComputedObservation(
      themeColor: WuiColorSlot_Foreground,
      env: env
    ) { [weak self] color, _ in
      self?.applyForeground(color)
    }
    bodyFontObservation = bodyFont
    foregroundObservation = foreground
    applyFont(bodyFont.value)
    applyForeground(foreground.value)
  }

  private func applyFont(_ resolved: WuiResolvedFontValue) {
    #if canImport(UIKit)
      let font = UIFont.systemFont(
        ofSize: CGFloat(resolved.size), weight: resolved.weight.toUIFontWeight())
    #elseif canImport(AppKit)
      let font = NSFont.systemFont(
        ofSize: CGFloat(resolved.size), weight: resolved.weight.toNSFontWeight())
    #endif
    setFont(font)
    invalidateCapturedRendering()
  }

  private func applyForeground(_ color: WuiResolvedColor) {
    #if canImport(UIKit)
      label.textColor = color.toUIColor()
    #elseif canImport(AppKit)
      textField.textColor = color.toNSColor()
    #endif
    invalidateCapturedRendering()
  }
}
