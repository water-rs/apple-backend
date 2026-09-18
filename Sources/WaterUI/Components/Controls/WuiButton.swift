// WuiButton.swift
// Button component - merged UIKit and AppKit implementation
//
// # Layout Behavior
// Button is content-sized - it uses its intrinsic size based on label content.
// Size adjusts to fit the label view plus standard button padding.
// Does not expand to fill available space.
//
// // INTERNAL: Layout Contract for Backend Implementers
// // - stretchAxis: .none (content-sized, does not expand)
// // - sizeThatFits: Returns intrinsic size based on label + padding
// // - Priority: 0 (default)

import CWaterUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

func buttonLabelForegroundSlot(for style: WuiButtonStyle) -> WuiColorSlot {
  #if canImport(UIKit)
    // Glass takes the primary label color: the capsule is the emphasis, and
    // only the prominent variant carries the accent, as a fill.
    switch style {
    case WuiButtonStyle_BorderedProminent, WuiButtonStyle_GlassProminent:
      WuiColorSlot_AccentForeground
    case WuiButtonStyle_Plain, WuiButtonStyle_Glass:
      WuiColorSlot_Foreground
    case WuiButtonStyle_Automatic,
      WuiButtonStyle_Link,
      WuiButtonStyle_Borderless,
      WuiButtonStyle_Bordered:
      WuiColorSlot_Accent
    default:
      fatalError("Unsupported WaterUI button style: \(style.rawValue)")
    }
  #elseif canImport(AppKit)
    // SwiftUI on macOS draws bordered button titles in the primary label
    // color; only link/borderless styles are accent-tinted.
    switch style {
    case WuiButtonStyle_BorderedProminent, WuiButtonStyle_GlassProminent:
      WuiColorSlot_AccentForeground
    case WuiButtonStyle_Automatic,
      WuiButtonStyle_Bordered,
      WuiButtonStyle_Plain,
      WuiButtonStyle_Glass:
      WuiColorSlot_Foreground
    case WuiButtonStyle_Link,
      WuiButtonStyle_Borderless:
      WuiColorSlot_Accent
    default:
      fatalError("Unsupported WaterUI button style: \(style.rawValue)")
    }
  #endif
}

@MainActor
private func makeButtonLabelEnvironment(
  style: WuiButtonStyle,
  parent: WuiEnvironment
) -> WuiEnvironment {
  let foregroundSlot = buttonLabelForegroundSlot(for: style)

  guard let childPointer = waterui_clone_env(parent.inner) else {
    fatalError("Failed to clone the WaterUI environment for a button label")
  }
  let child = WuiEnvironment(childPointer)
  guard let foreground = waterui_theme_color(parent.inner, foregroundSlot) else {
    fatalError("WaterUI button style requires theme color slot \(foregroundSlot.rawValue)")
  }
  waterui_theme_install_color(child.inner, WuiColorSlot_Foreground, foreground)
  return child
}

#if canImport(AppKit)
  /// Overlays the button bezel without stealing its mouse events, so the
  /// native bezel shows its own pressed/disabled states.
  private final class WuiHitTestTransparentView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }
#endif

@MainActor
final class WuiButton: PlatformView, WuiComponent {
  static var rawId: CWaterUI.WuiTypeId { waterui_button_id() }

  #if canImport(UIKit)
    private let button: UIButton = .init(type: .system)
    private let labelContainer = UIView()
  #elseif canImport(AppKit)
    private let button: NSButton
    private let labelContainer = WuiHitTestTransparentView()
  #endif

  private let action: Action
  private let labelView: any WuiComponent
  private let style: WuiButtonStyle

  /// The proposal the parent layout selected when it placed this button —
  /// the label's offer derives from it exactly as `sizeThatFits` computes
  /// `labelProposal` under the same value.
  private var selectedProposal: WuiProposalSize?
  private var accessibility: WuiControlAccessibility?
  private let disabled: WuiComputed<Bool>
  private var disabledWatcher: WatcherGuard?
  private let accent: WuiComputed<WuiResolvedColor>
  private var accentObservation: WuiComputedObservation<WuiResolvedColor>?

  // MARK: - WuiComponent Init

  convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
    let ffiButton: CWaterUI.WuiButton = waterui_force_as_button(anyview)
    let labelEnv = makeButtonLabelEnvironment(style: ffiButton.style, parent: env)
    let labelView = WuiAnyView(anyview: ffiButton.label.view, env: labelEnv)
    let action = Action(inner: ffiButton.action, env: env)
    guard let accessibilityLabel = ffiButton.label.accessibility_label else {
      fatalError("WaterUI button label has no accessibility signal")
    }
    guard let accent = waterui_theme_color(env.inner, WuiColorSlot_Accent) else {
      fatalError("WaterUI theme is missing required color slot \(WuiColorSlot_Accent.rawValue)")
    }
    self.init(
      label: labelView,
      action: action,
      style: ffiButton.style,
      disabled: env.disabled,
      accent: WuiComputed<WuiResolvedColor>(accent),
      accessibilityLabel: WuiComputed<WuiStyledStr>(accessibilityLabel)
    )
  }

  // MARK: - Designated Init

  init(
    label: any WuiComponent,
    action: Action,
    style: WuiButtonStyle = WuiButtonStyle_Automatic,
    disabled: WuiComputed<Bool>,
    accent: WuiComputed<WuiResolvedColor>,
    accessibilityLabel: WuiComputed<WuiStyledStr>
  ) {
    self.action = action
    self.labelView = label
    self.style = style
    self.disabled = disabled
    self.accent = accent
    #if canImport(AppKit)
      self.button = NSButton()
    #endif
    super.init(frame: .zero)
    configureButton()
    installThemeObservers()
    embedLabel(label)
    accessibility = WuiControlAccessibility(
      label: accessibilityLabel,
      target: button,
      visualLabel: label
    )
    startWatchingDisabled()
  }

  private func startWatchingDisabled() {
    disabledWatcher = disabled.watch { [weak self] isDisabled, _ in
      self?.applyDisabled(isDisabled)
    }
    applyDisabled(disabled.value)
  }

  private func applyDisabled(_ isDisabled: Bool) {
    button.isEnabled = !isDisabled
    #if canImport(UIKit)
      labelContainer.alpha = isDisabled ? 0.45 : 1
    #elseif canImport(AppKit)
      labelContainer.alphaValue = isDisabled ? 0.45 : 1
    #endif
    invalidateCapturedRendering()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  /// Whether the style draws chrome around its label. Styles without
  /// chrome — plain, borderless, link — present the label bare, matching
  /// SwiftUI's borderless button.
  private var drawsChrome: Bool {
    switch style {
    case WuiButtonStyle_Bordered, WuiButtonStyle_BorderedProminent, WuiButtonStyle_Glass,
      WuiButtonStyle_GlassProminent:
      true
    #if canImport(AppKit)
      // SwiftUI's automatic button style resolves to the bordered push
      // bezel on macOS.
      case WuiButtonStyle_Automatic:
        true
    #endif
    default:
      false
    }
  }

  /// Label padding inside the button chrome, measured from the platform's
  /// own bezel rather than styled literals: UIKit reports it through the
  /// button configuration's content insets, AppKit through the bezel cell's
  /// drawing rect inside a standard control bounds. Chrome-less styles get
  /// none — SwiftUI's borderless presentation pads nothing.
  private var contentPadding: (horizontal: CGFloat, vertical: CGFloat) {
    guard drawsChrome else { return (0, 0) }
    #if canImport(UIKit)
      guard let insets = chromeConfiguration?.contentInsets else { return (0, 0) }
      return (insets.leading, insets.top)
    #elseif canImport(AppKit)
      guard let cell = button.cell as? NSButtonCell else { return (0, 0) }
      let drawing = cell.drawingRect(forBounds: NSRect(x: 0, y: 0, width: 200, height: 24))
      return (drawing.minX, drawing.minY)
    #endif
  }

  #if canImport(UIKit)
    /// The native configuration the style's chrome is drawn with — what
    /// SwiftUI's button styles resolve to on iOS — or nil for chrome-less
    /// styles.
    private var chromeConfiguration: UIButton.Configuration? {
      switch style {
      case WuiButtonStyle_Bordered:
        // SwiftUI's .bordered is the neutral gray capsule; .tinted() would
        // dye the fill with the accent color, which borderedProminent
        // already reserves for itself.
        .gray()
      case WuiButtonStyle_BorderedProminent:
        .filled()
      case WuiButtonStyle_Glass:
        .glass()
      case WuiButtonStyle_GlassProminent:
        .prominentGlass()
      default:
        nil
      }
    }
  #endif

  // MARK: - WuiComponent

  func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
    // Button has stretchAxis = .none, so it always reports its content size.
    // When width/height is constrained, the label measures with that constraint
    // (allowing text to wrap) and the button grows in the cross-axis as needed.
    let (horizontalPadding, verticalPadding) = contentPadding

    let labelSize = labelView.sizeThatFits(labelOffer(from: proposal))
    return CGSize(
      width: labelSize.width + horizontalPadding * 2,
      height: labelSize.height + verticalPadding * 2
    )
  }

  /// The offer the embedded label is measured under — the button's own
  /// proposal minus its padding. Layout delivers the same derived value for
  /// the proposal the parent selected, so the label's own layout pass sees
  /// the negotiated offer, not its resolved frame.
  private func labelOffer(from base: WuiProposalSize) -> WuiProposalSize {
    let (horizontalPadding, verticalPadding) = contentPadding
    var labelProposal = WuiProposalSize()
    if let proposedWidth = base.width {
      labelProposal.width = max(proposedWidth - Float(horizontalPadding * 2), 0)
    }
    if let proposedHeight = base.height {
      labelProposal.height = max(proposedHeight - Float(verticalPadding * 2), 0)
    }
    return labelProposal
  }

  func setPlacementProposal(_ proposal: WuiProposalSize) {
    guard selectedProposal != proposal else { return }
    selectedProposal = proposal
    #if canImport(UIKit)
      setNeedsLayout()
    #elseif canImport(AppKit)
      needsLayout = true
    #endif
  }

  #if canImport(UIKit)
    override func layoutSubviews() {
      super.layoutSubviews()
      // Natively hosted buttons fall back to a bounded offer from the rect
      // they fill — the same boundary rule containers use.
      labelView.setPlacementProposal(
        labelOffer(from: selectedProposal ?? WuiProposalSize(size: bounds.size)))
    }
  #elseif canImport(AppKit)
    override func layout() {
      super.layout()
      labelView.setPlacementProposal(
        labelOffer(from: selectedProposal ?? WuiProposalSize(size: bounds.size)))
    }
  #endif

  // MARK: - Configuration

  private func configureButton() {
    button.translatesAutoresizingMaskIntoConstraints = false
    labelContainer.translatesAutoresizingMaskIntoConstraints = false
    #if canImport(UIKit)
      // The embedded label should not intercept touches meant for the button.
      labelContainer.isUserInteractionEnabled = false
    #endif

    #if canImport(AppKit)
      button.target = self
      button.action = #selector(didTap)
      button.title = ""
      // The native bezel is what SwiftUI renders for bordered styles on
      // macOS: platform gradient, pressed state, and appearance adaptation
      // all come from NSButton. `.flexiblePush` is the push bezel that may
      // grow beyond the standard control height, which arbitrary WaterUI
      // labels routinely need.
      switch style {
      case WuiButtonStyle_Automatic, WuiButtonStyle_Bordered, WuiButtonStyle_BorderedProminent:
        button.isBordered = true
        button.bezelStyle = .flexiblePush
      case WuiButtonStyle_Glass, WuiButtonStyle_GlassProminent:
        // The glass bezel is AppKit's Liquid Glass capsule; the prominent
        // variant is the same bezel with the accent as its `bezelColor`.
        button.isBordered = true
        button.bezelStyle = .glass
      case WuiButtonStyle_Plain, WuiButtonStyle_Link, WuiButtonStyle_Borderless:
        button.isBordered = false
        button.isTransparent = true
      default:
        fatalError("Unsupported WaterUI button style: \(style.rawValue)")
      }
      // A transparent borderless NSButton reports AXUnknown instead of
      // AXButton — the chrome change is visual, the element is still a
      // button to assistive technology.
      button.setAccessibilityRole(.button)
    #endif

    // Padding is asked of the platform chrome, so the bezel/configuration
    // has to be in place first.
    let (horizontalPadding, verticalPadding) = contentPadding

    #if canImport(AppKit)
      addSubview(button)
      addSubview(labelContainer)
    #else
      addSubview(button)
      button.addSubview(labelContainer)
    #endif

    NSLayoutConstraint.activate([
      button.leadingAnchor.constraint(equalTo: leadingAnchor),
      button.trailingAnchor.constraint(equalTo: trailingAnchor),
      button.topAnchor.constraint(equalTo: topAnchor),
      button.bottomAnchor.constraint(equalTo: bottomAnchor),

      labelContainer.leadingAnchor.constraint(
        equalTo: button.leadingAnchor, constant: horizontalPadding),
      labelContainer.trailingAnchor.constraint(
        equalTo: button.trailingAnchor, constant: -horizontalPadding),
      labelContainer.topAnchor.constraint(equalTo: button.topAnchor, constant: verticalPadding),
      labelContainer.bottomAnchor.constraint(
        equalTo: button.bottomAnchor, constant: -verticalPadding),
    ])

    #if canImport(UIKit)
      button.addTarget(self, action: #selector(didTap), for: .touchUpInside)
      button.addTarget(
        self, action: #selector(handleTouchDown), for: [.touchDown, .touchDragEnter])
      button.addTarget(
        self, action: #selector(handleTouchUp),
        for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
    #endif
  }

  private func installThemeObservers() {
    accentObservation = WuiComputedObservation(accent) { [weak self] _, _ in
      self?.applyThemeAppearance()
    }
    #if canImport(AppKit)
      if style == WuiButtonStyle_Link {
        setupLinkTrackingArea()
      }
    #endif
    applyThemeAppearance()
  }

  private func applyThemeAppearance() {
    guard let accent = accentObservation?.value else { return }

    #if canImport(UIKit)
      button.tintColor = accent.toUIColor()
      // The native configurations are what SwiftUI's button styles resolve
      // to on iOS: .bordered is the neutral gray capsule, .borderedProminent
      // the filled accent capsule. Insets stay zero because the WaterUI
      // label view is overlaid and padded by this component.
      var configuration = chromeConfiguration ?? .plain()
      configuration.contentInsets = .zero
      button.configuration = configuration
    #elseif canImport(AppKit)
      if style == WuiButtonStyle_BorderedProminent || style == WuiButtonStyle_GlassProminent {
        button.bezelColor = accent.toNSColor()
      }
    #endif
    invalidateCapturedRendering()
  }

  #if canImport(UIKit)
    @objc
    private func handleTouchDown() {
      updateHighlight(true)
    }

    @objc
    private func handleTouchUp() {
      updateHighlight(false)
    }

    private func updateHighlight(_ highlighted: Bool) {
      let targetAlpha: CGFloat = button.isEnabled ? (highlighted ? 0.55 : 1) : 0.45
      labelContainer.alpha = targetAlpha
    }
  #endif

  #if canImport(AppKit)
    /// Sets up tracking area for hover effects (Link style cursor change)
    private func setupLinkTrackingArea() {
      let trackingArea = NSTrackingArea(
        rect: bounds,
        options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
        owner: self,
        userInfo: nil
      )
      addTrackingArea(trackingArea)
    }

    override func mouseEntered(with event: NSEvent) {
      if style == WuiButtonStyle_Link {
        NSCursor.pointingHand.push()
      }
    }

    override func mouseExited(with event: NSEvent) {
      if style == WuiButtonStyle_Link {
        NSCursor.pop()
      }
    }

    override func mouseDown(with event: NSEvent) {
      if style == WuiButtonStyle_Link {
        // Natural press feedback: reduce opacity like SwiftUI
        labelView.alphaValue = 0.5
      }
      super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
      if style == WuiButtonStyle_Link {
        // Restore opacity
        labelView.alphaValue = 1.0
      }
      super.mouseUp(with: event)
    }
  #endif

  private func embedLabel(_ view: PlatformView) {
    view.translatesAutoresizingMaskIntoConstraints = false
    labelContainer.addSubview(view)
    NSLayoutConstraint.activate([
      view.leadingAnchor.constraint(equalTo: labelContainer.leadingAnchor),
      view.trailingAnchor.constraint(equalTo: labelContainer.trailingAnchor),
      view.topAnchor.constraint(equalTo: labelContainer.topAnchor),
      view.bottomAnchor.constraint(equalTo: labelContainer.bottomAnchor),
    ])
  }

  @objc
  private func didTap() {
    action.call()
  }

  /// Performs this button's action without a click on its own view.
  ///
  /// Chrome that presents a button as something else — a toolbar item drawn
  /// from the button's label rather than its view — still has to run the action
  /// the caller attached.
  func invokeAction() {
    action.call()
  }

  #if canImport(AppKit)
    /// The button's name as its semantic label states it — the text assistive
    /// technology reads, whatever the label draws.
    ///
    /// Chrome that presents the button as a toolbar item needs the name apart
    /// from the view: the Mac draws the icon alone and keeps the name for the
    /// overflow menu and the tooltip.
    var semanticTitle: String {
      button.accessibilityLabel() ?? ""
    }

    /// The platform symbol the button's label draws, if its icon is one.
    var systemIconName: String? {
      labelView.firstSystemIcon?.iconName
    }

    /// The label's own view. Under the icon-only display mode a window
    /// toolbar installs, this is the icon — what chrome that renders the
    /// item as an image (rather than hosting the accent-tinted view) draws.
    var labelContentView: WuiAnyView? {
      labelView as? WuiAnyView
    }

    /// Whether the button draws without a bezel — the borderless and link
    /// styles — so chrome presenting it as a toolbar item keeps it bare too.
    var isBorderless: Bool {
      style == WuiButtonStyle_Borderless || style == WuiButtonStyle_Link
    }
  #endif

  #if canImport(AppKit)
    nonisolated override var isFlipped: Bool { true }
  #endif
}
