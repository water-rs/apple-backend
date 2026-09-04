import CWaterUI
import Foundation

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

@MainActor
struct WuiStyledStr {
  var chunks: [WuiStyledChunk]

  init(_ inner: CWaterUI.WuiStyledStr) {
    self.chunks = WuiArray(inner.chunks).map(WuiStyledChunk.init)
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
final class WuiStyledStrRenderer {
  @MainActor
  private final class ResolvedChunk {
    let chunk: WuiStyledChunk
    let font: WuiComputedObservation<WuiResolvedFontValue>
    let foreground: WuiComputedObservation<WuiResolvedColor>?
    let background: WuiComputedObservation<WuiResolvedColor>?

    init(
      chunk: WuiStyledChunk,
      env: WuiEnvironment,
      onChange: @escaping () -> Void
    ) {
      self.chunk = chunk
      self.font = WuiComputedObservation(chunk.style.font.resolve(in: env)) { _, _ in
        onChange()
      }

      if let foreground = chunk.style.foreground {
        self.foreground = WuiComputedObservation(foreground.resolve(in: env)) { _, _ in
          onChange()
        }
      } else {
        self.foreground = nil
      }

      if let background = chunk.style.background {
        self.background = WuiComputedObservation(background.resolve(in: env)) { _, _ in
          onChange()
        }
      } else {
        self.background = nil
      }
    }

    func attributedString(defaultForeground: WuiResolvedColor?) -> NSAttributedString {
      guard let foreground = foreground?.value ?? defaultForeground else {
        fatalError("Styled text chunk has no foreground color")
      }
      return chunk.toAttributedString(
        font: font.value,
        foreground: foreground,
        background: background?.value
      )
    }
  }

  private let defaultForeground: WuiComputedObservation<WuiResolvedColor>?
  private var chunks: [ResolvedChunk]

  init(
    styled: WuiStyledStr,
    env: WuiEnvironment,
    defaultForegroundSlot: WuiColorSlot = WuiColorSlot_Foreground,
    onChange: @escaping () -> Void
  ) {
    defaultForeground =
      styled.chunks.contains { $0.style.foreground == nil }
      ? WuiComputedObservation(
        themeColor: defaultForegroundSlot,
        env: env
      ) { _, _ in
        onChange()
      }
      : nil
    chunks = styled.chunks.map { chunk in
      ResolvedChunk(
        chunk: chunk,
        env: env,
        onChange: onChange
      )
    }
  }

  func attributedString() -> NSAttributedString {
    let result = NSMutableAttributedString()
    for chunk in chunks {
      result.append(chunk.attributedString(defaultForeground: defaultForeground?.value))
    }
    return result
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

  func toAttributedString(
    font resolvedFont: WuiResolvedFontValue,
    foreground: WuiResolvedColor?,
    background: WuiResolvedColor?
  ) -> NSAttributedString {
    let font = resolvedFont.toPlatformFont()
    var attributes: [NSAttributedString.Key: Any] = [.font: font]

    if let foreground {
      #if canImport(UIKit)
        attributes[.foregroundColor] = foreground.toUIColor()
      #elseif canImport(AppKit)
        attributes[.foregroundColor] = foreground.toNSColor()
      #endif
    }

    if let background {
      #if canImport(UIKit)
        attributes[.backgroundColor] = background.toUIColor()
      #elseif canImport(AppKit)
        attributes[.backgroundColor] = background.toNSColor()
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

struct WuiResolvedFontValue {
  let size: Float
  let weight: CWaterUI.WuiFontWeight
  let familyName: String

  init(consuming resolved: CWaterUI.WuiResolvedFont) {
    size = resolved.size
    weight = resolved.weight
    familyName = WuiStr(resolved.family).toString()
  }

  #if canImport(UIKit)
    func toPlatformFont() -> UIFont {
      let resolvedSize = CGFloat(size)
      let size = resolvedSize > 0 ? resolvedSize : UIFont.systemFontSize
      let weight = weight.toUIFontWeight()

      if !familyName.isEmpty {
        if let genericFont = genericUIFont(familyName: familyName, size: size, weight: weight) {
          return genericFont
        }
        if let customFont = UIFont(name: familyName, size: size) {
          return customFont
        }
        fatalError(
          "WaterUI: Font family '\(familyName)' not found. Ensure the font is bundled and registered."
        )
      }

      return UIFont.systemFont(ofSize: size, weight: weight)
    }
  #elseif canImport(AppKit)
    func toPlatformFont() -> NSFont {
      let resolvedSize = CGFloat(size)
      let size = resolvedSize > 0 ? resolvedSize : NSFont.systemFontSize
      let weight = weight.toNSFontWeight()

      if !familyName.isEmpty {
        if let genericFont = genericNSFont(familyName: familyName, size: size, weight: weight) {
          return genericFont
        }
        if let customFont = NSFont(name: familyName, size: size) {
          return customFont
        }
        fatalError(
          "WaterUI: Font family '\(familyName)' not found. Ensure the font is bundled and registered."
        )
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
      default: fatalError("Unsupported WaterUI font weight: \(rawValue)")
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
      default: fatalError("Unsupported WaterUI font weight: \(rawValue)")
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

  func resolve(in env: WuiEnvironment) -> WuiComputed<WuiResolvedFontValue> {
    guard let inner else {
      fatalError("WuiFont pointer was already consumed")
    }
    let computedPtr = waterui_resolve_font(inner, env.inner)
    return WuiComputed<WuiResolvedFontValue>(computedPtr!)
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
