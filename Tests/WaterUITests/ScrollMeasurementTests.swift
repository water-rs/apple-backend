import CoreGraphics
import Testing

@testable import WaterUI

struct ScrollMeasurementTests {
  @Test func repeatedViewportOnlyMeasuresOnce() {
    var state = WuiScrollContentMeasurementState()
    let viewport = CGSize(width: 390, height: 844)

    let initialMeasurement = state.shouldMeasure(viewportSize: viewport)
    let repeatedMeasurement = state.shouldMeasure(viewportSize: viewport)

    #expect(initialMeasurement)
    #expect(!repeatedMeasurement)
  }

  @Test func viewportResizeRequiresMeasurement() {
    var state = WuiScrollContentMeasurementState()

    let portraitMeasurement = state.shouldMeasure(
      viewportSize: CGSize(width: 390, height: 844))
    let landscapeMeasurement = state.shouldMeasure(
      viewportSize: CGSize(width: 844, height: 390))

    #expect(portraitMeasurement)
    #expect(landscapeMeasurement)
  }

  @Test func descendantInvalidationRequiresMeasurementAtSameViewport() {
    var state = WuiScrollContentMeasurementState()
    let viewport = CGSize(width: 390, height: 844)

    let initialMeasurement = state.shouldMeasure(viewportSize: viewport)
    state.invalidate()
    let invalidatedMeasurement = state.shouldMeasure(viewportSize: viewport)

    #expect(initialMeasurement)
    #expect(invalidatedMeasurement)
  }
}
