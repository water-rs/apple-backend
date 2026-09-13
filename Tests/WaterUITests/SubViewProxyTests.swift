import CWaterUI
import CoreGraphics
import Testing

@testable import WaterUI

@MainActor
struct SubViewProxyTests {
  @Test func ffiSurfaceCarriesStretchAxisAndPriority() {
    let proxy = SubViewProxy(stretchAxis: .horizontal, priority: 3) { _ in
      WaterUI.WuiViewDimensions(size: .zero)
    }
    let subview = proxy.toBorrowedWuiSubView()
    #expect(subview.stretch_axis.rawValue == WaterUI.WuiStretchAxis.horizontal.rawValue)
    #expect(subview.priority == 3)
    #expect(subview.context != nil)
  }

  @Test func measureThroughTheVtableReturnsDimensions() throws {
    let proxy = SubViewProxy { _ in
      WaterUI.WuiViewDimensions(size: CGSize(width: 10, height: 5))
    }
    let subview = proxy.toBorrowedWuiSubView()
    let measure = try #require(subview.vtable.measure)
    let raw = measure(
      subview.context,
      WaterUI.WuiProposalSize(width: 100, height: nil).toCStruct()
    )
    let dimensions = WaterUI.WuiViewDimensions(raw)
    #expect(dimensions.cgSize == CGSize(width: 10, height: 5))
  }

  @Test func measurementsAreCachedPerProposalAndReset() throws {
    var proposals: [WaterUI.WuiProposalSize] = []
    let proxy = SubViewProxy { proposal in
      proposals.append(proposal)
      return WaterUI.WuiViewDimensions(size: CGSize(width: 10, height: 5))
    }
    let subview = proxy.toBorrowedWuiSubView()
    let measure = try #require(subview.vtable.measure)
    let proposal = WaterUI.WuiProposalSize(width: 100, height: nil).toCStruct()
    _ = measure(subview.context, proposal)
    _ = measure(subview.context, proposal)
    #expect(proposals.count == 1)
    _ = measure(
      subview.context,
      WaterUI.WuiProposalSize(width: 50, height: nil).toCStruct()
    )
    #expect(proposals.count == 2)
    proxy.resetMeasurementCache()
    _ = measure(subview.context, proposal)
    #expect(proposals.count == 3)
  }

  @Test func cachedArraySlicesToItsSubviewCount() throws {
    let first = SubViewProxy { _ in WaterUI.WuiViewDimensions(size: .zero) }
    let second = SubViewProxy { _ in WaterUI.WuiViewDimensions(size: .zero) }
    let array = CachedSubViewArray([first, second])
    let ffiArray = array.ffiArray
    let slice = try #require(ffiArray.vtable.slice)
    let result = slice(ffiArray.data)
    #expect(result.len == 2)
    #expect(result.head != nil)
  }

  @Test func emptyCachedArraySlicesToNothing() throws {
    let array = CachedSubViewArray([])
    let ffiArray = array.ffiArray
    let slice = try #require(ffiArray.vtable.slice)
    let result = slice(ffiArray.data)
    #expect(result.len == 0)
  }
}
