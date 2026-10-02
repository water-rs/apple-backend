import CWaterUI
import CoreGraphics
import Testing

@testable import WaterUI

#if canImport(AppKit)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
#endif

private func makeResolved(
  red: Float, green: Float, blue: Float, alpha: Float = 1.0
) -> WuiWorkingColor {
  WuiWorkingColor(red: red, green: green, blue: blue, alpha: alpha)
}

private func components(of color: CGColor) -> [CGFloat] {
  guard let components = color.components else {
    fatalError("CGColor carries no components")
  }
  return components
}

@MainActor
struct ColorConversionTests {
  @Test func srgbToLinearKnownValues() {
    #expect(wuiSrgbToLinear(0) == 0)
    #expect(abs(wuiSrgbToLinear(1) - 1) < 1e-6)
    #expect(abs(wuiSrgbToLinear(0.5) - 0.214_041_14) < 1e-6)
    #expect(abs(wuiSrgbToLinear(0.040_45) - 0.040_45 / 12.92) < 1e-7)
  }
}

#if canImport(AppKit)
  @MainActor
  struct NSColorConversionTests {
    @Test func extendedRangeComponentsSurvive() {
      // A Display P3 red arrives in extended linear sRGB with components
      // outside [0, 1]; the AppKit conversion must not clip them.
      let resolved = makeResolved(red: 1.4, green: -0.2, blue: 0.3)
      let components = components(of: resolved.toNSColor().cgColor)
      #expect(abs(Float(components[0]) - 1.4) < 1e-4)
      #expect(abs(Float(components[1]) - -0.2) < 1e-4)
      #expect(abs(Float(components[2]) - 0.3) < 1e-4)
    }

    @Test func sdrConversionClampsToUnitRange() {
      let components = components(
        of: makeResolved(red: 1.4, green: -0.2, blue: 0.3).toNSColor(allowHdr: false).cgColor)
      #expect(components[0] == 1.0)
      #expect(components[1] == 0.0)
      #expect(abs(components[2] - 0.3) < 1e-6)
    }

    @Test func resolvedColorRoundTripsThroughNSColor() {
      let original = makeResolved(red: 0.9, green: 0.4, blue: 0.1)
      let resolved = WuiWorkingColor.fromNSColor(original.toNSColor())
      #expect(abs(resolved.red - original.red) < 1e-3)
      #expect(abs(resolved.green - original.green) < 1e-3)
      #expect(abs(resolved.blue - original.blue) < 1e-3)
      #expect(abs(resolved.alpha - original.alpha) < 1e-3)
    }
  }
#endif

#if canImport(UIKit)
  @MainActor
  struct UIColorConversionTests {
    @Test func extendedRangeComponentsSurvive() {
      // Regression for water-rs/waterui#677: the UIKit conversion used to
      // clamp into sRGB and fold overflow into display metadata, turning a
      // saturated P3 red into a brighter sRGB red.
      let resolved = makeResolved(red: 1.4, green: -0.2, blue: 0.3)
      let components = components(of: resolved.toUIColor().cgColor)
      #expect(abs(Float(components[0]) - 1.4) < 1e-4)
      #expect(abs(Float(components[1]) - -0.2) < 1e-4)
      #expect(abs(Float(components[2]) - 0.3) < 1e-4)
    }

    @Test func hdrChannelsRemainUnscaled() {
      let components = components(
        of: makeResolved(red: 1.4, green: 0.25, blue: 0.125).toUIColor().cgColor)
      #expect(abs(Float(components[0]) - 1.4) < 1e-4)
      #expect(abs(Float(components[1]) - 0.25) < 1e-4)
      #expect(abs(Float(components[2]) - 0.125) < 1e-4)
    }

    @Test func sdrConversionClampsToUnitRange() {
      let components = components(
        of: makeResolved(red: 1.4, green: -0.2, blue: 0.3).toUIColor(allowHdr: false).cgColor)
      #expect(components[0] == 1.0)
      #expect(components[1] == 0.0)
      #expect(abs(components[2] - 0.3) < 1e-6)
    }

  }
#endif
