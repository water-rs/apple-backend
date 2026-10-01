@_exported import CWaterUI

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
}

@MainActor
struct WuiStyledChunk {
  var text: WuiStr
  var style: WuiTextStyle

  init(_ inner: CWaterUI.WuiStyledChunk) {
    self.text = WuiStr(inner.text)
    self.style = WuiTextStyle(inner.style)
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

extension PlatformFont {
  /// The face's declared line pitch — line box plus leading. Published to
  /// the wire as a theme font's `lineHeight`.
  var naturalLinePitch: CGFloat {
    ascender - descender + leading
  }
}

@MainActor
class WuiFont {
  private var inner: OpaquePointer?

  init(_ inner: OpaquePointer) {
    self.inner = inner
  }

  @MainActor deinit {
    if let inner {
      waterui_drop_font(inner)
    }
  }
}
