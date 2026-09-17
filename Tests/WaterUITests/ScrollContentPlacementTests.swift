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
