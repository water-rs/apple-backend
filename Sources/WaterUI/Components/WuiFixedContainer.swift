// WuiFixedContainer.swift
// Fixed container layout component - children are a fixed array (no lazy loading)
//
// # Layout Behavior
// Container delegates layout calculations to the Rust layout engine.
// Size and placement are determined by the layout algorithm (VStack, HStack, etc.).
// Children are provided as a fixed array at construction time.
//
// // INTERNAL: Layout Contract for Backend Implementers
// // - stretchAxis: Depends on children and layout algorithm
// // - sizeThatFits: Delegates to Rust layout engine
// // - Priority: 0 (default)

import CWaterUI
import os.log

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

private let logger = Logger(subsystem: "dev.waterui", category: "layout")

/// A native container that uses the Rust layout engine for child positioning.
/// FixedContainer has a fixed array of children - no lazy loading support.
@MainActor
final class WuiFixedContainer: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_fixed_container_id() }

    private(set) var stretchAxis: WuiStretchAxis

    private var wuiLayout: WuiLayout
    private var childViews: [WuiAnyView]
    private let bridge = NativeLayoutBridge()

    // MARK: - WuiComponent Init

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
        let stretchAxis = WuiStretchAxis(waterui_view_stretch_axis(anyview))
        let container: CWaterUI.WuiFixedContainer = waterui_force_as_fixed_container(anyview)
        let layout = WuiLayout(inner: container.layout!)
        let pointerArray = WuiArray<OpaquePointer>(container.contents)
        let childViews = pointerArray.toArray().map {
            WuiAnyView(anyview: $0, env: env)
        }
        self.init(stretchAxis: stretchAxis, layout: layout, children: childViews)
    }

    // MARK: - Designated Init

    init(stretchAxis: WuiStretchAxis, layout: WuiLayout, children: [WuiAnyView]) {
        self.stretchAxis = stretchAxis
        self.wuiLayout = layout
        self.childViews = children
        super.init(frame: .zero)

        for child in children {
            child.translatesAutoresizingMaskIntoConstraints = true
            addSubview(child)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - WuiComponent

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        let proxies = bridge.createSubViewProxies(children: childViews) { child, childProposal in
            child.sizeThatFits(childProposal)
        }

        return bridge.containerSize(
            layout: wuiLayout,
            parentProposal: proposal,
            children: proxies
        )
    }

    // MARK: - Layout

    #if canImport(UIKit)
    override func layoutSubviews() {
        super.layoutSubviews()
        performLayout()
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let proposal = WuiProposalSize(size: size)
        return sizeThatFits(proposal)
    }

    override var intrinsicContentSize: CGSize {
        sizeThatFits(WuiProposalSize())
    }
    #elseif canImport(AppKit)
    override func layout() {
        super.layout()
        performLayout()
    }

    override var fittingSize: NSSize {
        sizeThatFits(WuiProposalSize())
    }

    override var intrinsicContentSize: NSSize {
        sizeThatFits(WuiProposalSize())
    }

    override var isFlipped: Bool { true }
    #endif

    private func performLayout() {
        guard !childViews.isEmpty else { return }

        // CRITICAL: Create proposal from bounds so children measure with actual available width
        // This ensures VStack centering works correctly - children know the real container width
        let boundsProposal = WuiProposalSize(width: Float(bounds.width), height: Float(bounds.height))

        let proxies = bridge.createSubViewProxies(children: childViews) { child, childProposal in
            child.sizeThatFits(childProposal)
        }

        // Measure with bounds-based proposal first - this ensures children know available width
        _ = bridge.containerSize(
            layout: wuiLayout,
            parentProposal: boundsProposal,
            children: proxies
        )

        let rects = bridge.placements(
            layout: wuiLayout,
            bounds: bounds,
            children: proxies
        )

        // Debug: log layout info if there are more than 2 children (likely a table or complex layout)
        if childViews.count > 2 {
            let boundsDesc = bounds.debugDescription
            let childCount = childViews.count
            let rectCount = rects.count
            logger.info("[WuiFixedContainer] bounds=\(boundsDesc), children=\(childCount), rects=\(rectCount)")
            for (index, rect) in rects.enumerated() {
                let rectDesc = rect.debugDescription
                logger.info("  child[\(index)] rect=\(rectDesc)")
            }
        }

        for (index, rect) in rects.enumerated() {
            guard index < childViews.count else { break }
            var frame = rect
            guard frame.isValidForLayout else {
                let frameDesc = frame.debugDescription
                logger.warning("WuiFixedContainer received invalid rect for child \(index): \(frameDesc)")
                continue
            }

            #if canImport(AppKit)
            // Convert to AppKit coordinate system if not flipped
            if !isFlipped {
                frame.origin.y = bounds.height - frame.origin.y - frame.height
            }
            #endif

            childViews[index].frame = frame
        }
    }

    // MARK: - Child Management

    func setChildren(_ newChildren: [WuiAnyView]) {
        for child in childViews {
            child.removeFromSuperview()
        }

        childViews = newChildren
        for child in newChildren {
            child.translatesAutoresizingMaskIntoConstraints = true
            addSubview(child)
        }

        #if canImport(UIKit)
        setNeedsLayout()
        #elseif canImport(AppKit)
        needsLayout = true
        #endif
    }
}
