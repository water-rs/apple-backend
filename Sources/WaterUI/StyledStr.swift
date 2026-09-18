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

  // periphery:ignore - test seam: the unit suite builds styled text without the Rust library
  init(chunks: [WuiStyledChunk] = []) {
    self.chunks = chunks
  }

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

    func attributedString(defaultForeground: PlatformColor?) -> NSAttributedString {
      guard let foreground = foreground?.value.toPlatformColor() ?? defaultForeground else {
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
  /// A platform-native default color (e.g. the placeholder color) applied to
  /// chunks without an explicit foreground. Unlike a theme slot it carries a
  /// live dynamic color, so it adapts to the resolved interface style at draw
  /// time the way the platform's own control would.
  private let defaultForegroundColor: PlatformColor?
  private var chunks: [ResolvedChunk]

  init(
    styled: WuiStyledStr,
    env: WuiEnvironment,
    defaultForegroundSlot: WuiColorSlot = WuiColorSlot_Foreground,
    defaultForegroundColor: PlatformColor? = nil,
    onChange: @escaping () -> Void
  ) {
    self.defaultForegroundColor = defaultForegroundColor
    defaultForeground =
      defaultForegroundColor == nil && styled.chunks.contains { $0.style.foreground == nil }
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
      result.append(
        chunk.attributedString(
          defaultForeground: defaultForeground?.value.toPlatformColor()
            ?? defaultForegroundColor
        ))
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
    foreground: PlatformColor?,
    background: WuiResolvedColor?
  ) -> NSAttributedString {
    NSAttributedString.wui(
      text.toString(),
      font: resolvedFont,
      foreground: foreground,
      background: background,
      decorations: WuiTextDecorations(
        underline: style.underline,
        strikethrough: style.strikethrough,
        italic: style.italic
      )
    )
  }

  mutating func intoInner() -> CWaterUI.WuiStyledChunk {
    CWaterUI.WuiStyledChunk(
      text: text.intoInner(),
      style: style.intoInner()
    )
  }
}

/// The inline decorations a text run carries on top of its resolved font.
struct WuiTextDecorations {
  var underline = false
  var strikethrough = false
  var italic = false
}

extension NSAttributedString {
  /// The attributed form every WaterUI text leaf renders through — styled
  /// chunks and plain strings alike — so the theme's line pitch, letter
  /// spacing, hyphenation and break strategy apply to all of them.
  @MainActor
  static func wui(
    _ string: String,
    font resolvedFont: WuiResolvedFontValue,
    foreground: PlatformColor?,
    background: WuiResolvedColor?,
    decorations: WuiTextDecorations = WuiTextDecorations()
  ) -> NSAttributedString {
    let font = resolvedFont.toPlatformFont()
    var attributes: [NSAttributedString.Key: Any] = [.font: font]

    if let foreground {
      attributes[.foregroundColor] = foreground
    }

    if let background {
      #if canImport(UIKit)
        attributes[.backgroundColor] = background.toUIColor()
      #elseif canImport(AppKit)
        attributes[.backgroundColor] = background.toNSColor()
      #endif
    }

    if decorations.underline {
      attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
    }

    if decorations.strikethrough {
      attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
    }

    if resolvedFont.letterSpacing != 0 {
      attributes[.kern] = CGFloat(resolvedFont.letterSpacing)
    }

    let paragraphStyle = NSMutableParagraphStyle()
    // On iOS, SwiftUI Text hyphenates only a run that cannot break at a
    // word boundary; an ordinary word wraps whole. TextKit hyphenates a line
    // whenever the width it fills at its last word boundary, as a fraction
    // of the fragment width, falls below the factor — a run with no word
    // boundary fills nothing at one, so the smallest positive factor keeps
    // ordinary words whole and breaks overflow runs with a hyphen the way
    // the iOS typesetter does. On macOS, SwiftUI never hyphenates: an
    // overflow run wraps at the last glyph that fits, with no hyphen.
    #if canImport(UIKit)
      paragraphStyle.hyphenationFactor = .leastNormalMagnitude
    #endif
    // Platform text views lay out with the standard break-strategy set,
    // which pushes a line's last word down to keep a single-word orphan
    // off the closing line. A paragraph style built from scratch defaults
    // to no strategy, so attaching one without it would lose that orphan
    // control and wrap greedily where UILabel and SwiftUI do not.
    paragraphStyle.lineBreakStrategy = .standard
    // A resolved line height is the face's line pitch — line box plus
    // leading. The platform font we can rebuild carries no leading, so the
    // pitch is expressed as `lineSpacing` over the rebuilt face's natural
    // line pitch: mixed-script lines keep their inflated metrics, and the
    // declared pitch lands between lines the way the face's leading does.
    // The closing line keeps its natural line box: SwiftUI's text height is
    // the interior pitch times the line count less one, plus one line box.
    if resolvedFont.lineHeight > 0 {
      paragraphStyle.lineSpacing = CGFloat(resolvedFont.lineHeight) - font.naturalLinePitch
    }
    attributes[.paragraphStyle] = paragraphStyle

    var finalFont = font
    if decorations.italic {
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

    return NSAttributedString(string: string, attributes: attributes)
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

/// Splits a CSS-style family list ("Roboto, sans-serif") into the candidate
/// order a lookup should try: each comma-separated family, trimmed. A single
/// name returns a one-element list, preserving exact-family semantics.
private func fontFamilyCandidates(_ familyName: String) -> [String] {
  familyName
    .split(separator: ",")
    .map { $0.trimmingCharacters(in: .whitespaces) }
    .filter { !$0.isEmpty }
}

extension PlatformFont {
  /// The face's default line pitch — the distance TextKit puts between
  /// baselines with no paragraph style: line box plus leading.
  var naturalLinePitch: CGFloat {
    ascender - descender + leading
  }
}

struct WuiResolvedFontValue {
  let size: Float
  let weight: CWaterUI.WuiFontWeight
  let familyName: String
  /// Which of the system's own faces to use when no family is named.
  let design: CWaterUI.WuiFontDesign
  /// Absolute line pitch in points; `0` keeps the platform face's natural
  /// metrics. Theme faces publish their `lineHeight + leading` here because
  /// the wire form cannot carry the platform font itself.
  let lineHeight: Float
  /// Additional spacing between adjacent glyphs in points.
  let letterSpacing: Float

  init(consuming resolved: CWaterUI.WuiResolvedFont) {
    size = resolved.size
    weight = resolved.weight
    familyName = WuiStr(resolved.family).toString()
    design = resolved.design
    lineHeight = resolved.line_height
    letterSpacing = resolved.letter_spacing
  }

  #if canImport(UIKit)
    func toPlatformFont() -> UIFont {
      let resolvedSize = CGFloat(size)
      let size = resolvedSize > 0 ? resolvedSize : UIFont.systemFontSize
      let weight = weight.toUIFontWeight()

      if !familyName.isEmpty {
        for candidate in fontFamilyCandidates(familyName) {
          if let genericFont = genericUIFont(familyName: candidate, size: size, weight: weight) {
            return genericFont
          }
          if let customFont = UIFont(name: candidate, size: size) {
            return customFont
          }
        }
        fatalError(
          "WaterUI: Font family '\(familyName)' not found. Ensure the font is bundled and registered."
        )
      }

      switch design {
      case WuiFontDesign_Default:
        return UIFont.systemFont(ofSize: size, weight: weight)
      case WuiFontDesign_Monospaced:
        return UIFont.monospacedSystemFont(ofSize: size, weight: weight)
      default:
        fatalError("Unsupported WaterUI font design: \(design.rawValue)")
      }
    }
  #elseif canImport(AppKit)
    func toPlatformFont() -> NSFont {
      let resolvedSize = CGFloat(size)
      let size = resolvedSize > 0 ? resolvedSize : NSFont.systemFontSize
      let weight = weight.toNSFontWeight()

      if !familyName.isEmpty {
        for candidate in fontFamilyCandidates(familyName) {
          if let genericFont = genericNSFont(familyName: candidate, size: size, weight: weight) {
            return genericFont
          }
          if let customFont = NSFont(name: candidate, size: size) {
            return customFont
          }
        }
        fatalError(
          "WaterUI: Font family '\(familyName)' not found. Ensure the font is bundled and registered."
        )
      }

      switch design {
      case WuiFontDesign_Default:
        return NSFont.systemFont(ofSize: size, weight: weight)
      case WuiFontDesign_Monospaced:
        return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
      default:
        fatalError("Unsupported WaterUI font design: \(design.rawValue)")
      }
    }
  #endif
}

#if canImport(UIKit)
  private func genericUIFont(familyName: String, size: CGFloat, weight: UIFont.Weight) -> UIFont? {
    switch familyName {
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
