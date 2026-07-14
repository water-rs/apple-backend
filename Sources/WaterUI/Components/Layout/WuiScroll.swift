// WuiScroll.swift
// Scroll view component - merged UIKit and AppKit implementation
//
// # Layout Behavior
// ScrollView fills available space when proposed, but reports 0 size when unconstrained.
// This prevents ScrollView from forcing window/parent expansion.
// Content can exceed scroll view bounds and becomes scrollable.
// Scroll direction is configured via axis parameter.
//
// // INTERNAL: Layout Contract for Backend Implementers
// // - stretchAxis: .both (greedy, fills all available space)
// // - sizeThatFits: Returns proposed size, or 0 if unspecified (no preferred size)
// // - Priority: 0 (default)

import CWaterUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

private func isMinSizeQuery(_ proposal: WuiProposalSize) -> (width: Bool, height: Bool) {
  let widthMin = proposal.width.map { $0 == 0 } ?? false
  let heightMin = proposal.height.map { $0 == 0 } ?? false
  return (widthMin, heightMin)
}

private func proposalDimension(_ value: Float?) -> CGFloat {
  value.map(CGFloat.init) ?? 0
}

private func scrollMinSize(
  axis: WuiAxis,
  proposal: WuiProposalSize,
  measureContent: (WuiProposalSize) -> CGSize
) -> CGSize {
  let minQuery = isMinSizeQuery(proposal)
  if !minQuery.width && !minQuery.height {
    return CGSize(
      width: proposalDimension(proposal.width),
      height: proposalDimension(proposal.height)
    )
  }

  let intrinsic = measureContent(WuiProposalSize(width: nil, height: nil))
  let intrinsicWidth = intrinsic.width.isFinite ? max(0, intrinsic.width) : 0
  let intrinsicHeight = intrinsic.height.isFinite ? max(0, intrinsic.height) : 0

  let proposedWidth = proposalDimension(proposal.width)
  let proposedHeight = proposalDimension(proposal.height)

  switch axis {
  case WuiAxis_Vertical:
    // Vertical scroll can compress on Y, but X should preserve content minimum.
    return CGSize(
      width: minQuery.width ? intrinsicWidth : proposedWidth,
      height: minQuery.height ? 0 : proposedHeight
    )
  case WuiAxis_Horizontal:
    // Horizontal scroll can compress on X, but Y should preserve content minimum.
    return CGSize(
      width: minQuery.width ? 0 : proposedWidth,
      height: minQuery.height ? intrinsicHeight : proposedHeight
    )
  case WuiAxis_All:
    // Bi-directional scroll allows compression on both axes.
    return CGSize(
      width: minQuery.width ? 0 : proposedWidth,
      height: minQuery.height ? 0 : proposedHeight
    )
  default:
    fatalError("Unsupported WaterUI scroll axis: \(axis.rawValue)")
  }
}

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

      // Use automatic for UINavigationController large title tracking
      // UIKit handles top (nav bar) and bottom (home indicator) insets automatically
      contentInsetAdjustmentBehavior = .automatic

      // Transparent background to avoid white flash during bounce
      backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    // MARK: - WuiComponent

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
      scrollMinSize(axis: axis, proposal: proposal) { contentProposal in
        contentView.sizeThatFits(contentProposal)
      }
    }

    override func layoutSubviews() {
      super.layoutSubviews()

      // Do NOT manually adjust contentInset - trust UIKit's .automatic behavior
      // UIKit adds top inset for nav bar, bottom inset for home indicator automatically

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
        fatalError("Unsupported WaterUI scroll axis: \(axis.rawValue)")
      }

      let measuredSize = contentView.sizeThatFits(contentProposal)

      let finalWidth: CGFloat
      let finalHeight: CGFloat

      switch axis {
      case WuiAxis_Vertical:
        finalWidth = bounds.width
        finalHeight = measuredSize.height
      case WuiAxis_Horizontal:
        finalWidth = measuredSize.width
        finalHeight = bounds.height
      case WuiAxis_All:
        finalWidth = measuredSize.width
        finalHeight = measuredSize.height
      default:
        fatalError("Unsupported WaterUI scroll axis: \(axis.rawValue)")
      }

      // Only update frame when changed to avoid recursive layout loops
      let newFrame = CGRect(x: 0, y: 0, width: finalWidth, height: finalHeight)
      if contentView.frame != newFrame {
        contentView.frame = newFrame
        contentSize = CGSize(width: finalWidth, height: finalHeight)
        contentView.setNeedsLayout()
        contentView.layoutIfNeeded()
      }
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
      scrollMinSize(axis: axis, proposal: proposal) { contentProposal in
        contentHostView.sizeThatFits(contentProposal)
      }
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
        fatalError("Unsupported WaterUI scroll axis: \(axis.rawValue)")
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
        fatalError("Unsupported WaterUI scroll axis: \(axis.rawValue)")
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
