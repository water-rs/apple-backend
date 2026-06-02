import CWaterUI
import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@_silgen_name("waterui_font_from_resolved")
private func wui_font_from_resolved(
    _ _: Float,
    _ _: CWaterUI.WuiFontWeight,
    _ _: CWaterUI.WuiStr
) -> OpaquePointer?

@MainActor
struct WuiStyledStr {
    var chunks: [WuiStyledChunk]

    init(_ inner: CWaterUI.WuiStyledStr) {
        self.chunks = []
        for chunk in WuiArray(inner.chunks).toArray() {
            chunks.append(WuiStyledChunk(chunk))
        }
    }

    init(chunks: [WuiStyledChunk]) {
        self.chunks = chunks
    }

    static func fromAttributedString(_ attributed: NSAttributedString) -> WuiStyledStr {
        let nsText = attributed.string as NSString
        if attributed.length == 0 {
            return WuiStyledStr(chunks: [WuiStyledChunk(text: "", style: WuiTextStyle.defaultStyle())])
        }

        var chunks: [WuiStyledChunk] = []
        let fullRange = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttributes(in: fullRange, options: []) { attributes, range, _ in
            guard range.length > 0 else { return }
            let text = nsText.substring(with: range)
            let style = WuiTextStyle.fromAttributes(attributes)
            chunks.append(WuiStyledChunk(text: text, style: style))
        }

        if chunks.isEmpty {
            chunks.append(WuiStyledChunk(text: attributed.string, style: WuiTextStyle.defaultStyle()))
        }

        return WuiStyledStr(chunks: chunks)
    }

    func toAttributedString(env: WuiEnvironment) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for chunk in chunks {
            result.append(chunk.toAttributedString(env: env))
        }
        return result
    }

    func toString() -> String {
        chunks.map { $0.text.toString() }.joined()
    }

    mutating func intoInner() -> CWaterUI.WuiStyledStr {
        var ffiChunks: [CWaterUI.WuiStyledChunk] = []
        ffiChunks.reserveCapacity(chunks.count)

        for index in chunks.indices {
            var chunk = chunks[index]
            ffiChunks.append(chunk.intoInner())
        }

        let chunkArray = WuiArray<CWaterUI.WuiStyledChunk>(array: ffiChunks).intoInner()
        let typedArray = unsafeBitCast(chunkArray, to: CWaterUI.WuiArray_WuiStyledChunk.self)
        return CWaterUI.WuiStyledStr(chunks: typedArray)
    }
}

@MainActor
struct WuiStyledChunk {
    var text: WuiStr
    var style: WuiTextStyle

    init(_ inner: CWaterUI.WuiStyledChunk) {
        self.text = WuiStr(inner.text)
        self.style = WuiTextStyle(inner.style)
    }

    init(text: String, style: WuiTextStyle) {
        self.text = WuiStr(string: text)
        self.style = style
    }

    func toAttributedString(env: WuiEnvironment) -> NSAttributedString {
        let resolvedFont = style.font.resolve(in: env).value
        let font = resolvedFont.toPlatformFont()

        var attributes: [NSAttributedString.Key: Any] = [
            .font: font
        ]

        let resolvedForeground: WuiResolvedColor?
        if let foreground = style.foreground {
            resolvedForeground = foreground.resolve(in: env).value
        } else {
            // Fall back to env's Foreground slot so the `.foreground()` view
            // modifier (which installs a ForegroundOverride) takes effect on
            // text that doesn't carry an explicit color.
            let computedPtr = waterui_theme_color(env.inner, WuiColorSlot_Foreground)
            if let computedPtr {
                resolvedForeground = WuiComputed<WuiResolvedColor>(computedPtr).value
            } else {
                resolvedForeground = nil
            }
        }
        if let resolvedColor = resolvedForeground {
            #if canImport(UIKit)
            attributes[.foregroundColor] = resolvedColor.toUIColor()
            #elseif canImport(AppKit)
            attributes[.foregroundColor] = resolvedColor.toNSColor()
            #endif
        }

        if let background = style.background {
            let resolvedColor = background.resolve(in: env).value
            #if canImport(UIKit)
            attributes[.backgroundColor] = resolvedColor.toUIColor()
            #elseif canImport(AppKit)
            attributes[.backgroundColor] = resolvedColor.toNSColor()
            #endif
        }

        if style.underline {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }

        if style.strikethrough {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }

        var finalFont = font
        if style.italic {
            #if canImport(UIKit)
            if let descriptor = font.fontDescriptor.withSymbolicTraits(.traitItalic) {
                finalFont = UIFont(descriptor: descriptor, size: font.pointSize)
            }
            #elseif canImport(AppKit)
            let descriptor = font.fontDescriptor.withSymbolicTraits(.italic)
            finalFont = NSFont(descriptor: descriptor, size: font.pointSize) ?? font
            #endif
            attributes[.font] = finalFont
        }

        return NSAttributedString(string: text.toString(), attributes: attributes)
    }

