// ListRowMetricsTests.swift
// Per-row insets and the list's minimum-row-height floor.
//
// `WuiListItem.insets` replaces the theme's row insets wholesale for one row,
// and `WuiList.min_row_height` replaces the platform's row-height floor for
// the whole list (`0` sizes each row to its content plus insets). These pin
// the resolution math the table delegates run — the FFI value-to-points
// conversion, the absent-means-theme fallbacks, and the content-plus-insets
// pitch floored at the resolved minimum.

import Foundation
import Testing

@testable import WaterUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

@MainActor
struct ListRowMetricsTests {
  /// The FFI's `WuiEdgeInsets` carries directional points — `WuiListRowInsets`
  /// must land each field on its own edge without a merge.
  @Test func ffiInsetsConvertFieldByField() {
    let ffi = CWaterUI.WuiEdgeInsets(top: 1, leading: 2, bottom: 3, trailing: 4)
    #expect(WuiListRowInsets(ffi) == WuiListRowInsets(top: 1, leading: 2, bottom: 3, trailing: 4))
  }

  /// A row's own insets replace the theme's set outright; a row without them
  /// keeps the theme.
  @Test func itemInsetsReplaceThemeWholesale() {
    let theme = WuiListRowInsets(top: 11, leading: 20, bottom: 11, trailing: 20)
    let item = CWaterUI.WuiEdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 48)
    let resolved = Optional(item).map(WuiListRowInsets.init) ?? theme
    #expect(resolved == WuiListRowInsets(top: 0, leading: 0, bottom: 0, trailing: 48))
    let absent = Optional<CWaterUI.WuiEdgeInsets>.none.map(WuiListRowInsets.init)
    #expect((absent ?? theme) == theme)
  }

  /// `has_min_row_height` hands the floor to the FFI value — `0` removes it
  /// entirely — and its absence keeps the platform's floor.
  @Test func minRowHeightReplacesThemeFloor() {
    #expect(wuiListMinRowHeight(hasValue: false, value: 0, theme: 24) == 24)
    #expect(wuiListMinRowHeight(hasValue: true, value: 64, theme: 24) == 64)
    #expect(wuiListMinRowHeight(hasValue: true, value: 0, theme: 24) == 0)
  }

  /// The reported row height is content plus vertical insets, floored at the
  /// resolved minimum; a `0` floor lets the content alone set the height.
  @Test func rowHeightIsContentPlusInsetsFloored() {
    let insets = WuiListRowInsets(top: 4, leading: 10, bottom: 6, trailing: 10)
    #expect(wuiListRowHeight(contentHeight: 20, insets: insets, minRowHeight: 0) == 30)
    #expect(wuiListRowHeight(contentHeight: 20, insets: insets, minRowHeight: 44) == 44)
    #expect(wuiListRowHeight(contentHeight: 40, insets: insets, minRowHeight: 44) == 50)
  }

  #if canImport(UIKit)
    /// The theme's row insets are the same values `rowInsets` measures — the
    /// absent-insets path keeps today's rows exactly.
    @Test func themeRowInsetsMirrorPlatformRowInsets() {
      let theme = WuiListCell.themeRowInsets
      let rowInsets = WuiListCell.rowInsets
      #expect(theme.top == rowInsets.top)
      #expect(theme.leading == rowInsets.leading)
      #expect(theme.bottom == rowInsets.bottom)
      #expect(theme.trailing == rowInsets.trailing)
    }
  #endif

  #if canImport(AppKit)
    /// The theme's row insets are `rowContentInset`/`rowVerticalInset` — the
    /// absent-insets path keeps today's rows exactly.
    @Test func themeRowInsetsMirrorContentAndVerticalInsets() {
      let theme = WuiList.themeRowInsets
      #expect(theme.top == WuiList.rowVerticalInset)
      #expect(theme.leading == WuiList.rowContentInset)
      #expect(theme.bottom == WuiList.rowVerticalInset)
      #expect(theme.trailing == WuiList.rowContentInset)
    }
  #endif
}
