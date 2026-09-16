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

  @Test func measurementsAreCachedPerProposalWithinTheProxyLifetime() throws {
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
  }

  @Test func rebuildingTheArrayRefreshesMeasurementsAndSlotTraits() throws {
    var width: CGFloat = 10
    var calls = 0
    func makeArray(priority: Int32) -> CachedSubViewArray {
      CachedSubViewArray([SubViewProxy(stretchAxis: .horizontal, priority: priority) { _ in
        calls += 1
        return WaterUI.WuiViewDimensions(size: CGSize(width: width, height: 5))
      }])
    }
    func measure(_ array: CachedSubViewArray, priority: Int32) throws -> CGFloat {
      let ffi = array.ffiArray
      let sliceFunction = try #require(ffi.vtable.slice)
      let slice = sliceFunction(ffi.data)
      let head = try #require(slice.head)
      let child = head.pointee
      #expect(child.priority == priority)
      let measureFunction = try #require(child.vtable.measure)
      let result = measureFunction(
        child.context, WaterUI.WuiProposalSize(width: 100, height: nil).toCStruct())
      return WaterUI.WuiViewDimensions(result).cgSize.width
    }
    let old = makeArray(priority: 0)
    #expect(try measure(old, priority: 0) == 10)
    width = 30
    #expect(try measure(old, priority: 0) == 10)
    let rebuilt = makeArray(priority: 5)
    #expect(try measure(rebuilt, priority: 5) == 30)
    #expect(calls == 2)
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
