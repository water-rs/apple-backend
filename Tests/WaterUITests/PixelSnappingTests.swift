import XCTest
@testable import WaterUI

/// Regression coverage for the layout-twins a13 cells: siblings that share
/// an edge in the layout engine's fractional answer must snap to the same
/// pixel. Snapping each size on its own — nearest pixel, rounded up — made
/// three 33.33 pt fills report 34/33.5 pt apiece, overflowing a 100 pt host
/// by a point at scale 1 and overlapping by half a point at scale 2.
final class PixelSnappingTests: XCTestCase {
    /// The a13 fixture: three equal fills dividing a 100 pt host, at the
    /// fractional offsets and extents the engine emits.
    private func snappedFills(scale: CGFloat) -> [CGRect] {
        let thirds = [0.0, 33.33333333333334, 66.66666666666669]
        return thirds.map {
            pixelSnapped(CGRect(x: $0, y: 0, width: 33.33333333333334, height: 10), scale: scale)
        }
    }

    func testSharedEdgesTileWithoutOverflowAtScale1() {
        let fills = snappedFills(scale: 1)
        XCTAssertEqual(fills[0].maxX, fills[1].minX)
        XCTAssertEqual(fills[1].maxX, fills[2].minX)
        XCTAssertEqual(fills[2].maxX, 100, "last far edge must not overflow the 100 pt host")
        XCTAssertEqual(fills.map(\.width).reduce(0, +), 100)
    }

    func testSharedEdgesTileWithoutOverlapAtScale2() {
        let fills = snappedFills(scale: 2)
        XCTAssertEqual(fills[0].maxX, fills[1].minX)
        XCTAssertEqual(fills[1].maxX, fills[2].minX)
        XCTAssertEqual(fills[2].maxX, 100)
        XCTAssertEqual(fills.map(\.width).reduce(0, +), 100)
    }

    func testSharedEdgesTileAtScale3() {
        let fills = snappedFills(scale: 3)
        XCTAssertEqual(fills[2].maxX, 100)
        XCTAssertEqual(fills.map(\.width).reduce(0, +), 100)
    }

    /// A size the engine measured on the grid survives unchanged:
    /// round(x + n) - round(x) = n for a whole number of pixels, so a label
    /// that measured exactly its text keeps the width it wrapped for.
    func testIntegralPixelSizeSurvivesAFractionalOrigin() {
        for scale in [1.0, 2.0, 3.0] {
            for origin in [0.24, 0.26, 0.49, 0.51, 0.74, 0.76, 0.99] {
                let snapped = pixelSnapped(
                    CGRect(x: origin, y: 0, width: 5, height: 2.5), scale: scale)
                XCTAssertEqual(snapped.width, 5,
                               "5 pt (a whole pixel count at every scale) shrunk at scale \(scale), origin \(origin)")
            }
        }
    }

    /// At scale 3 a centred leaf sits on a half pixel, and `x * scale` and
    /// `(x + w) * scale` can fall on opposite sides of .5 by floating-point
    /// noise. Rounding both edges would then take a pixel off a label that
    /// measured exactly its text, wrapping its last word onto a hidden line
    /// — so a whole-pixel size keeps its count exactly.
    func testWholePixelSizeSurvivesHalfPixelBoundaryNoise() {
        for noise in [-1e-12, 0.0, 1e-12] {
            let snapped = pixelSnapped(
                CGRect(x: (7.5 + noise) / 3, y: 0, width: 5, height: 10),
                scale: 3)
            XCTAssertEqual(snapped.width, 5,
                           "15-px width lost a pixel at boundary noise \(noise)")
        }
    }
}
