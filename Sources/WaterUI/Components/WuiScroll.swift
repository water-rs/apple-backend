// WuiScroll.swift
// Scroll view component - merged UIKit and AppKit implementation
//
// # Layout Behavior
// ScrollView is greedy - it expands to fill all available space in both directions.
// Content can exceed scroll view bounds and becomes scrollable.
// Scroll direction is configured via axis parameter.
//
// // INTERNAL: Layout Contract for Backend Implementers
// // - stretchAxis: .both (greedy, fills all available space)
// // - sizeThatFits: Returns proposed size or screen size if unspecified
// // - Priority: 0 (default)

import CWaterUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit)
@MainActor
final class WuiScroll: UIScrollView, WuiComponent, UIScrollViewDelegate {
    static var rawId: CWaterUI.WuiTypeId { waterui_scroll_view_id() }

    private(set) var stretchAxis: WuiStretchAxis

    private var contentView: WuiAnyView
    private let axis: WuiAxis

    // MARK: - WuiComponent Init

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
        let stretchAxis = WuiStretchAxis(waterui_view_stretch_axis(anyview))
        let ffiScroll: CWaterUI.WuiScrollView = waterui_force_as_scroll_view(anyview)
        let contentView = WuiAnyView(anyview: ffiScroll.content, env: env)
        self.init(stretchAxis: stretchAxis, content: contentView, axis: ffiScroll.axis)
    }

    // MARK: - Designated Init

    init(stretchAxis: WuiStretchAxis, content: WuiAnyView, axis: WuiAxis) {
        self.stretchAxis = stretchAxis
        self.contentView = content
        self.axis = axis
        super.init(frame: .zero)

        content.translatesAutoresizingMaskIntoConstraints = true
        addSubview(content)

        delegate = self

        let isVertical = axis == WuiAxis_Vertical || axis == WuiAxis_All
        let isHorizontal = axis == WuiAxis_Horizontal || axis == WuiAxis_All

        showsVerticalScrollIndicator = isVertical
        showsHorizontalScrollIndicator = isHorizontal
        alwaysBounceVertical = isVertical
        alwaysBounceHorizontal = isHorizontal

        // Don't use automatic adjustment - we handle safe area manually for SwiftUI-like behavior
        // where ScrollView extends into bottom safe area
        contentInsetAdjustmentBehavior = .never

        // Allow content to be visible outside scroll view bounds (for bottom safe area extension)
        clipsToBounds = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - WuiComponent

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        // ScrollView takes all proposed space, or screen size if unspecified
        let width = proposal.width.map { CGFloat($0) } ?? UIScreen.main.bounds.width
        let height = proposal.height.map { CGFloat($0) } ?? UIScreen.main.bounds.height
        return CGSize(width: width, height: height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        // Get bottom safe area for SwiftUI-like extension behavior
        let safeBottom = window?.safeAreaInsets.bottom ?? 0
        let isVerticalScroll = axis == WuiAxis_Vertical || axis == WuiAxis_All

        // Measure content with the scroll view's width (for vertical scrolling)
        // or height (for horizontal scrolling) as constraint
        let contentProposal: WuiProposalSize
        switch axis {
        case WuiAxis_Vertical:
            contentProposal = WuiProposalSize(width: Float(bounds.width), height: nil)
        case WuiAxis_Horizontal:
            contentProposal = WuiProposalSize(width: nil, height: Float(bounds.height))
        case WuiAxis_All:
            contentProposal = WuiProposalSize(width: nil, height: nil)
        default:
            contentProposal = WuiProposalSize(width: Float(bounds.width), height: nil)
        }

        let measuredSize = contentView.sizeThatFits(contentProposal)

        // Calculate effective scroll height including bottom safe area for vertical scrolling
        // This allows content to scroll into the bottom safe area like SwiftUI
        let effectiveScrollHeight = bounds.height + (isVerticalScroll ? safeBottom : 0)

        let finalWidth: CGFloat
        let finalHeight: CGFloat

        switch axis {
        case WuiAxis_Vertical:
            finalWidth = bounds.width
            finalHeight = max(measuredSize.height, effectiveScrollHeight)
        case WuiAxis_Horizontal:
            finalWidth = max(measuredSize.width, bounds.width)
            finalHeight = bounds.height
        case WuiAxis_All:
            finalWidth = max(measuredSize.width, bounds.width)
            finalHeight = max(measuredSize.height, effectiveScrollHeight)
        default:
            finalWidth = bounds.width
            finalHeight = max(measuredSize.height, effectiveScrollHeight)
        }

        contentView.frame = CGRect(x: 0, y: 0, width: finalWidth, height: finalHeight)

        // Content size includes bottom safe area so content can scroll there
        self.contentSize = CGSize(width: finalWidth, height: finalHeight)

        contentView.setNeedsLayout()
        contentView.layoutIfNeeded()
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }
}
#endif

