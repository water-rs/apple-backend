// WuiSpacer.swift
// Spacer component - stretches to fill available space along container's main axis
//
// # Layout Behavior
// Spacer expands along the parent container's main axis to fill available space.
// In VStack: expands vertically. In HStack: expands horizontally.
// Multiple spacers in the same container share the available space equally.
//
// // INTERNAL: Layout Contract for Backend Implementers
// // - stretchAxis: .mainAxis (expands along parent's main axis)
// // - sizeThatFits: Returns the minimum length on both axes; the stack
// //   hands the spacer its main-axis allocation at placement
// // - Priority: Int32.min (flexible gap)

import CWaterUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
final class WuiSpacer: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_spacer_id() }

    private(set) var stretchAxis: WuiStretchAxis

    // MARK: - WuiComponent Init

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
        let stretchAxis = WuiStretchAxis(waterui_view_stretch_axis(anyview))
        self.init(stretchAxis: stretchAxis)
    }

    // MARK: - Designated Init

    init(stretchAxis: WuiStretchAxis) {
        self.stretchAxis = stretchAxis
        super.init(frame: .zero)
        #if canImport(UIKit)
        backgroundColor = .clear
        #elseif canImport(AppKit)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - WuiComponent

    /// `Spacer::DEFAULT_LAYOUT_PRIORITY` — a spacer yields every other child
    /// before taking space, so it sits at the bottom of the priority bands.
    func layoutPriority() -> Int32 {
        Int32.min
    }

    /// A spacer measures as its minimum length on both axes — zero — the way
    /// the framework's own `SpacerLayout` does. The stack expands it along its
    /// main axis at placement because it stretches there; answering the
    /// proposal here instead made every spacer report the offer on the cross
    /// axis too, so a column holding `spacer().height(8)` measured as wide as
    /// the offer and a content-sized card filled its whole slot.
    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        .zero
    }

    #if canImport(AppKit)
    nonisolated override var isFlipped: Bool { true }
    #endif
}
