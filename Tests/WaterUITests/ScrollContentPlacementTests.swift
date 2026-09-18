import CWaterUI
import CoreGraphics
import Testing

@testable import WaterUI

/// Where a scroll frames its content on the non-scrolling axis.
///
/// The content keeps its own measured extent there and is centred in the
/// viewport whether it is narrower or wider, as SwiftUI's `ScrollView` lays
/// it out: the `hover` example's 414 pt rows in a 402 pt viewport are clipped
/// 6 pt on each edge instead of starting at the leading edge. The scrollable
/// extent stays the viewport's, so nothing scrolls sideways.
struct ScrollContentPlacementTests {
  private let viewport = CGSize(width: 402, height: 600)

  @Test func verticalScrollCentresWiderContentAcrossBothEdges() {
    let placement = scrollContentPlacement(
      axis: WuiAxis_Vertical, viewport: viewport,
      measured: CGSize(width: 414, height: 384))
    #expect(placement.contentFrame == CGRect(x: -6, y: 0, width: 414, height: 384))
    #expect(placement.scrollExtent == CGSize(width: 402, height: 384))
  }

  @Test func verticalScrollCentresNarrowerContent() {
    let placement = scrollContentPlacement(
      axis: WuiAxis_Vertical, viewport: viewport,
      measured: CGSize(width: 200, height: 96))
    #expect(placement.contentFrame == CGRect(x: 101, y: 0, width: 200, height: 96))
    #expect(placement.scrollExtent == CGSize(width: 402, height: 96))
  }

  @Test func horizontalScrollCentresOnTheVerticalAxis() {
    let placement = scrollContentPlacement(
      axis: WuiAxis_Horizontal, viewport: viewport,
      measured: CGSize(width: 1200, height: 640))
    #expect(placement.contentFrame == CGRect(x: 0, y: -20, width: 1200, height: 640))
    #expect(placement.scrollExtent == CGSize(width: 1200, height: 600))
  }

  @Test func bidirectionalScrollFramesTheAnswerAtTheOrigin() {
    let placement = scrollContentPlacement(
      axis: WuiAxis_All, viewport: viewport,
      measured: CGSize(width: 1200, height: 900))
    #expect(placement.contentFrame == CGRect(x: 0, y: 0, width: 1200, height: 900))
    #expect(placement.scrollExtent == CGSize(width: 1200, height: 900))
  }
}

/// What a scroll answers a measurement proposal on each axis.
///
/// A specified axis is filled with exactly what was offered. An unspecified
/// axis — `nil`, asking for the ideal, or `0`, asking for the minimum —
/// answers `0` on the scroll axis, which has no intrinsic extent to report,
/// and the content's own ideal on the cross axis. That cross-axis answer is
/// the ideal width a macOS window centres its page column on and the minimum
/// extent a minimum-size query keeps visible.
struct ScrollMinSizeTests {
  private let content = CGSize(width: 320, height: 480)

  private func measure(_: WaterUI.WuiProposalSize) -> CGSize { content }

  @Test func verticalScrollAnswersContentWidthAndZeroHeightWhenUnspecified() {
    for proposal in [WaterUI.WuiProposalSize(), WaterUI.WuiProposalSize(width: 0, height: 0)] {
      let size = scrollMinSize(
        axis: WuiAxis_Vertical, proposal: proposal, measureContent: measure)
      #expect(size == CGSize(width: 320, height: 0))
    }
  }

  @Test func verticalScrollKeepsContentWidthUnderMinimumHeightQuery() {
    let size = scrollMinSize(
      axis: WuiAxis_Vertical, proposal: WaterUI.WuiProposalSize(width: nil, height: 0),
      measureContent: measure)
    #expect(size == CGSize(width: 320, height: 0))
  }

  @Test func verticalScrollFillsSpecifiedAxesOnly() {
    #expect(
      scrollMinSize(
        axis: WuiAxis_Vertical, proposal: WaterUI.WuiProposalSize(width: nil, height: 600),
        measureContent: measure) == CGSize(width: 320, height: 600))
    #expect(
      scrollMinSize(
        axis: WuiAxis_Vertical, proposal: WaterUI.WuiProposalSize(width: 400, height: nil),
        measureContent: measure) == CGSize(width: 400, height: 0))
    #expect(
      scrollMinSize(
        axis: WuiAxis_Vertical, proposal: WaterUI.WuiProposalSize(width: 400, height: 600),
        measureContent: measure) == CGSize(width: 400, height: 600))
  }

  @Test func horizontalScrollAnswersZeroWidthAndContentHeightWhenUnspecified() {
    for proposal in [WaterUI.WuiProposalSize(), WaterUI.WuiProposalSize(width: 0, height: 0)] {
      let size = scrollMinSize(
        axis: WuiAxis_Horizontal, proposal: proposal, measureContent: measure)
      #expect(size == CGSize(width: 0, height: 480))
    }
  }

  @Test func horizontalScrollFillsSpecifiedAxesOnly() {
    #expect(
      scrollMinSize(
        axis: WuiAxis_Horizontal, proposal: WaterUI.WuiProposalSize(width: nil, height: 600),
        measureContent: measure) == CGSize(width: 0, height: 600))
    #expect(
      scrollMinSize(
        axis: WuiAxis_Horizontal, proposal: WaterUI.WuiProposalSize(width: 400, height: nil),
        measureContent: measure) == CGSize(width: 400, height: 480))
  }

  @Test func bidirectionalScrollCompressesOnBothAxes() {
    #expect(
      scrollMinSize(
        axis: WuiAxis_All, proposal: WaterUI.WuiProposalSize(), measureContent: measure)
      == .zero)
    #expect(
      scrollMinSize(
        axis: WuiAxis_All, proposal: WaterUI.WuiProposalSize(width: nil, height: 600),
        measureContent: measure) == CGSize(width: 0, height: 600))
    #expect(
      scrollMinSize(
        axis: WuiAxis_All, proposal: WaterUI.WuiProposalSize(width: 400, height: 600),
        measureContent: measure) == CGSize(width: 400, height: 600))
  }

  @Test func nonFiniteContentIdealAnswersZero() {
    let size = scrollMinSize(
      axis: WuiAxis_Vertical, proposal: WaterUI.WuiProposalSize(),
      measureContent: { _ in CGSize(width: CGFloat.infinity, height: CGFloat.infinity) })
    #expect(size == .zero)
  }
}
