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
    if #available(iOS 26.0, tvOS 26.0, visionOS 26.0, watchOS 26.0, macCatalyst 26.0, *) {
        return true
    }
    return false
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
        let alpha = wuiClampUnit(self.opacity)

        if allowHdr,
           wuiSupportsExtendedRange(),
           #available(iOS 26.0, tvOS 26.0, visionOS 26.0, watchOS 26.0, macCatalyst 26.0, *) {
            let exposure = max(1.0, 1.0 + CGFloat(self.headroom))

            // UIColor's HDR initializer expects SDR (nominal [0..1]) components. Our resolved color is stored
            // in linear space, so convert to sRGB before constructing the base SDR color.
            var r = wuiLinearToSrgb(self.red)
            var g = wuiLinearToSrgb(self.green)
            var b = wuiLinearToSrgb(self.blue)

            // If upstream provides linear components outside [0..1], normalize into the exposure to keep
            // the base SDR color in-range while preserving the intended output.
            let maxLinear = max(self.red, self.green, self.blue)
            if maxLinear > 1.0 {
                let mergedExposure = max(exposure, CGFloat(maxLinear))
                let inv = 1.0 / Float(mergedExposure)
                r = wuiLinearToSrgb(self.red * inv)
                g = wuiLinearToSrgb(self.green * inv)
                b = wuiLinearToSrgb(self.blue * inv)
                return UIColor(
                    red: CGFloat(wuiClampUnit(r)),
                    green: CGFloat(wuiClampUnit(g)),
                    blue: CGFloat(wuiClampUnit(b)),
                    alpha: CGFloat(alpha),
                    linearExposure: mergedExposure
                )
            }

            return UIColor(
                red: CGFloat(wuiClampUnit(r)),
                green: CGFloat(wuiClampUnit(g)),
                blue: CGFloat(wuiClampUnit(b)),
                alpha: CGFloat(alpha),
                linearExposure: exposure
            )
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

        func components(in colorSpace: NSColorSpace) -> (CGFloat, CGFloat, CGFloat, CGFloat)? {
            guard let converted = sourceColor.usingColorSpace(colorSpace),
                  let components = converted.cgColor.components,
                  components.count >= 3 else {
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
