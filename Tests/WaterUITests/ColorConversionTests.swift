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
  red: Float, green: Float, blue: Float, opacity: Float = 1.0, headroom: Float = 0.0
) -> WuiResolvedColor {
  WuiResolvedColor(red: red, green: green, blue: blue, opacity: opacity, headroom: headroom)
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

    @Test func headroomMapsToContentHeadroom() {
      let color = makeResolved(red: 0.5, green: 0.5, blue: 0.5, headroom: 1.0).toNSColor()
      #expect(abs(color.linearExposure - 2.0) < 1e-3)
    }

    @Test func sdrConversionClampsToUnitRange() {
      let components = components(
        of: makeResolved(red: 1.4, green: -0.2, blue: 0.3).toNSColor(allowHdr: false).cgColor)
      #expect(components[0] == 1.0)
      #expect(components[1] == 0.0)
      #expect(abs(components[2] - 0.3) < 1e-6)
    }

    @Test func fromNSColorRecoversHeadroom() {
      // `applyingContentHeadroom` records exposure without scaling components,
      // and `standardDynamicRange` tone-maps the base — so only headroom
      // round-trips for an HDR color.
      let hdr = NSColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0)
        .applyingContentHeadroom(2.0)
      let resolved = WuiResolvedColor.fromNSColor(hdr)
      #expect(abs(resolved.headroom - 1.0) < 1e-3)
    }

    @Test func resolvedColorRoundTripsThroughNSColor() {
      let original = makeResolved(red: 0.9, green: 0.4, blue: 0.1)
      let resolved = WuiResolvedColor.fromNSColor(original.toNSColor())
      #expect(abs(resolved.red - original.red) < 1e-3)
      #expect(abs(resolved.green - original.green) < 1e-3)
      #expect(abs(resolved.blue - original.blue) < 1e-3)
      #expect(abs(resolved.headroom - original.headroom) < 1e-3)
    }
  }
#endif

#if canImport(UIKit)
  @MainActor
  struct UIColorConversionTests {
    @Test func extendedRangeComponentsSurvive() {
      // Regression for water-rs/waterui#677: the UIKit conversion used to
      // clamp into sRGB and fold overflow into linearExposure, turning a
      // saturated P3 red into a brighter sRGB red.
      let resolved = makeResolved(red: 1.4, green: -0.2, blue: 0.3)
      let components = components(of: resolved.toUIColor().cgColor)
      #expect(abs(Float(components[0]) - 1.4) < 1e-4)
      #expect(abs(Float(components[1]) - -0.2) < 1e-4)
      #expect(abs(Float(components[2]) - 0.3) < 1e-4)
    }

    @Test func headroomScalesExtendedRangeComponents() {
      let components = components(
        of: makeResolved(red: 0.5, green: 0.25, blue: 0.125, headroom: 1.0).toUIColor().cgColor)
      #expect(abs(Float(components[0]) - 1.0) < 1e-4)
      #expect(abs(Float(components[1]) - 0.5) < 1e-4)
      #expect(abs(Float(components[2]) - 0.25) < 1e-4)
    }

    @Test func sdrConversionClampsToUnitRange() {
      let components = components(
        of: makeResolved(red: 1.4, green: -0.2, blue: 0.3).toUIColor(allowHdr: false).cgColor)
      #expect(components[0] == 1.0)
      #expect(components[1] == 0.0)
      #expect(abs(components[2] - 0.3) < 1e-6)
    }

    @Test func fromUIColorRecoversHeadroom() {
      let hdr = UIColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0, linearExposure: 2.0)
      let resolved = WuiResolvedColor.fromUIColor(hdr)
      #expect(abs(resolved.headroom - 1.0) < 1e-3)
    }
  }
#endif
