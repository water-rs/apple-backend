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

extension PlatformView {
    /// Whether this view is WaterUI's empty view `()`, possibly under
    /// layout-transparent wrappers or hosted by a `Dynamic`.
    ///
    /// This is a semantic answer, not a measured size: a `Color` or `Spacer`
    /// squeezed to zero still renders and still answers false, and so does a
    /// `WuiFixedContainer` (a frame or nested stack explicitly claims its
    /// slot — e.g. `().size(w, h)`). Transparent single-child hosts forward
    /// the child's answer. A stack treats a view answering true as a
    /// non-member (§4.4: no slot, no spacing).
    var rendersNothing: Bool {
        if self is WuiEmpty {
            return true
        }
        if self is WuiFixedContainer {
            return false
        }
        guard !subviews.isEmpty else {
            return false
        }
        return subviews.allSatisfy { $0.rendersNothing }
    }
}
