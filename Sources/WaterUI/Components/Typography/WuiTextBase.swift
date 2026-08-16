// WuiTextBase.swift
// Base class for text components (WuiText and WuiPlain)
//
// # Layout Behavior
// Text is content-sized - it uses its intrinsic size based on content and styling.
// When width is constrained, text wraps and height adjusts accordingly.
// Does not expand to fill available space.

import CWaterUI
import CoreText

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

/// Base class providing shared text rendering functionality for WuiText and WuiPlain.
@MainActor
class WuiTextBase: PlatformView {
  #if canImport(UIKit)
    let label = UILabel()
  #elseif canImport(AppKit)
    let textField: NSTextField
  #endif

  #if canImport(AppKit)
    init(initialText: String = "") {
      self.textField = NSTextField(labelWithString: initialText)
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
    let constraintWidth = proposedWidth ?? CGFloat.greatestFiniteMagnitude
    let constraintHeight = proposedHeight ?? CGFloat.greatestFiniteMagnitude
    let framesetter = CTFramesetterCreateWithAttributedString(attributedText as CFAttributedString)
    var fitRange = CFRange()
    let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
      framesetter,
      CFRange(location: 0, length: 0),
      nil,
      CGSize(width: constraintWidth, height: constraintHeight),
      &fitRange
    )
    let width = ceil(min(suggested.width, maxWidth))
    let height = ceil(min(suggested.height, maxHeight))
    let size = CGSize(width: max(width, 0.0), height: max(height, 0.0))
    let frameWidth = max(size.width, 1.0)
    let frameHeight = max(size.height, 1.0)
    let path = CGPath(
      rect: CGRect(x: 0.0, y: 0.0, width: frameWidth, height: frameHeight), transform: nil)
    let frame = CTFramesetterCreateFrame(
      framesetter,
      CFRange(location: 0, length: fitRange.length),
      path,
      nil
    )
    guard let lines = CTFrameGetLines(frame) as? [CTLine] else {
      fatalError("CoreText returned a CTFrame line array with non-CTLine elements.")
    }
    guard !lines.isEmpty else {
      return (size, nil, nil)
    }
    var origins = Array(repeating: CGPoint.zero, count: lines.count)
    CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
    let firstBaseline = frameHeight - origins[0].y
    let lastBaseline = frameHeight - origins[lines.count - 1].y
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
