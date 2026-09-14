// WuiTextBase.swift
// Base class for text components (WuiText and WuiPlain)
//
// # Layout Behavior
// Text is content-sized - it uses its intrinsic size based on content and styling.
// When width is constrained, text wraps and height adjusts accordingly.
// Does not expand to fill available space.

import CWaterUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

/// The platform label every `WuiTextBase` draws through.
///
/// Interpolated text carries directional isolates (U+2066–U+2069 and friends)
/// so mixed-direction strings render correctly. They are formatting marks —
/// invisible on screen and skipped by speech — but they do surface literally
/// in the accessibility value, so the value answers with them removed while
/// the rendered string keeps them.
#if canImport(UIKit)
  final class WuiTextLabel: UILabel {
    override var accessibilityValue: String? {
      get { super.accessibilityValue?.removingBidiControlCharacters }
      set { super.accessibilityValue = newValue }
    }
  }
#elseif canImport(AppKit)
  final class WuiTextLabel: NSTextField {
    override func accessibilityValue() -> String? {
      super.accessibilityValue()?.removingBidiControlCharacters
    }
  }
#endif

extension String {
  /// This string without the Unicode bidi control characters interpolation
  /// wraps placeholders in (isolate marks, embeddings, overrides, and the
  /// Arabic letter mark).
  var removingBidiControlCharacters: String {
    guard unicodeScalars.contains(where: { Self.bidiControls.contains($0) }) else {
      return self
    }
    return String(
      String.UnicodeScalarView(unicodeScalars.filter { !Self.bidiControls.contains($0) }))
  }

  private static let bidiControls: Set<Unicode.Scalar> = [
    "\u{061C}",  // Arabic letter mark
    "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",  // embeddings, override
    "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}",  // isolates
  ]
}

/// Base class providing shared text rendering functionality for WuiText and WuiPlain.
@MainActor
class WuiTextBase: PlatformView {
  #if canImport(UIKit)
    let label = WuiTextLabel()
  #elseif canImport(AppKit)
    let textField: NSTextField
  #endif

  #if canImport(AppKit)
    init(initialText: String = "") {
      self.textField = WuiTextLabel(labelWithString: initialText)
      super.init(frame: .zero)
      configureTextView()
    }
  #else
    override init(frame: CGRect) {
      super.init(frame: frame)
      configureTextView()
    }
  #endif

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - Configuration

  private func configureTextView() {
    #if canImport(UIKit)
      label.translatesAutoresizingMaskIntoConstraints = false
      label.numberOfLines = 0
      label.lineBreakMode = .byWordWrapping
      addSubview(label)
      NSLayoutConstraint.activate([
        label.leadingAnchor.constraint(equalTo: leadingAnchor),
        label.trailingAnchor.constraint(equalTo: trailingAnchor),
        label.topAnchor.constraint(equalTo: topAnchor),
        label.bottomAnchor.constraint(equalTo: bottomAnchor),
      ])
    #elseif canImport(AppKit)
      textField.translatesAutoresizingMaskIntoConstraints = false
      textField.isEditable = false
      textField.isSelectable = false
      textField.isBordered = false
      textField.drawsBackground = false
      textField.lineBreakMode = .byWordWrapping
      textField.maximumNumberOfLines = 0
      textField.cell?.wraps = true
      textField.cell?.isScrollable = false
      addSubview(textField)
      NSLayoutConstraint.activate([
        textField.leadingAnchor.constraint(equalTo: leadingAnchor),
        textField.trailingAnchor.constraint(equalTo: trailingAnchor),
        textField.topAnchor.constraint(equalTo: topAnchor),
        textField.bottomAnchor.constraint(equalTo: bottomAnchor),
      ])
    #endif
  }

  // MARK: - Line limit

  /// Maximum laid-out lines; `0` means no limit — `TextConfig::line_limit`'s
  /// wire convention.
  private var lineLimit: Int = 0

