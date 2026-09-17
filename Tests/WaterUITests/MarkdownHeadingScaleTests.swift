import CWaterUI
import Testing

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

@testable import WaterUI

/// Markdown headings resolve through the theme's font slots — the
/// framework's `heading_style` maps `#` → `Headline`, `##` → `Title`,
/// `###` → `Subheadline` — so the slot's installed platform text style is
/// what a heading's font point size comes from.
@Test("Markdown headings land on the platform type scale")
@MainActor
func markdownHeadingScale() {
  // (heading level's font slot, the platform style for that level)
  let levels: [(WuiFontSlot, PlatformTextStyle)] = [
    (WuiFontSlot_Headline, .largeTitle),  // #
    (WuiFontSlot_Title, .title1),  // ##
    (WuiFontSlot_Subheadline, .title2),  // ###
  ]

  for (slot, expectedStyle) in levels {
    let installed = ThemeBridge.textStyle(for: slot)
    #expect(installed == expectedStyle)
    #if canImport(UIKit)
      #expect(
        UIFont.preferredFont(forTextStyle: installed).pointSize
          == UIFont.preferredFont(forTextStyle: expectedStyle).pointSize)
    #elseif canImport(AppKit)
      #expect(
        NSFont.preferredFont(forTextStyle: installed, options: [:]).pointSize
          == NSFont.preferredFont(forTextStyle: expectedStyle, options: [:]).pointSize)
    #endif
  }
}
