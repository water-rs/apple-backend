import Testing

@testable import WaterUI

@MainActor
struct WuiArrayTests {
  @Test func arrayRoundTripsThroughTheFFISurface() {
    let array = WuiArray<Int32>(array: [1, 2, 3])
    #expect(array.toArray() == [1, 2, 3])
  }

  @Test func mapTransformsInPlace() {
    let array = WuiArray<Int32>(array: [1, 2, 3])
    #expect(array.map { $0 * 2 } == [2, 4, 6])
  }

  @Test func emptyArrayReadsBackEmpty() {
    let array = WuiArray<Int32>(array: [])
    #expect(array.toArray().isEmpty)
    #expect(array.withUnsafeBufferPointer { $0.count } == 0)
  }

  @Test func wuiStrRoundTripsAString() {
    let str = WuiStr(string: "WaterUI")
    #expect(str.toString() == "WaterUI")
  }

  @Test func wuiStrRoundTripsUTF8() {
    let str = WuiStr(string: "界面🌊")
    #expect(str.toString() == "界面🌊")
  }
}
