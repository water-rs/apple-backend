// TextMetricsTests.swift
// Regression tests for the SwiftUI-parity text line-box drift.
//
// The nightly e2e lane found every WaterUI text element's line box ~0.6-0.7pt
// taller than SwiftUI Text's (~2px per line at 3x, ~1px at 2x), which
// accumulates down every vstack. These tests pin WaterUI's text measurement
// to SwiftUI Text's own answers on the same display.

import SwiftUI
import XCTest

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

@testable import WaterUI

@MainActor
final class TextMetricsTests: XCTestCase {
  #if canImport(AppKit)
    /// Both measurement paths are attached to this window so each resolves
    /// the same backing scale factor when snapping to the pixel grid.
    private lazy var measurementWindow = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
  #endif

  // MARK: - Measurement helpers

  /// The WaterUI answer: `WuiTextBase.sizeThatFits`, the path the layout
  /// engine measures text through.
  private func waterUITextSize(_ text: String, font: PlatformFont, width: CGFloat? = nil)
    -> CGSize
  {
    #if canImport(UIKit)
      let view = WuiTextBase(frame: .zero)
    #elseif canImport(AppKit)
      let view = WuiTextBase(initialText: "")
    #endif
    view.setAttributedText(NSAttributedString(string: text, attributes: [.font: font]))
    #if canImport(AppKit)
      measurementWindow.contentView?.addSubview(view)
      defer { view.removeFromSuperview() }
    #endif
    return view.sizeThatFits(WuiProposalSize(width: width.map { Float($0) }))
  }

  /// The SwiftUI answer for the same string and font.
  private func swiftUITextSize(_ text: String, font: Font, width: CGFloat? = nil) -> CGSize {
    let root = Text(text).font(font).frame(width: width)
    #if canImport(UIKit)
      return UIHostingController(rootView: root)
        .sizeThatFits(in: CGSize(width: 10_000, height: 10_000))
    #elseif canImport(AppKit)
      let hosting = NSHostingView(rootView: root)
      measurementWindow.contentView?.addSubview(hosting)
      defer { hosting.removeFromSuperview() }
      return hosting.fittingSize
    #endif
  }

  /// SwiftUI's laid-out size for two texts in a `VStack(spacing:)`.
  private func swiftUITwoTextStackSize(spacing: CGFloat, font: Font) -> CGSize {
    let root = VStack(spacing: spacing) {
      Text("A").font(font)
      Text("B").font(font)
    }
    #if canImport(UIKit)
      return UIHostingController(rootView: root)
        .sizeThatFits(in: CGSize(width: 10_000, height: 10_000))
    #elseif canImport(AppKit)
      let hosting = NSHostingView(rootView: root)
      measurementWindow.contentView?.addSubview(hosting)
      defer { hosting.removeFromSuperview() }
      return hosting.fittingSize
    #endif
  }

  /// Line count TextKit produces for `text` wrapped at `width` — the
  /// denominator that turns a height delta into a per-line delta.
  private func lineCount(of text: String, font: PlatformFont, width: CGFloat) -> Int {
    let storage = NSTextStorage(
      attributedString: NSAttributedString(string: text, attributes: [.font: font]))
    let layoutManager = NSLayoutManager()
    let container = NSTextContainer(
      size: CGSize(width: width, height: .greatestFiniteMagnitude))
    container.lineFragmentPadding = 0
    storage.addLayoutManager(layoutManager)
    layoutManager.addTextContainer(container)
    layoutManager.ensureLayout(for: container)
    var lines = 0
    var glyphIndex = 0
    while glyphIndex < layoutManager.numberOfGlyphs {
      var range = NSRange()
      layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &range)
      lines += 1
      glyphIndex = NSMaxRange(range)
    }
    return lines
  }

  // MARK: - Tests

  /// One line of text: WaterUI's line box must match SwiftUI Text's within
  /// 0.25pt. The e2e drift was ~0.6-0.7pt per line.
  func testSingleLineBoxesMatchSwiftUI() {
    let cases: [(String, PlatformFont, Font)] = [
      ("body", .preferredFont(forTextStyle: .body), .body),
      ("title1", .preferredFont(forTextStyle: .title1), .title),
      ("title2", .preferredFont(forTextStyle: .title2), .title2),
      ("caption1", .preferredFont(forTextStyle: .caption1), .caption),
    ]
    for (name, platformFont, swiftUIFont) in cases {
      let ours = waterUITextSize("Hello", font: platformFont)
      let theirs = swiftUITextSize("Hello", font: swiftUIFont)
      XCTAssertEqual(
        ours.height, theirs.height, accuracy: 0.25,
        "\(name) line box: WaterUI \(ours.height)pt vs SwiftUI \(theirs.height)pt"
      )
    }
  }

  /// Wrapped text: the delta must be per line, not per element — a fixed
  /// padding would pass a total-height check while every line still drifts.
  func testWrappedLineBoxesMatchSwiftUI() {
    let text = "The quick brown fox jumps over the lazy dog and keeps running far away"
    let width: CGFloat = 120
    let font = PlatformFont.preferredFont(forTextStyle: .body)
    let lines = lineCount(of: text, font: font, width: width)
    XCTAssertGreaterThan(lines, 1, "expected the probe string to wrap at \(width)pt")

    let ours = waterUITextSize(text, font: font, width: width)
    let theirs = swiftUITextSize(text, font: .body, width: width)
    XCTAssertEqual(
      ours.height, theirs.height, accuracy: 0.25 * CGFloat(lines),
      "wrapped body @\(width)pt over \(lines) lines: "
        + "WaterUI \(ours.height)pt vs SwiftUI \(theirs.height)pt"
    )
  }

  /// Two texts in `vstack(spacing: 10)`: WaterUI's slot pitch is the child's
  /// measured height plus the configured spacing (the Rust layout engine
  /// applies spacing verbatim between measured slots). Comparing that pitch
  /// with SwiftUI's separates "line box too tall" from "vstack spacing
  /// resolves too large": if the resolved spacing is 10 and the pitches
  /// match, the drift is the text metric.
  func testVStackSlotPitchMatchesSwiftUI() {
    let spacing: CGFloat = 10
    let font = PlatformFont.preferredFont(forTextStyle: .body)
    let ours = waterUITextSize("A", font: font).height
    let theirsA = swiftUITextSize("A", font: .body).height
    let theirsB = swiftUITextSize("B", font: .body).height
    let stack = swiftUITwoTextStackSize(spacing: spacing, font: .body)

    let resolvedSpacing = stack.height - theirsA - theirsB
    XCTAssertEqual(
      resolvedSpacing, spacing, accuracy: 0.25,
      "SwiftUI resolved VStack spacing \(resolvedSpacing)pt "
        + "(total \(stack.height), texts \(theirsA)+\(theirsB))"
    )

    let oursPitch = ours + spacing
    let theirsPitch = theirsA + resolvedSpacing
    XCTAssertEqual(
      oursPitch, theirsPitch, accuracy: 0.25,
      "vstack(spacing: \(spacing)) slot pitch: "
        + "WaterUI \(oursPitch)pt (text \(ours)) vs SwiftUI \(theirsPitch)pt (text \(theirsA))"
    )
  }
}
