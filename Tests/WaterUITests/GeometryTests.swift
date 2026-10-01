import CWaterUI
import CoreGraphics
import Testing

@testable import WaterUI

@MainActor
struct GeometryTests {
  @Test func proposalInitFromCGSize() {
    let proposal = WaterUI.WuiProposalSize(size: CGSize(width: 10, height: 20))
    #expect(proposal.width == 10)
    #expect(proposal.height == 20)
  }

  @Test func viewIdIsValueEqualityOverThe128BitKey() {
    let first = WuiViewId(CWaterUI.WuiTypeId(low: 1, high: 2))
    let same = WuiViewId(CWaterUI.WuiTypeId(low: 1, high: 2))
    let different = WuiViewId(CWaterUI.WuiTypeId(low: 1, high: 3))
    #expect(first == same)
    #expect(first != different)
    #expect(Set([first, same, different]).count == 2)
  }
}
