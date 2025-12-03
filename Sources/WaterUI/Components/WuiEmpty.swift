// WuiEmpty.swift
// Zero-size invisible view for empty/unit type `()`
//
// # Layout Behavior
// Empty view has zero size and is invisible. Used as a placeholder for unit type `()`.
// Does not participate in layout or consume any space.
//
// // INTERNAL: Layout Contract for Backend Implementers
// // - stretchAxis: .none (zero-size, does not expand)
// // - sizeThatFits: Always returns CGSize.zero
// // - Priority: 0 (default)

import CWaterUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// A zero-size invisible view for empty/unit type `()`.
@MainActor
final class WuiEmpty: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_empty_id() }

    // WuiEmpty is special - it doesn't use the standard init(anyview:env:) pattern
    // because it's handled specially in PlatformRenderer.makeView()
    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
        self.init()
    }

    init() {
        super.init(frame: .zero)
        #if canImport(UIKit)
        isHidden = true
        #elseif canImport(AppKit)
        isHidden = true
        #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        .zero
    }
}
