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

    // Font from environment
    private var bodyFont: WuiComputed<WuiResolvedFont>?
    private var fontWatcher: WatcherGuard?

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
        label.text = text
        #endif

        setupFontFromEnv(env)
    }

    // MARK: - WuiComponent

    override func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        super.sizeThatFits(proposal)
    }

    // MARK: - Font Setup

    private func setupFontFromEnv(_ env: WuiEnvironment) {
        guard let fontPtr = waterui_theme_font_body(env.inner) else { return }

        let computed = WuiComputed<WuiResolvedFont>(fontPtr)
        self.bodyFont = computed

        // Apply initial font
        applyFont(computed.value)

        // Watch for font changes
        fontWatcher = computed.watch { [weak self] newFont, _ in
            self?.applyFont(newFont)
        }
    }

    private func applyFont(_ resolved: WuiResolvedFont) {
        #if canImport(UIKit)
        let font = UIFont.systemFont(ofSize: CGFloat(resolved.size), weight: resolved.weight.toUIFontWeight())
        #elseif canImport(AppKit)
        let font = NSFont.systemFont(ofSize: CGFloat(resolved.size), weight: resolved.weight.toNSFontWeight())
        #endif
        setFont(font)
    }
}
