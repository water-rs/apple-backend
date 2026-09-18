//
//  Color.swift
//  waterui-swift
//
//  Created by Lexo Liu on 10/21/24.
//
import CWaterUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

func wuiSrgbToLinear(_ srgb: Float) -> Float {
  if srgb <= 0.040_45 {
    return srgb / 12.92
  }
  return pow((srgb + 0.055) / 1.055, 2.4)
}

private func wuiClampUnit(_ value: Float) -> Float {
  min(max(value, 0.0), 1.0)
}

private func wuiHeadroomScale(_ headroom: Float) -> Float {
  precondition(headroom.isFinite && headroom >= 0, "Color headroom must be finite and non-negative")
  return 1.0 + headroom
}

private func wuiLinearComponents(_ color: WuiResolvedColor) -> (Float, Float, Float, Float) {
  let scale = wuiHeadroomScale(color.headroom)
  return (
    color.red * scale,
    color.green * scale,
    color.blue * scale,
    wuiClampUnit(color.opacity)
  )
}

@MainActor
class WuiColor {
  private var inner: OpaquePointer?
  init(_ inner: OpaquePointer) {
    self.inner = inner
  }

  func resolve(in env: WuiEnvironment) -> WuiComputed<WuiResolvedColor> {
    guard let inner else {
      fatalError("WuiColor pointer was already consumed")
    }
    let computed = waterui_resolve_color(inner, env.inner)
    return WuiComputed(computed!)
  }

  func intoInner() -> OpaquePointer {
    guard let inner else {
      fatalError("WuiColor pointer was already consumed")
    }
    self.inner = nil
    return inner
  }

  @MainActor deinit {
    if let inner {
      waterui_drop_color(inner)
    }
  }
}

#if canImport(UIKit)
  extension WuiResolvedColor {
    func toUIColor(allowHdr: Bool = true) -> UIColor {
      if allowHdr {
        // UIColor carries an extended-range CGColor verbatim: unclamped
        // components preserve both the wide gamut and, through the headroom
        // scale, HDR range — matching the AppKit path below.
        let (r, g, b, a) = wuiLinearComponents(self)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
          let cgColor = CGColor(
            colorSpace: colorSpace,
            components: [CGFloat(r), CGFloat(g), CGFloat(b), CGFloat(a)]
          )
        else {
          fatalError("Core Graphics could not create an extended-linear sRGB color")
        }
        return UIColor(cgColor: cgColor)
      }

      let (r, g, b, a) = wuiLinearComponents(self)

      guard let colorSpace = CGColorSpace(name: CGColorSpace.linearSRGB),
        let cgColor = CGColor(
          colorSpace: colorSpace,
          components: [
            CGFloat(wuiClampUnit(r)),
            CGFloat(wuiClampUnit(g)),
            CGFloat(wuiClampUnit(b)),
            CGFloat(a),
          ]
        )
      else {
        fatalError("Core Graphics could not create a linear sRGB color")
      }
      return UIColor(cgColor: cgColor)
    }

    static func fromUIColor(_ color: UIColor) -> WuiResolvedColor {
      var headroom: Float = 0.0
      var sourceColor = color
      let exposure = color.linearExposure
      if exposure > 1.0 {
        headroom = Float(exposure - 1.0)
        sourceColor = color.standardDynamicRange
      }

      if let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
        let converted = sourceColor.cgColor.converted(
          to: colorSpace,
          intent: .defaultIntent,
          options: nil
        ),
        let components = converted.components,
        components.count >= 3
      {
        let alpha = components.count > 3 ? components[3] : 1.0
        return WuiResolvedColor(
          red: Float(components[0]),
          green: Float(components[1]),
          blue: Float(components[2]),
          opacity: Float(alpha),
          headroom: headroom
        )
      }

      var r: CGFloat = 0
      var g: CGFloat = 0
      var b: CGFloat = 0
      var a: CGFloat = 0
      guard sourceColor.getRed(&r, green: &g, blue: &b, alpha: &a) else {
        fatalError("UIColor cannot convert to extended linear sRGB")
      }
      return WuiResolvedColor(
        red: wuiSrgbToLinear(Float(r)),
        green: wuiSrgbToLinear(Float(g)),
        blue: wuiSrgbToLinear(Float(b)),
        opacity: Float(a),
        headroom: headroom
      )
    }
  }
