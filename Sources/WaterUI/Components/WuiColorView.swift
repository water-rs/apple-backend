// WuiColorView.swift
// Color fill component - stretches to fill available space with a solid color
//
// # Layout Behavior
// Color views are greedy - they expand to fill all available space in both
// horizontal and vertical directions. Use frame modifiers to constrain size.
//
// // INTERNAL: Layout Contract for Backend Implementers
// // - stretchAxis: .both (greedy, fills all available space)
// // - sizeThatFits: Returns proposed size or 0 if unspecified
// // - Priority: 0 (default)

import CWaterUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
final class WuiColorView: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_color_id() }

    private(set) var stretchAxis: WuiStretchAxis

    private var watcher: WatcherGuard?

    // MARK: - WuiComponent Init

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
        let stretchAxis = WuiStretchAxis(waterui_view_stretch_axis(anyview))
        let colorPtr = waterui_force_as_color(anyview)!
        let wuiColor = WuiColor(colorPtr)
        let color = wuiColor.resolve(in: env)
        self.init(stretchAxis: stretchAxis, color: color)
    }

    // MARK: - Designated Init

    init(stretchAxis: WuiStretchAxis, color: WuiComputed<WuiResolvedColor>) {
        self.stretchAxis = stretchAxis
        super.init(frame: .zero)

        #if canImport(UIKit)
        layer.masksToBounds = true
        #elseif canImport(AppKit)
        wantsLayer = true
        layer?.masksToBounds = true
        #endif

        apply(color: color.value)
        watcher = color.watch { [weak self] newColor, _ in
            self?.apply(color: newColor)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - WuiComponent

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        CGSize(
            width: CGFloat(proposal.width ?? 0),
            height: CGFloat(proposal.height ?? 0)
        )
    }

    // MARK: - Color Application

    private func apply(color: WuiResolvedColor) {
        #if canImport(UIKit)
        backgroundColor = UIColor(
            red: CGFloat(color.red),
            green: CGFloat(color.green),
            blue: CGFloat(color.blue),
            alpha: CGFloat(color.opacity)
        )
        #elseif canImport(AppKit)
        layer?.backgroundColor = NSColor(
            calibratedRed: CGFloat(color.red),
            green: CGFloat(color.green),
            blue: CGFloat(color.blue),
            alpha: CGFloat(color.opacity)
        ).cgColor
        #endif
    }

    #if canImport(AppKit)
    override var isFlipped: Bool { true }
    #endif
}
