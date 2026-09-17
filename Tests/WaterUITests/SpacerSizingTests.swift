import CWaterUI
import CoreGraphics
import Testing

@testable import WaterUI

/// A spacer's answer to a layout probe.
///
/// The framework's `SpacerLayout` answers its minimum length on both axes and
/// the stack expands the spacer along its main axis at placement. A spacer
/// that answered the proposal instead reported the offer on the cross axis
/// too: `spacer().height(8)` inside a card column measured as wide as the
/// column's offer, so a content-sized card filled its whole slot.
@MainActor
struct SpacerSizingTests {
  @Test func spacerAnswersItsMinimumLengthOnBothAxes() {
    let spacer = WuiSpacer(stretchAxis: .mainAxis)
    for proposal in [
      WaterUI.WuiProposalSize(width: 320, height: 8),
      WaterUI.WuiProposalSize(width: 320, height: nil),
      WaterUI.WuiProposalSize(width: nil, height: nil),
      WaterUI.WuiProposalSize(width: 0, height: 0),
      WaterUI.WuiProposalSize(width: .infinity, height: .infinity),
    ] {
      #expect(spacer.sizeThatFits(proposal) == .zero)
    }
  }
}
