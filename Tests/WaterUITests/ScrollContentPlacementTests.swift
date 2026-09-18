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

/// What a scroll answers a min-size (zero) query on its cross axis.
///
/// The content is asked the same question — zero on that axis, unspecified
/// on the scroll axis — so the answer is how narrow the content can wrap,
/// never its unwrapped ideal: the `reply` example's detail pane is a
/// paragraph 2 200 pt wide unwrapped and 48 pt at its narrowest wrap, and a
/// stack that trusted the former as the pane's floor pushed the whole row off
/// the window.
struct ScrollMinSizeTests {
  /// A paragraph: unwrapped when unspecified, wrapped to the offer, and at
  /// its longest word for a zero offer.
  private func paragraph(_ proposal: WaterUI.WuiProposalSize) -> CGSize {
    switch proposal.width {
    case .none: CGSize(width: 2200, height: 20)
    case .some(0): CGSize(width: 48, height: 900)
    case .some(let width): CGSize(width: CGFloat(width), height: 20 * ceil(2200 / CGFloat(width)))
    }
  }

  @Test func verticalScrollMinWidthIsTheContentsNarrowestWrap() {
    let size = scrollMinSize(
      axis: WuiAxis_Vertical, proposal: WaterUI.WuiProposalSize(width: 0, height: 600), measureContent: paragraph)
    #expect(size == CGSize(width: 48, height: 600))
  }

  @Test func verticalScrollMinHeightIsZero() {
    let size = scrollMinSize(
      axis: WuiAxis_Vertical, proposal: WaterUI.WuiProposalSize(width: 402, height: 0), measureContent: paragraph)
    #expect(size == CGSize(width: 402, height: 0))
  }

  @Test func horizontalScrollMinHeightIsTheContentsMinimum() {
    let size = scrollMinSize(
      axis: WuiAxis_Horizontal, proposal: WaterUI.WuiProposalSize(width: 402, height: 0)
    ) { proposal in
      proposal.height == 0 ? CGSize(width: 900, height: 32) : CGSize(width: 900, height: 200)
    }
    #expect(size == CGSize(width: 402, height: 32))
  }
}
