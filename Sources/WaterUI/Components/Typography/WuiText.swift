// WuiText.swift
// Styled text component - uses WuiTextBase for shared functionality

import CWaterUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

@MainActor
final class WuiText: WuiTextBase, WuiComponent {
  static var rawId: CWaterUI.WuiTypeId { waterui_text_id() }

  private var content: WuiComputed<WuiStyledStr>
  private var paragraphAlignment: WuiComputed<WuiHorizontalAlignment>
  private var env: WuiEnvironment
  private var contentWatcher: WatcherGuard?
  private var alignmentWatcher: WatcherGuard?
  private var styledRenderer: WuiStyledStrRenderer?
  var onIntrinsicContentChange: (() -> Void)?

  // MARK: - WuiComponent Init

  convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
    let ffiText: CWaterUI.WuiText = waterui_force_as_text(anyview)
    let content = WuiComputed<WuiStyledStr>(ffiText.content)
    let paragraphAlignment = WuiComputed<WuiHorizontalAlignment>(ffiText.paragraph_alignment)
    self.init(content: content, paragraphAlignment: paragraphAlignment, env: env)
  }

  // MARK: - Designated Init

  init(
    content: WuiComputed<WuiStyledStr>, paragraphAlignment: WuiComputed<WuiHorizontalAlignment>,
    env: WuiEnvironment
  ) {
    self.content = content
    self.paragraphAlignment = paragraphAlignment
    self.env = env
    #if canImport(AppKit)
      super.init(initialText: "")
    #else
      super.init(frame: .zero)
    #endif

    startWatching()
    setParagraphAlignment(paragraphAlignment.value)
    applyText(content.value)
  }

  // MARK: - WuiComponent

  override func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
    super.sizeThatFits(proposal)
  }

  // MARK: - Reactive Updates

  private func startWatching() {
    contentWatcher = content.watch { [weak self] value, metadata in
      guard let self else { return }
      #if canImport(UIKit)
        withCrossDissolveAnimation(self.label, metadata) {
          self.applyText(value)
        }
      #elseif canImport(AppKit)
        withCrossDissolveAnimation(self.textField, metadata) {
          self.applyText(value)
        }
      #endif
    }

    alignmentWatcher = paragraphAlignment.watch { [weak self] value, _ in
      guard let self else { return }
      self.setParagraphAlignment(value)
    }
  }

  private func applyText(_ styled: WuiStyledStr) {
    styledRenderer = WuiStyledStrRenderer(styled: styled, env: env) { [weak self] in
      self?.applyResolvedText()
    }
    applyResolvedText()
  }

  private func applyResolvedText() {
    guard let styledRenderer else { return }
    setAttributedText(styledRenderer.attributedString())
    onIntrinsicContentChange?()
  }
}