    mutating func intoInner() -> CWaterUI.WuiStyledChunk {
        CWaterUI.WuiStyledChunk(
            text: text.intoInner(),
            style: style.intoInner()
        )
    }
}

@MainActor
struct WuiTextStyle {
    var font: WuiFont
    var foreground: WuiColor?
    var background: WuiColor?
    var underline: Bool
    var strikethrough: Bool
    var italic: Bool

    init(_ inner: CWaterUI.WuiTextStyle) {
        self.font = WuiFont(inner.font)
        if inner.foreground != nil {
            self.foreground = WuiColor(inner.foreground)
        }

        if inner.background != nil {
            self.background = WuiColor(inner.background)
        }

        self.underline = inner.underline
        self.strikethrough = inner.strikethrough
        self.italic = inner.italic
    }

    init(
        font: WuiFont,
        foreground: WuiColor?,
        background: WuiColor?,
        underline: Bool,
        strikethrough: Bool,
        italic: Bool
    ) {
        self.font = font
        self.foreground = foreground
        self.background = background
        self.underline = underline
        self.strikethrough = strikethrough
        self.italic = italic
    }

    static func defaultStyle() -> WuiTextStyle {
        #if canImport(UIKit)
        let platformFont = UIFont.systemFont(ofSize: UIFont.systemFontSize)
        #elseif canImport(AppKit)
        let platformFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        #endif
        return WuiTextStyle(
            font: wuiFont(from: platformFont),
            foreground: nil,
            background: nil,
            underline: false,
            strikethrough: false,
            italic: false
        )
    }

    static func fromAttributes(_ attributes: [NSAttributedString.Key: Any]) -> WuiTextStyle {
        #if canImport(UIKit)
        let platformFont = (attributes[.font] as? UIFont) ?? UIFont.systemFont(ofSize: UIFont.systemFontSize)
        #elseif canImport(AppKit)
        let platformFont = (attributes[.font] as? NSFont) ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        #endif

        let underlineValue = (attributes[.underlineStyle] as? NSNumber)?.intValue ?? 0
        let strikethroughValue = (attributes[.strikethroughStyle] as? NSNumber)?.intValue ?? 0

        #if canImport(UIKit)
        let italic = platformFont.fontDescriptor.symbolicTraits.contains(.traitItalic)
        let foreground = wuiColor(from: attributes[.foregroundColor] as? UIColor)
        let background = wuiColor(from: attributes[.backgroundColor] as? UIColor)
        #elseif canImport(AppKit)
        let italic = platformFont.fontDescriptor.symbolicTraits.contains(.italic)
        let foreground = wuiColor(from: attributes[.foregroundColor] as? NSColor)
        let background = wuiColor(from: attributes[.backgroundColor] as? NSColor)
        #endif

        return WuiTextStyle(
            font: wuiFont(from: platformFont),
            foreground: foreground,
            background: background,
            underline: underlineValue != 0,
            strikethrough: strikethroughValue != 0,
            italic: italic
        )
    }