#elseif canImport(AppKit)
  extension WuiResolvedColor {
    func toNSColor(allowHdr: Bool = true) -> NSColor {
      let alpha = wuiClampUnit(self.opacity)
      let base = (self.red, self.green, self.blue)

      if allowHdr, self.headroom > 0.0 {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
          let cgColor = CGColor(
            colorSpace: colorSpace,
            components: [CGFloat(base.0), CGFloat(base.1), CGFloat(base.2), CGFloat(alpha)]
          ),
          let baseColor = NSColor(cgColor: cgColor)
        else {
          fatalError("AppKit rejected a valid HDR color")
        }
        return baseColor.applyingContentHeadroom(CGFloat(wuiHeadroomScale(self.headroom)))
      }

      let (r, g, b, a) = wuiLinearComponents(self)

      if allowHdr {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
          let cgColor = CGColor(
            colorSpace: colorSpace,
            components: [CGFloat(r), CGFloat(g), CGFloat(b), CGFloat(a)]
          ),
          let color = NSColor(cgColor: cgColor)
        else {
          fatalError("AppKit rejected a valid extended-linear sRGB CGColor")
        }
        return color
      }

      guard let colorSpace = CGColorSpace(name: CGColorSpace.linearSRGB),
        let cgColor = CGColor(
          colorSpace: colorSpace,
          components: [
            CGFloat(wuiClampUnit(r)),
            CGFloat(wuiClampUnit(g)),
            CGFloat(wuiClampUnit(b)),
            CGFloat(a),
          ]
        ),
        let color = NSColor(cgColor: cgColor)
      else {
        fatalError("AppKit rejected a valid linear sRGB color")
      }
      return color
    }

    static func fromNSColor(_ color: NSColor) -> WuiResolvedColor {
      var headroom: Float = 0.0
      var sourceColor = color
      let exposure = color.linearExposure
      if exposure > 1.0 {
        headroom = Float(exposure - 1.0)
        sourceColor = color.standardDynamicRange
      }

      func components(in colorSpace: NSColorSpace) -> (CGFloat, CGFloat, CGFloat, CGFloat)? {
        guard let converted = sourceColor.usingColorSpace(colorSpace),
          let components = converted.cgColor.components,
          components.count >= 3
        else {
          return nil
        }
        let alpha = components.count > 3 ? components[3] : 1.0
        return (components[0], components[1], components[2], alpha)
      }

      if let (r, g, b, a) = components(in: .extendedSRGB) {
        return WuiResolvedColor(
          red: wuiSrgbToLinear(Float(r)),
          green: wuiSrgbToLinear(Float(g)),
          blue: wuiSrgbToLinear(Float(b)),
          opacity: Float(a),
          headroom: headroom
        )
      }

      if let (r, g, b, a) = components(in: .sRGB) {
        return WuiResolvedColor(
          red: wuiSrgbToLinear(Float(r)),
          green: wuiSrgbToLinear(Float(g)),
          blue: wuiSrgbToLinear(Float(b)),
          opacity: Float(a),
          headroom: headroom
        )
      }

      fatalError("WaterUI: NSColor '\(color)' could not be resolved to an RGB color space.")
    }
  }
#endif

extension WuiResolvedColor {
  func toPlatformColor(allowHdr: Bool = true) -> PlatformColor {
    #if canImport(UIKit)
      return toUIColor(allowHdr: allowHdr)
    #elseif canImport(AppKit)
      return toNSColor(allowHdr: allowHdr)
    #endif
  }
}