#if canImport(AppKit)
@MainActor
final class WuiScroll: NSScrollView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_scroll_view_id() }

    private(set) var stretchAxis: WuiStretchAxis

    private var contentHostView: WuiAnyView
    private let axis: WuiAxis

    // MARK: - WuiComponent Init

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
        let stretchAxis = WuiStretchAxis(waterui_view_stretch_axis(anyview))
        let ffiScroll: CWaterUI.WuiScrollView = waterui_force_as_scroll_view(anyview)
        let contentView = WuiAnyView(anyview: ffiScroll.content, env: env)
        self.init(stretchAxis: stretchAxis, content: contentView, axis: ffiScroll.axis)
    }

    // MARK: - Designated Init

    init(stretchAxis: WuiStretchAxis, content: WuiAnyView, axis: WuiAxis) {
        self.stretchAxis = stretchAxis
        self.contentHostView = content
        self.axis = axis
        super.init(frame: .zero)

        let isVertical = axis == WuiAxis_Vertical || axis == WuiAxis_All
        let isHorizontal = axis == WuiAxis_Horizontal || axis == WuiAxis_All

        hasVerticalScroller = isVertical
        hasHorizontalScroller = isHorizontal
        autohidesScrollers = true

        // Use flipped document view for consistent coordinate system
        let documentView = FlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = true
        documentView.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = true

        self.documentView = documentView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - WuiComponent

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let screenSize = screen?.frame.size ?? CGSize(width: 800, height: 600)
        let width = proposal.width.map { CGFloat($0) } ?? screenSize.width
        let height = proposal.height.map { CGFloat($0) } ?? screenSize.height
        return CGSize(width: width, height: height)
    }

    override func layout() {
        super.layout()

        guard let documentView = documentView else { return }

        // Use bounds (the scroll view's actual size), not contentSize (which is the document size)
        let visibleWidth = bounds.width
        let visibleHeight = bounds.height

        let contentProposal: WuiProposalSize
        switch axis {
        case WuiAxis_Vertical:
            contentProposal = WuiProposalSize(width: Float(visibleWidth), height: nil)
        case WuiAxis_Horizontal:
            contentProposal = WuiProposalSize(width: nil, height: Float(visibleHeight))
        case WuiAxis_All:
            contentProposal = WuiProposalSize(width: nil, height: nil)
        default:
            contentProposal = WuiProposalSize(width: Float(visibleWidth), height: nil)
        }

        let measuredSize = contentHostView.sizeThatFits(contentProposal)

        let finalWidth: CGFloat
        let finalHeight: CGFloat

        switch axis {
        case WuiAxis_Vertical:
            finalWidth = visibleWidth
            finalHeight = max(measuredSize.height, visibleHeight)
        case WuiAxis_Horizontal:
            finalWidth = max(measuredSize.width, visibleWidth)
            finalHeight = visibleHeight
        case WuiAxis_All:
            finalWidth = max(measuredSize.width, visibleWidth)
            finalHeight = max(measuredSize.height, visibleHeight)
        default:
            finalWidth = visibleWidth
            finalHeight = max(measuredSize.height, visibleHeight)
        }

        let documentFrame = CGRect(x: 0, y: 0, width: finalWidth, height: finalHeight)
        documentView.frame = documentFrame
        contentHostView.frame = documentFrame

        contentHostView.needsLayout = true
        contentHostView.layoutSubtreeIfNeeded()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
}

// MARK: - Flipped Document View

private class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
#endif
