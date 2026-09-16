//
//  WuiBadge.swift
//
//  Badge indicator overlay — renders the reactive count from `WuiBadge`
//  as a dot (0) or count capsule (non-zero) pinned to the content's
//  top-trailing corner, matching the badge metrics hydrolysis draws.
//

import CWaterUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

/// Component for `Native<BadgeConfig>` — `waterui_badge_id`.
///
/// The badge overlays its content without contributing layout size: measure
/// and stretch forward to the wrapped view, then the indicator is positioned
/// at the top-trailing corner (mirrored in RTL), following the shared badge
/// metrics — a 6pt dot for `0`, a 16pt-high capsule carrying the count
/// otherwise.
@MainActor
final class WuiBadge: PlatformView, WuiComponent {
  static var rawId: CWaterUI.WuiTypeId { waterui_badge_id() }

  private let contentView: any WuiComponent
  private let indicator = BadgeIndicatorView()
  private var valueObservation: WuiComputedObservation<Int32>?
  private var colorObservation: WuiComputedObservation<WuiResolvedColor>?
  private var labelColorObservation: WuiComputedObservation<WuiResolvedColor>?

  var stretchAxis: WuiStretchAxis { contentView.stretchAxis }

  required init(anyview: OpaquePointer, env: WuiEnvironment) {
    let badge = waterui_force_as_badge(anyview)
    contentView = WuiAnyView.resolve(anyview: badge.content, env: env)
    super.init(frame: .zero)

    contentView.translatesAutoresizingMaskIntoConstraints = true
    addSubview(contentView)

    indicator.translatesAutoresizingMaskIntoConstraints = true
    addSubview(indicator)

    #if canImport(UIKit)
      clipsToBounds = false
    #elseif canImport(AppKit)
      wantsLayer = true
      layer?.masksToBounds = false
    #endif

    valueObservation = WuiComputedObservation(WuiComputed<Int32>(badge.value)) {
      [weak self, indicator] value, _ in
      indicator.value = value
      self?.setNeedsIndicatorLayout()
    }
    indicator.value = valueObservation!.value

    // `waterui_resolve_computed_color` reclaims the `Computed<Color>` handle
    // and hands back an env-resolved `Computed<ResolvedColor>` owned here.
    guard let resolvedColor = waterui_resolve_computed_color(badge.color, env.inner) else {
      fatalError("waterui_resolve_computed_color returned nil for badge color")
    }
    colorObservation = WuiComputedObservation(WuiComputed<WuiResolvedColor>(resolvedColor)) {
      [indicator] color, _ in
      indicator.fillColor = color.platformColor
    }
    indicator.fillColor = colorObservation!.value.platformColor

    labelColorObservation = WuiComputedObservation(
      themeColor: WuiColorSlot_AccentForeground, env: env
    ) { [indicator] color, _ in
      indicator.labelColor = color.platformColor
    }
    indicator.labelColor = labelColorObservation!.value.platformColor
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func layoutPriority() -> Int32 {
    contentView.layoutPriority()
  }

  /// Transparent for layout: the proposal selected for this
  /// wrapper is the proposal its content was negotiated with.
  func setPlacementProposal(_ proposal: WuiProposalSize) {
    contentView.setPlacementProposal(proposal)
  }

  func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
    contentView.sizeThatFits(proposal)
  }

  func measure(_ proposal: WuiProposalSize) -> WuiViewDimensions {
    contentView.measure(proposal)
  }

  private func setNeedsIndicatorLayout() {
    #if canImport(UIKit)
      setNeedsLayout()
    #elseif canImport(AppKit)
      needsLayout = true
    #endif
  }

  private func layoutIndicator() {
    let size = indicator.indicatorSize()
    #if canImport(UIKit)
      let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
    #elseif canImport(AppKit)
      let isRTL = userInterfaceLayoutDirection == .rightToLeft
    #endif
    let x: CGFloat
    if isRTL {
      x = bounds.minX + indicator.horizontalOffset - size.width
    } else {
      x = bounds.maxX - indicator.horizontalOffset
    }
    indicator.frame = CGRect(
      x: x,
      y: bounds.minY + indicator.verticalOffset - size.height,
      width: size.width,
      height: size.height
    )
  }

