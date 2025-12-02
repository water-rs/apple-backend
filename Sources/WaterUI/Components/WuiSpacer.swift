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
// // - sizeThatFits: Returns proposed size or 0 if unspecified
// // - Priority: 0 (default)

import CWaterUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
final class WuiSpacer: PlatformView, WuiComponent {
    static let id: String = decodeViewIdentifier(waterui_spacer_id())

    var stretchAxis: WuiStretchAxis { .mainAxis }

    // MARK: - WuiComponent Init

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
        self.init()
    }

    // MARK: - Designated Init

    init() {
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

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        CGSize(
            width: proposal.width.map { CGFloat($0) } ?? 0,
            height: proposal.height.map { CGFloat($0) } ?? 0
        )
    }

    #if canImport(AppKit)
    override var isFlipped: Bool { true }
    #endif
}
