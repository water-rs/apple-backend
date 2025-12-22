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

func wuiLinearToSrgb(_ linear: Float) -> Float {
    if linear <= 0.003_130_8 {
        return linear * 12.92
    }
    return 1.055 * pow(linear, 1.0 / 2.4) - 0.055
}

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
    if headroom.isFinite && headroom > 0.0 {
        return 1.0 + headroom
    }
    return 1.0
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

#if canImport(UIKit)
private func wuiSupportsExtendedRange() -> Bool {
    UIScreen.main.maximumExtendedDynamicRangeColorComponentValue > 1.0
}
#elseif canImport(AppKit)
private func wuiSupportsExtendedRange() -> Bool {
    let screen = NSScreen.main
    if (screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1.0) > 1.0 {
        return true
    }
    return (screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0) > 1.0
}
#endif


@MainActor
class WuiColor {
    var inner: OpaquePointer
    init(_ inner: OpaquePointer) {
        self.inner = inner
    }

    func resolve(in env: WuiEnvironment) -> WuiComputed<WuiResolvedColor> {
        let computed = waterui_resolve_color(inner, env.inner)
        return WuiComputed(computed!)
    }

    @MainActor deinit {
        waterui_drop_color(inner)
    }
}

#if canImport(UIKit)
extension WuiResolvedColor {
    func toUIColor(allowHdr: Bool = true) -> UIColor {
        let base = (self.red, self.green, self.blue)
        let alpha = wuiClampUnit(self.opacity)

        if allowHdr,
           wuiSupportsExtendedRange(),
           self.headroom > 0.0,
           #available(iOS 26.0, tvOS 26.0, visionOS 26.0, watchOS 26.0, macCatalyst 26.0, *),
           let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
            let cgColor = CGColor(
               colorSpace: colorSpace,
               components: [CGFloat(base.0), CGFloat(base.1), CGFloat(base.2), CGFloat(alpha)]
           ) {
            return UIColor(cgColor: cgColor)
                .applyingContentHeadroom(max(1.0, 1.0 + CGFloat(self.headroom)))
        }

        let (r, g, b, a) = wuiLinearComponents(self)

        if allowHdr,
           wuiSupportsExtendedRange(),
           let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
           let cgColor = CGColor(
               colorSpace: colorSpace,
               components: [CGFloat(r), CGFloat(g), CGFloat(b), CGFloat(a)]
           ) {
            return UIColor(cgColor: cgColor)
        }

        if let colorSpace = CGColorSpace(name: CGColorSpace.linearSRGB),
           let cgColor = CGColor(
               colorSpace: colorSpace,
               components: [
                   CGFloat(wuiClampUnit(r)),
                   CGFloat(wuiClampUnit(g)),
                   CGFloat(wuiClampUnit(b)),
                   CGFloat(a),
               ]
           ) {
            return UIColor(cgColor: cgColor)
        }

        let srgbR = wuiLinearToSrgb(wuiClampUnit(r))
        let srgbG = wuiLinearToSrgb(wuiClampUnit(g))
        let srgbB = wuiLinearToSrgb(wuiClampUnit(b))
        return UIColor(
            red: CGFloat(wuiClampUnit(srgbR)),
            green: CGFloat(wuiClampUnit(srgbG)),
            blue: CGFloat(wuiClampUnit(srgbB)),
            alpha: CGFloat(a)
        )
    }

    static func fromUIColor(_ color: UIColor) -> WuiResolvedColor {
        var headroom: Float = 0.0
        var sourceColor = color
        if #available(iOS 26.0, tvOS 26.0, visionOS 26.0, watchOS 26.0, macCatalyst 26.0, *) {
            let exposure = color.linearExposure
            if exposure > 1.0 {
                headroom = Float(exposure - 1.0)
                sourceColor = color.standardDynamicRange
            }
        }

