// WuiDivider.swift
// Divider component - thin line separator
//
// # Layout Behavior
// Divider expands along the parent container's cross axis to span the full width/height.
// In VStack: expands horizontally (1pt height). In HStack: expands vertically (1pt width).
// The thickness (1pt) is fixed and cannot be changed.
//
// // INTERNAL: Layout Contract for Backend Implementers
// // - stretchAxis: .crossAxis (expands along parent's cross axis)
// // - sizeThatFits: Returns proposed width (or 0) with fixed 1pt height
// // - Priority: 0 (default)

import CWaterUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
final class WuiDivider: PlatformView, WuiComponent {
    static let id: String = decodeViewIdentifier(waterui_divider_id())

    var stretchAxis: WuiStretchAxis { .crossAxis }

    // MARK: - WuiComponent Init

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
        self.init()
    }

    // MARK: - Designated Init

    init() {
        super.init(frame: .zero)
        #if canImport(UIKit)
        backgroundColor = .separator
        #elseif canImport(AppKit)
        wantsLayer = true
        layer?.backgroundColor = NSColor.separatorColor.cgColor
        #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - WuiComponent

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        // Divider stretches horizontally, fixed 1pt height
        let width = proposal.width.map { CGFloat($0) } ?? 0
        return CGSize(width: width, height: 1)
    }

    #if canImport(UIKit)
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 1)
    }
    #elseif canImport(AppKit)
    override var intrinsicContentSize: NSSize {
        CGSize(width: NSView.noIntrinsicMetric, height: 1)
    }

    override var isFlipped: Bool { true }
    #endif
}