    mutating func intoInner() -> CWaterUI.WuiTextStyle {
        let fontPtr = font.intoInner()

        var foregroundPtr: OpaquePointer?
        if let foreground {
            foregroundPtr = foreground.intoInner()
        }

        var backgroundPtr: OpaquePointer?
        if let background {
            if let foreground, background === foreground {
                backgroundPtr = foregroundPtr
            } else {
                backgroundPtr = background.intoInner()
            }
        }

        return CWaterUI.WuiTextStyle(
            font: fontPtr,
            italic: italic,
            underline: underline,
            strikethrough: strikethrough,
            foreground: foregroundPtr,
            background: backgroundPtr
        )
    }
}

extension WuiResolvedFont {
    #if canImport(UIKit)
    func toPlatformFont() -> UIFont {
        let resolvedSize = CGFloat(self.size)
        let size = resolvedSize > 0 ? resolvedSize : UIFont.systemFontSize
        let weight = self.weight.toUIFontWeight()

        let familyName = WuiStr(self.family).toString()
        if !familyName.isEmpty {
            if let genericFont = genericUIFont(familyName: familyName, size: size, weight: weight) {
                return genericFont
            }
            if let customFont = UIFont(name: familyName, size: size) {
                return customFont
            }
            fatalError("WaterUI: Font family '\(familyName)' not found. Ensure the font is bundled and registered.")
        }

        return UIFont.systemFont(ofSize: size, weight: weight)
    }
    #elseif canImport(AppKit)
    func toPlatformFont() -> NSFont {
        let resolvedSize = CGFloat(self.size)
        let size = resolvedSize > 0 ? resolvedSize : NSFont.systemFontSize
        let weight = self.weight.toNSFontWeight()

        let familyName = WuiStr(self.family).toString()
        if !familyName.isEmpty {
            if let genericFont = genericNSFont(familyName: familyName, size: size, weight: weight) {
                return genericFont
            }
            if let customFont = NSFont(name: familyName, size: size) {
                return customFont
            }
            fatalError("WaterUI: Font family '\(familyName)' not found. Ensure the font is bundled and registered.")
        }

        return NSFont.systemFont(ofSize: size, weight: weight)
    }
    #endif
}

#if canImport(UIKit)
private func genericUIFont(familyName: String, size: CGFloat, weight: UIFont.Weight) -> UIFont? {
    switch familyName {
    case "monospace":
        return UIFont.monospacedSystemFont(ofSize: size, weight: weight)
    case "system", "sans-serif":
        return UIFont.systemFont(ofSize: size, weight: weight)
    default:
        return nil
    }
}

extension CWaterUI.WuiFontWeight {
    func toUIFontWeight() -> UIFont.Weight {
        switch self {
        case WuiFontWeight_Thin: return .thin
        case WuiFontWeight_UltraLight: return .ultraLight
        case WuiFontWeight_Light: return .light
        case WuiFontWeight_Normal: return .regular
        case WuiFontWeight_Medium: return .medium
        case WuiFontWeight_SemiBold: return .semibold
        case WuiFontWeight_Bold: return .bold
        case WuiFontWeight_UltraBold: return .heavy
        case WuiFontWeight_Black: return .black
        default: return .regular
        }
    }
}
#elseif canImport(AppKit)
private func genericNSFont(familyName: String, size: CGFloat, weight: NSFont.Weight) -> NSFont? {
    switch familyName {
    case "monospace":
        return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    case "system", "sans-serif":
        return NSFont.systemFont(ofSize: size, weight: weight)
    default:
        return nil
    }
}

extension CWaterUI.WuiFontWeight {
    func toNSFontWeight() -> NSFont.Weight {
        switch self {
        case WuiFontWeight_Thin: return .thin
        case WuiFontWeight_UltraLight: return .ultraLight
        case WuiFontWeight_Light: return .light
        case WuiFontWeight_Normal: return .regular
        case WuiFontWeight_Medium: return .medium
        case WuiFontWeight_SemiBold: return .semibold
        case WuiFontWeight_Bold: return .bold
        case WuiFontWeight_UltraBold: return .heavy
        case WuiFontWeight_Black: return .black
        default: return .regular
        }
    }
}
#endif

@MainActor
class WuiFont {
    private var inner: OpaquePointer?

