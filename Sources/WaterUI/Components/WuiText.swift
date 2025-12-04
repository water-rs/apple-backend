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
    private var env: WuiEnvironment
    private var watcher: WatcherGuard?

    // MARK: - WuiComponent Init

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
        let ffiText: CWaterUI.WuiText = waterui_force_as_text(anyview)
        let content = WuiComputed<WuiStyledStr>(ffiText.content)
        self.init(content: content, env: env)
    }

    // MARK: - Designated Init

    init(content: WuiComputed<WuiStyledStr>, env: WuiEnvironment) {
        self.content = content
        self.env = env
        #if canImport(AppKit)
        super.init(initialText: "")
        #else
        super.init(frame: .zero)
        #endif

        applyText(content.value)
        startWatching()
    }

    // MARK: - WuiComponent

    override func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        super.sizeThatFits(proposal)
    }

    // MARK: - Reactive Updates

    private func startWatching() {
        watcher = content.watch { [weak self] value, metadata in
            guard let self else { return }
            #if canImport(UIKit)
            if metadata.getAnimation() != nil {
                UIView.transition(
                    with: label,
                    duration: 0.15,
                    options: .transitionCrossDissolve,
                    animations: { self.applyText(value) }
                )
            } else {
                self.applyText(value)
            }
            #elseif canImport(AppKit)
            if metadata.getAnimation() != nil {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.15
                    context.allowsImplicitAnimation = true
                    self.applyText(value)
                }
            } else {
                self.applyText(value)
            }
            #endif
        }
    }

    private func applyText(_ styled: WuiStyledStr) {
        let attributed = styled.toAttributedString(env: env)
        setAttributedText(attributed)
    }
}
