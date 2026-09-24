// LineLimitMeasurementTests.swift
// Regression for water-rs/waterui#1229 twin a2: a line limit must cap the
// measured lines at the limit, not fold the whole measurement into the one
// displayed line. `applyLineLimit` sets the label's truncating break mode,
// and the platform label writes that mode into its stored attributed text's
// paragraph style — measuring that copy bounded every limit to one line.

import XCTest

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

@testable import WaterUI

@MainActor
final class LineLimitMeasurementTests: XCTestCase {
  #if canImport(AppKit)
    private lazy var measurementWindow = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
  #endif

  private func measuredHeight(_ limit: Int, width: CGFloat = 100) -> CGFloat {
    #if canImport(UIKit)
      let view = WuiTextBase(frame: .zero)
    #elseif canImport(AppKit)
      let view = WuiTextBase(initialText: "")
    #endif
    view.setAttributedText(
      NSAttributedString(
        string: "mmmmmmmmmm mmmmmmmmmm",
        attributes: [.font: PlatformFont.monospacedSystemFont(ofSize: 16.7, weight: .regular)]
      ))
    view.applyLineLimit(limit)
    #if canImport(AppKit)
      measurementWindow.contentView?.addSubview(view)
      defer { view.removeFromSuperview() }
    #endif
    return view.sizeThatFits(WuiProposalSize(width: Float(width))).height
  }

  /// The twin's leaf: `lineLimit(2)` over four laid-out lines caps the
  /// measured height at two line boxes, not one.
  func testLineLimitTwoMeasuresTwoLines() {
    let oneLine = measuredHeight(1)
    XCTAssertEqual(measuredHeight(2), oneLine * 2, accuracy: 1.0)
  }

  func testNoLimitMeasuresEveryLaidOutLine() {
    // 21 monospaced glyphs wrap to four lines at a 100 pt proposal.
    XCTAssertEqual(measuredHeight(0), measuredHeight(1) * 4, accuracy: 1.0)
  }
}