  /// Applies `TextConfig::line_limit`: caps the platform label at `limit`
  /// lines with tail truncation, or restores free word-wrapping for `0`.
  func applyLineLimit(_ limit: Int) {
    lineLimit = max(0, limit)
    #if canImport(UIKit)
      label.numberOfLines = lineLimit
      label.lineBreakMode = lineLimit == 0 ? .byWordWrapping : .byTruncatingTail
    #elseif canImport(AppKit)
      textField.maximumNumberOfLines = lineLimit
      textField.lineBreakMode = lineLimit == 0 ? .byWordWrapping : .byTruncatingTail
      textField.cell?.truncatesLastVisibleLine = lineLimit != 0
    #endif
  }

  // MARK: - Measurement

  private func currentAttributedText() -> NSAttributedString {
    #if canImport(UIKit)
      return label.attributedText ?? NSAttributedString(string: label.text ?? "")
    #elseif canImport(AppKit)
      return textField.attributedStringValue
    #endif
  }

  private func textMeasurement(_ proposal: WuiProposalSize) -> (
    size: CGSize,
    firstBaseline: CGFloat?,
    lastBaseline: CGFloat?
  ) {
    let attributedText = currentAttributedText()
    guard attributedText.length > 0 else {
      return (.zero, nil, nil)
    }

    let proposedWidth = proposal.width.map(CGFloat.init)
    let proposedHeight = proposal.height.map(CGFloat.init)
    let maxWidth = proposedWidth ?? CGFloat.greatestFiniteMagnitude
    let maxHeight = proposedHeight ?? CGFloat.greatestFiniteMagnitude
    let constraintSize = CGSize(
      width: proposedWidth ?? CGFloat.greatestFiniteMagnitude,
      height: proposedHeight ?? CGFloat.greatestFiniteMagnitude
    )

    // Line layout through TextKit — the engine NSTextField/UILabel (and
    // SwiftUI Text) use — not CTFramesetter. CoreText sizes a line to the
    // largest font metric it contains, so one CJK/Arabic fallback glyph
    // inflates the whole line by ~1pt and the extra height accumulates down
    // a stack.
    let textStorage = NSTextStorage(attributedString: attributedText)
    let layoutManager = NSLayoutManager()
    let container = NSTextContainer(size: constraintSize)
    container.lineFragmentPadding = 0
    textStorage.addLayoutManager(layoutManager)
    layoutManager.addTextContainer(container)
    layoutManager.ensureLayout(for: container)
    let glyphCount = layoutManager.numberOfGlyphs
    guard glyphCount > 0 else {
      return (.zero, nil, nil)
    }

    func baselineOfLine(containingGlyph glyphIndex: Int) -> CGFloat {
      var lineRange = NSRange()
      let lineRect = layoutManager.lineFragmentRect(
        forGlyphAt: glyphIndex, effectiveRange: &lineRange)
      let glyphLocation = layoutManager.location(forGlyphAt: lineRange.location)
      return lineRect.origin.y + glyphLocation.y
    }
    let firstBaseline = baselineOfLine(containingGlyph: 0)

    // A line limit caps the measurement at the last visible line; the
    // platform label truncates that line with an ellipsis, so the hidden
    // remainder must not reserve height.
    var measuredText = attributedText
    var lastBaselineGlyph = glyphCount - 1
    if lineLimit > 0 {
      var lineCount = 0
      var glyphIndex = 0
      while glyphIndex < glyphCount {
        var lineRange = NSRange()
        layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &lineRange)
        lineCount += 1
        if lineCount == lineLimit, NSMaxRange(lineRange) < glyphCount {
          let charRange = layoutManager.characterRange(
            forGlyphRange: NSRange(location: 0, length: NSMaxRange(lineRange)),
            actualGlyphRange: nil)
          measuredText = attributedText.attributedSubstring(from: charRange)
          lastBaselineGlyph = lineRange.location
          break
        }
        glyphIndex = NSMaxRange(lineRange)
      }
    }