    init(_ inner: OpaquePointer) {
        self.inner = inner
    }

    func resolve(in env: WuiEnvironment) -> WuiComputed<CWaterUI.WuiResolvedFont> {
        guard let inner else {
            fatalError("WuiFont pointer was already consumed")
        }
        let computedPtr = waterui_resolve_font(inner, env.inner)
        return WuiComputed<CWaterUI.WuiResolvedFont>(computedPtr!)
    }

    func intoInner() -> OpaquePointer {
        guard let inner else {
            fatalError("WuiFont pointer was already consumed")
        }
        self.inner = nil
        return inner
    }

    @MainActor deinit {
        if let inner {
            waterui_drop_font(inner)
        }
    }
}

#if canImport(UIKit)
@MainActor
private func wuiColor(from color: UIColor?) -> WuiColor? {
    guard let color else { return nil }

    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
        return nil
    }

    guard let pointer = waterui_color_from_srgba(Float(red), Float(green), Float(blue), Float(alpha)) else {
        return nil
    }
    return WuiColor(pointer)
}

@MainActor
private func wuiFont(from font: UIFont) -> WuiFont {
    let weight = wuiFontWeight(from: font)
    let family = WuiStr(string: font.fontName)
    guard let pointer = wui_font_from_resolved(Float(font.pointSize), weight, family.intoInner()) else {
        fatalError("Failed to create WuiFont from UIFont")
    }
    return WuiFont(pointer)
}

private func wuiFontWeight(from font: UIFont) -> CWaterUI.WuiFontWeight {
    let traits = font.fontDescriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
    let raw = (traits?[.weight] as? CGFloat) ?? 0

    switch raw {
    case ...(-0.8): return WuiFontWeight_Thin
    case (-0.8) ... (-0.6): return WuiFontWeight_UltraLight
    case (-0.6) ... (-0.4): return WuiFontWeight_Light
    case (-0.4) ... (0.0): return WuiFontWeight_Normal
    case (0.0) ... (0.23): return WuiFontWeight_Medium
    case (0.23) ... (0.3): return WuiFontWeight_SemiBold
    case (0.3) ... (0.5): return WuiFontWeight_Bold
    case (0.5) ... (0.8): return WuiFontWeight_UltraBold
    default: return WuiFontWeight_Black
    }
}
#elseif canImport(AppKit)
@MainActor
private func wuiColor(from color: NSColor?) -> WuiColor? {
    guard let color else { return nil }
    guard let srgb = color.usingColorSpace(.sRGB) else { return nil }

    let red = Float(srgb.redComponent)
    let green = Float(srgb.greenComponent)
    let blue = Float(srgb.blueComponent)
    let alpha = Float(srgb.alphaComponent)

    guard let pointer = waterui_color_from_srgba(red, green, blue, alpha) else {
        return nil
    }
    return WuiColor(pointer)
}

@MainActor
private func wuiFont(from font: NSFont) -> WuiFont {
    let weight = wuiFontWeight(from: font)
    let family = WuiStr(string: font.fontName)
    guard let pointer = wui_font_from_resolved(Float(font.pointSize), weight, family.intoInner()) else {
        fatalError("Failed to create WuiFont from NSFont")
    }
    return WuiFont(pointer)
}

private func wuiFontWeight(from font: NSFont) -> CWaterUI.WuiFontWeight {
    let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
    let raw = (traits?[.weight] as? NSNumber)?.doubleValue ?? 0

    switch raw {
    case ...(-0.8): return WuiFontWeight_Thin
    case (-0.8) ... (-0.6): return WuiFontWeight_UltraLight
    case (-0.6) ... (-0.4): return WuiFontWeight_Light
    case (-0.4) ... (0.0): return WuiFontWeight_Normal
    case (0.0) ... (0.23): return WuiFontWeight_Medium
    case (0.23) ... (0.3): return WuiFontWeight_SemiBold
    case (0.3) ... (0.5): return WuiFontWeight_Bold
    case (0.5) ... (0.8): return WuiFontWeight_UltraBold
    default: return WuiFontWeight_Black
    }
}
#endif
