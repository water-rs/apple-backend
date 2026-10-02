//
//  Color.swift
//  waterui-swift
//
//  Created by Lexo Liu on 10/21/24.
//
@_exported import CWaterUI

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

private func wuiWorkingColorSpace() -> CGColorSpace {
  guard let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3) else {
    fatalError("Core Graphics could not create the extended-linear Display-P3 color space")
  }
  return colorSpace
}

private func wuiLinearComponents(_ color: WuiWorkingColor) -> (Float, Float, Float, Float) {
  return (
    color.red,
    color.green,
    color.blue,
    wuiClampUnit(color.alpha)
  )
}

private func wuiWorkingColor(from cgColor: CGColor) -> WuiWorkingColor? {
  guard
    let converted = cgColor.converted(
      to: wuiWorkingColorSpace(),
      intent: .defaultIntent,
      options: nil
    ),
    let components = converted.components,
    components.count >= 3
  else {
    return nil
  }
  let alpha = components.count > 3 ? components[3] : 1.0
  return WuiWorkingColor(
    red: Float(components[0]),
    green: Float(components[1]),
    blue: Float(components[2]),
    alpha: Float(alpha)
  )
}

private func wuiWorkingColorFromLinearSrgb(
  red: Float,
  green: Float,
  blue: Float,
  alpha: Float
) -> WuiWorkingColor {
  guard
    let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
    let cgColor = CGColor(
      colorSpace: colorSpace,
      components: [CGFloat(red), CGFloat(green), CGFloat(blue), CGFloat(alpha)]
    ),
    let color = wuiWorkingColor(from: cgColor)
  else {
    fatalError("Core Graphics could not convert linear sRGB to linear Display-P3")
  }
  return color
}

@MainActor
class WuiColor {
  private var inner: OpaquePointer?
  init(_ inner: OpaquePointer) {
    self.inner = inner
  }

  @MainActor deinit {
    if let inner {
      waterui_drop_color(inner)
    }
  }
}

#if canImport(UIKit)
  extension WuiWorkingColor {
    func toUIColor(allowHdr: Bool = true) -> UIColor {
      let (r, g, b, a) = wuiLinearComponents(self)
      let components = allowHdr
        ? [r, g, b, a]
        : [wuiClampUnit(r), wuiClampUnit(g), wuiClampUnit(b), a]
      guard let cgColor = CGColor(
        colorSpace: wuiWorkingColorSpace(),
        components: components.map { CGFloat($0) }
      )
      else {
        fatalError("Core Graphics could not create an extended-linear Display-P3 color")
      }
      return UIColor(cgColor: cgColor)
    }

    static func fromUIColor(_ color: UIColor) -> WuiWorkingColor {
      if let workingColor = wuiWorkingColor(from: color.cgColor) {
        return workingColor
      }

      var r: CGFloat = 0
      var g: CGFloat = 0
      var b: CGFloat = 0
      var a: CGFloat = 0
      guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else {
        fatalError("UIColor cannot convert to linear Display-P3")
      }
      return wuiWorkingColorFromLinearSrgb(
        red: wuiSrgbToLinear(Float(r)),
        green: wuiSrgbToLinear(Float(g)),
        blue: wuiSrgbToLinear(Float(b)),
        alpha: Float(a)
      )
    }
  }
#elseif canImport(AppKit)
  extension WuiWorkingColor {
    func toNSColor(allowHdr: Bool = true) -> NSColor {
      let (r, g, b, a) = wuiLinearComponents(self)
      let components = allowHdr
        ? [r, g, b, a]
        : [wuiClampUnit(r), wuiClampUnit(g), wuiClampUnit(b), a]
      guard
        let cgColor = CGColor(
          colorSpace: wuiWorkingColorSpace(),
          components: components.map { CGFloat($0) }
        ),
        let color = NSColor(cgColor: cgColor)
      else {
        fatalError("AppKit rejected an extended-linear Display-P3 color")
      }
      return color
    }

    static func fromNSColor(_ color: NSColor) -> WuiWorkingColor {
      if let workingColor = wuiWorkingColor(from: color.cgColor) {
        return workingColor
      }

      guard let converted = color.usingColorSpace(.sRGB),
        let components = converted.cgColor.components,
        components.count >= 3
      else {
        fatalError("WaterUI: NSColor '\(color)' could not be resolved to an RGB color space.")
      }
      let alpha = components.count > 3 ? components[3] : 1.0
      return wuiWorkingColorFromLinearSrgb(
        red: wuiSrgbToLinear(Float(components[0])),
        green: wuiSrgbToLinear(Float(components[1])),
        blue: wuiSrgbToLinear(Float(components[2])),
        alpha: Float(alpha)
      )
    }
  }
#endif
