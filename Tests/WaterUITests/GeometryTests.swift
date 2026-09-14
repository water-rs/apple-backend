import CWaterUI
import CoreGraphics
import Testing

@testable import WaterUI

@MainActor
struct GeometryTests {
  @Test func proposalMapsNaNToNilBothWays() {
    let raw = CWaterUI.WuiProposalSize(width: 42, height: .nan)
    let proposal = WaterUI.WuiProposalSize(raw)
    #expect(proposal.width == 42)
    #expect(proposal.height == nil)

    let encoded = proposal.toCStruct()
    #expect(encoded.width == 42)
    #expect(encoded.height.isNaN)
  }

  @Test func proposalInitFromCGSize() {
    let proposal = WaterUI.WuiProposalSize(size: CGSize(width: 10, height: 20))
    #expect(proposal.width == 10)
    #expect(proposal.height == 20)
  }

  @Test func pointSizeRectRoundTripThroughCStruct() {
    let point = WaterUI.WuiPoint(CGPoint(x: 1.5, y: -2))
    #expect(point.toCStruct().x == 1.5)
    #expect(WaterUI.WuiPoint(point.toCStruct()).cgPoint == CGPoint(x: 1.5, y: -2))

    let size = WaterUI.WuiSize(CGSize(width: 3, height: 4))
    #expect(WaterUI.WuiSize(size.toCStruct()).cgSize == CGSize(width: 3, height: 4))

    let rect = WaterUI.WuiRect(CGRect(x: 1, y: 2, width: 30, height: 40))
    let roundTripped = WaterUI.WuiRect(rect.toCStruct()).cgRect
    #expect(roundTripped == CGRect(x: 1, y: 2, width: 30, height: 40))
  }

  @Test func layoutValidityChecksRejectNonFiniteValues() {
    #expect(CGFloat(1).isValidForLayout)
    #expect(CGFloat.nan.isValidForLayout == false)
    #expect(CGFloat.infinity.isValidForLayout == false)
    #expect(CGRect(x: 0, y: 0, width: 10, height: 10).isValidForLayout)
    #expect(CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10).isValidForLayout == false)
    #expect(CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 10).isValidForLayout == false)
  }

  @Test func viewIdIsValueEqualityOverThe128BitKey() {
    let first = WuiViewId(CWaterUI.WuiTypeId(low: 1, high: 2))
    let same = WuiViewId(CWaterUI.WuiTypeId(low: 1, high: 2))
    let different = WuiViewId(CWaterUI.WuiTypeId(low: 1, high: 3))
    #expect(first == same)
    #expect(first != different)
    #expect(Set([first, same, different]).count == 2)
  }

  @Test func stretchAxisBridgingIsComplete() {
    let axes: [WaterUI.WuiStretchAxis] = [
      .none, .horizontal, .vertical, .both, .mainAxis, .crossAxis,
    ]
    for axis in axes {
      #expect(WaterUI.WuiStretchAxis(axis.ffiValue) == axis)
    }
  }
}