    // `boundingRect(with:options:)` without `.usesFontLeading` applies the
    // platform's default leading — identical to what NSTextField/UILabel
    // report for the same attributed string.
    let bounding = measuredText.boundingRect(
      with: constraintSize, options: [.usesLineFragmentOrigin], context: nil)
    let width = ceil(min(bounding.width, maxWidth))
    let height = ceil(min(bounding.height, maxHeight))
    let size = CGSize(width: max(width, 0.0), height: max(height, 0.0))

    let lastBaseline = baselineOfLine(containingGlyph: lastBaselineGlyph)
    return (size, firstBaseline, lastBaseline)
  }

  func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
    textMeasurement(proposal).size
  }

  #if canImport(UIKit)
    /// `UILabel.intrinsicContentSize` reports a single-line height unless
    /// `preferredMaxLayoutWidth` is set. When the host wraps us in Auto
    /// Layout (e.g. a `UITableViewCell`), our outer bounds already encode
    /// the available width — propagate it so the underlying label wraps
    /// instead of clipping.
    private var lastLabelMaxWidth: CGFloat = 0

    override func layoutSubviews() {
      super.layoutSubviews()
      let width = bounds.width
      if width > 0, width != lastLabelMaxWidth {
        lastLabelMaxWidth = width
        label.preferredMaxLayoutWidth = width
        label.invalidateIntrinsicContentSize()
        invalidateLayoutHierarchy()
      }
    }
  #endif

  func measure(_ proposal: WuiProposalSize) -> WuiViewDimensions {
    let measurement = textMeasurement(proposal)
    var verticalGuides: [WuiVerticalGuide] = []
    if let firstBaseline = measurement.firstBaseline {
      verticalGuides.append(
        WuiVerticalGuide(
          alignment: WuiVerticalAlignment_FirstBaseline,
          value: Float(firstBaseline)
        )
      )
    }
    if let lastBaseline = measurement.lastBaseline {
      verticalGuides.append(
        WuiVerticalGuide(
          alignment: WuiVerticalAlignment_LastBaseline,
          value: Float(lastBaseline)
        )
      )
    }
    return WuiViewDimensions(size: measurement.size, verticalGuides: verticalGuides)
  }

  #if canImport(AppKit)
    nonisolated override var isFlipped: Bool { true }
  #endif

  // MARK: - Text Updates

  func setAttributedText(_ attributed: NSAttributedString) {
    #if canImport(UIKit)
      label.attributedText = attributed
    #elseif canImport(AppKit)
      textField.attributedStringValue = NSAttributedString(attributedString: attributed)
    #endif
    invalidateLayout()
  }

  func setParagraphAlignment(_ alignment: WuiHorizontalAlignment) {
    #if canImport(UIKit)
      let direction = UIView.userInterfaceLayoutDirection(for: semanticContentAttribute)
      switch alignment {
      case WuiHorizontalAlignment_Leading:
        label.textAlignment = .natural
      case WuiHorizontalAlignment_Trailing:
        label.textAlignment = direction == .rightToLeft ? .left : .right
      case WuiHorizontalAlignment_Center:
        label.textAlignment = .center
      default:
        fatalError("Unsupported WaterUI paragraph alignment: \(alignment.rawValue)")
      }
    #elseif canImport(AppKit)
      let direction = userInterfaceLayoutDirection
      switch alignment {
      case WuiHorizontalAlignment_Leading:
        textField.alignment = .natural
      case WuiHorizontalAlignment_Trailing:
        textField.alignment = direction == .rightToLeft ? .left : .right
      case WuiHorizontalAlignment_Center:
        textField.alignment = .center
      default:
        fatalError("Unsupported WaterUI paragraph alignment: \(alignment.rawValue)")
      }
    #endif
    invalidateLayout()
  }

  func setFont(_ font: PlatformFont) {
    #if canImport(UIKit)
      label.font = font
    #elseif canImport(AppKit)
      textField.font = font
    #endif
    invalidateLayout()
  }

  func invalidateLayout() {
    #if canImport(UIKit)
      label.invalidateIntrinsicContentSize()
    #elseif canImport(AppKit)
      textField.invalidateIntrinsicContentSize()
    #endif
    invalidateLayoutHierarchy()
  }
}
