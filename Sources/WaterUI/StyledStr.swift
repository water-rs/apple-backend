import CWaterUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
struct WuiStyledStr {
    var chunks: [WuiStyledChunk]

    init(_ inner: CWaterUI.WuiStyledStr) {
        self.chunks = []
        for chunk in WuiArray(inner.chunks).toArray() {
            chunks.append(WuiStyledChunk(chunk))
        }
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
}

@MainActor
struct WuiStyledChunk {
    var text: WuiStr
    var style: WuiTextStyle
    init(_ inner: CWaterUI.WuiStyledChunk) {
        self.text = WuiStr(inner.text)
        self.style = WuiTextStyle(inner.style)
    }

    func toAttributedString(env: WuiEnvironment) -> NSAttributedString {
        let resolvedFont = style.font.resolve(in: env).value
        let font = resolvedFont.toPlatformFont()

        var attributes: [NSAttributedString.Key: Any] = [
            .font: font
        ]

        // Apply foreground color if specified
        if let foreground = style.foreground {
            let resolvedColor = foreground.resolve(in: env).value
            #if canImport(UIKit)
            attributes[.foregroundColor] = resolvedColor.toUIColor()
            #elseif canImport(AppKit)
            attributes[.foregroundColor] = resolvedColor.toNSColor()
            #endif
        }

        // Apply background color if specified
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

        // Apply italic by creating a font with italic trait
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
}


extension WuiResolvedFont {
    #if canImport(UIKit)
    func toPlatformFont() -> UIFont {
        // Use system font size as fallback if resolved size is 0 or invalid
        let resolvedSize = CGFloat(self.size)
        let size = resolvedSize > 0 ? resolvedSize : UIFont.systemFontSize
        let weight = self.weight.toUIFontWeight()
        return UIFont.systemFont(ofSize: size, weight: weight)
    }
    #elseif canImport(AppKit)
    func toPlatformFont() -> NSFont {
        // Use system font size as fallback if resolved size is 0 or invalid
        let resolvedSize = CGFloat(self.size)
        let size = resolvedSize > 0 ? resolvedSize : NSFont.systemFontSize
        let weight = self.weight.toNSFontWeight()
        return NSFont.systemFont(ofSize: size, weight: weight)
    }
    #endif
}

#if canImport(UIKit)
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
    var inner: OpaquePointer

    init(_ inner: OpaquePointer) {
        self.inner = inner
    }

    func resolve(in env: WuiEnvironment) -> WuiComputed<CWaterUI.WuiResolvedFont> {
        let computedPtr = waterui_resolve_font(inner, env.inner)
        return WuiComputed<CWaterUI.WuiResolvedFont>(computedPtr!)
    }

    @MainActor deinit {
        waterui_drop_font(inner)
    }
}