        if let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
           let converted = sourceColor.cgColor.converted(
               to: colorSpace,
               intent: .defaultIntent,
               options: nil
           ),
           let components = converted.components,
           components.count >= 3 {
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
            return WuiResolvedColor()
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

        if allowHdr,
           self.headroom > 0.0,
           #available(macOS 26.0, *),
           let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
           let cgColor = CGColor(
               colorSpace: colorSpace,
               components: [CGFloat(base.0), CGFloat(base.1), CGFloat(base.2), CGFloat(alpha)]
           ),
           let baseColor = NSColor(cgColor: cgColor) {
            return baseColor
                .applyingContentHeadroom(max(1.0, 1.0 + CGFloat(self.headroom)))
        }

        let (r, g, b, a) = wuiLinearComponents(self)

        if allowHdr,
           wuiSupportsExtendedRange(),
           let colorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
           let cgColor = CGColor(
               colorSpace: colorSpace,
               components: [CGFloat(r), CGFloat(g), CGFloat(b), CGFloat(a)]
           ) {
            return NSColor(cgColor: cgColor) ?? NSColor.systemBlue
        }

        if let colorSpace = CGColorSpace(name: CGColorSpace.linearSRGB),
           let cgColor = CGColor(
               colorSpace: colorSpace,
               components: [
                   CGFloat(wuiClampUnit(r)),
                   CGFloat(wuiClampUnit(g)),
                   CGFloat(wuiClampUnit(b)),
                   CGFloat(a),
               ]
           ) {
            return NSColor(cgColor: cgColor) ?? NSColor.systemBlue
        }

        let srgbR = wuiLinearToSrgb(wuiClampUnit(r))
        let srgbG = wuiLinearToSrgb(wuiClampUnit(g))
        let srgbB = wuiLinearToSrgb(wuiClampUnit(b))
        return NSColor(
            srgbRed: CGFloat(wuiClampUnit(srgbR)),
            green: CGFloat(wuiClampUnit(srgbG)),
            blue: CGFloat(wuiClampUnit(srgbB)),
            alpha: CGFloat(a)
        )
    }

    static func fromNSColor(_ color: NSColor) -> WuiResolvedColor {
        var headroom: Float = 0.0
        var sourceColor = color
        if #available(macOS 26.0, *) {
            let exposure = color.linearExposure
            if exposure > 1.0 {
                headroom = Float(exposure - 1.0)
                sourceColor = color.standardDynamicRange
            }
        }

        func components(in colorSpaceName: CFString) -> (CGFloat, CGFloat, CGFloat, CGFloat)? {
            guard let colorSpace = CGColorSpace(name: colorSpaceName),
                  let converted = sourceColor.cgColor.converted(
                      to: colorSpace,
                      intent: .defaultIntent,
                      options: nil
                  ),
                  let components = converted.components,
                  components.count >= 3
            else {
                return nil
            }
            let alpha = components.count > 3 ? components[3] : 1.0
            return (components[0], components[1], components[2], alpha)
        }

        if let (r, g, b, a) = components(in: CGColorSpace.extendedLinearSRGB) {
            return WuiResolvedColor(
                red: Float(r),
                green: Float(g),
                blue: Float(b),
                opacity: Float(a),
                headroom: headroom
            )
        }

        if let (r, g, b, a) = components(in: CGColorSpace.linearSRGB) {
            return WuiResolvedColor(
                red: Float(r),
                green: Float(g),
                blue: Float(b),
                opacity: Float(a),
                headroom: headroom
            )
        }

        if let (r, g, b, a) = components(in: CGColorSpace.extendedSRGB) {
            return WuiResolvedColor(
                red: wuiSrgbToLinear(Float(r)),
                green: wuiSrgbToLinear(Float(g)),
                blue: wuiSrgbToLinear(Float(b)),
                opacity: Float(a),
                headroom: headroom
            )
        }

        if let (r, g, b, a) = components(in: CGColorSpace.sRGB) {
            return WuiResolvedColor(
                red: wuiSrgbToLinear(Float(r)),
                green: wuiSrgbToLinear(Float(g)),
                blue: wuiSrgbToLinear(Float(b)),
                opacity: Float(a),
                headroom: headroom
            )
        }

        return WuiResolvedColor()
    }
}
#endif