  #if canImport(UIKit)
    override func layoutSubviews() {
      super.layoutSubviews()
      contentView.frame = bounds
      layoutIndicator()
    }
  #elseif canImport(AppKit)
    nonisolated override var isFlipped: Bool { true }

    override func layout() {
      super.layout()
      contentView.frame = bounds
      layoutIndicator()
    }
  #endif
}

/// Geometry shared with the badge metrics hydrolysis draws: the dot and the
/// capsule's leading edge sit `horizontalOffset` inside the content's
/// trailing edge, and the indicator's top sits `verticalOffset` below the
/// content's top (so the capsule overhangs upward).
private final class BadgeIndicatorView: PlatformView {
  static let dotSize: CGFloat = 6
  static let capsuleHeight: CGFloat = 16
  static let capsuleHorizontalPadding: CGFloat = 4
  static let capsuleFontSize: CGFloat = 11

  var horizontalOffset: CGFloat { value == 0 ? Self.dotSize : 12 }
  var verticalOffset: CGFloat { value == 0 ? Self.dotSize : 14 }

  var value: Int32 = 0 {
    didSet {
      guard value != oldValue else { return }
      updateAccessibility()
      requestDisplay()
    }
  }

  var fillColor: PlatformColor = .systemRed {
    didSet { requestDisplay() }
  }

  var labelColor: PlatformColor = .white {
    didSet { requestDisplay() }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    #if canImport(UIKit)
      isUserInteractionEnabled = false
      backgroundColor = .clear
    #endif
    updateAccessibility()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  #if canImport(AppKit)
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  #endif

  func indicatorSize() -> CGSize {
    guard value != 0 else {
      return CGSize(width: Self.dotSize, height: Self.dotSize)
    }
    let textSize = valueText.size(withAttributes: textAttributes)
    let width = ceil(textSize.width) + Self.capsuleHorizontalPadding * 2
    return CGSize(width: max(Self.capsuleHeight, width), height: Self.capsuleHeight)
  }

  private var valueText: NSString { "\(value)" as NSString }

  private var textAttributes: [NSAttributedString.Key: Any] {
    [
      .font: PlatformFont.systemFont(ofSize: Self.capsuleFontSize, weight: .medium),
      .foregroundColor: labelColor,
    ]
  }

  private func requestDisplay() {
    #if canImport(UIKit)
      setNeedsDisplay()
    #elseif canImport(AppKit)
      needsDisplay = true
    #endif
  }

  private func updateAccessibility() {
    #if canImport(UIKit)
      isAccessibilityElement = value != 0
      accessibilityLabel = value != 0 ? "\(value)" : nil
    #elseif canImport(AppKit)
      setAccessibilityElement(value != 0)
      setAccessibilityLabel(value != 0 ? "\(value)" : nil)
    #endif
  }

  private func drawIndicator(in rect: CGRect) {
    #if canImport(UIKit)
      guard let context = UIGraphicsGetCurrentContext() else { return }
    #elseif canImport(AppKit)
      guard let context = NSGraphicsContext.current?.cgContext else { return }
    #endif
    context.setFillColor(fillColor.cgColor)
    if value == 0 {
      context.fillEllipse(in: rect)
      return
    }
    context.addPath(
      CGPath(
        roundedRect: rect,
        cornerWidth: rect.height / 2,
        cornerHeight: rect.height / 2,
        transform: nil
      ))
    context.fillPath()
    let textSize = valueText.size(withAttributes: textAttributes)
    let textRect = CGRect(
      x: rect.midX - textSize.width / 2,
      y: rect.midY - textSize.height / 2,
      width: textSize.width,
      height: textSize.height
    )
    valueText.draw(in: textRect, withAttributes: textAttributes)
  }

  #if canImport(UIKit)
    override func draw(_ rect: CGRect) {
      drawIndicator(in: bounds)
    }
  #elseif canImport(AppKit)
    nonisolated override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
      drawIndicator(in: bounds)
    }
  #endif
}

extension WuiResolvedColor {
  fileprivate var platformColor: PlatformColor {
    #if canImport(UIKit)
      toUIColor()
    #elseif canImport(AppKit)
      toNSColor()
    #endif
  }
}
