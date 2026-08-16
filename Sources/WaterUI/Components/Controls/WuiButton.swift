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
    switch style {
    case WuiButtonStyle_BorderedProminent:
      WuiColorSlot_AccentForeground
    case WuiButtonStyle_Plain:
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
    case WuiButtonStyle_BorderedProminent:
      WuiColorSlot_AccentForeground
    case WuiButtonStyle_Automatic,
      WuiButtonStyle_Bordered,
      WuiButtonStyle_Plain:
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
  private let labelView: WuiAnyView
  private let style: WuiButtonStyle
  private var accessibility: WuiControlAccessibility?
  private let disabled: WuiComputed<Bool>
  private var disabledWatcher: WatcherGuard?
  private let env: WuiEnvironment
  private var accentObservation: WuiComputedObservation<WuiResolvedColor>?

  // MARK: - WuiComponent Init

  convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
    let ffiButton: CWaterUI.WuiButton = waterui_force_as_button(anyview)
    let labelEnv = makeButtonLabelEnvironment(style: ffiButton.style, parent: env)
    let labelView = WuiAnyView(anyview: ffiButton.label.view, env: labelEnv)
    let action = Action(inner: ffiButton.action, env: env)
    self.init(
      label: labelView,
      action: action,
      style: ffiButton.style,
      semanticLabel: ffiButton.label,
      disabled: env.disabled,
      env: env
    )
  }

  // MARK: - Designated Init

  init(
    label: WuiAnyView,
    action: Action,
    style: WuiButtonStyle = WuiButtonStyle_Automatic,
    semanticLabel: CWaterUI.WuiLabel,
    disabled: WuiComputed<Bool>,
    env: WuiEnvironment
  ) {
    self.action = action
    self.labelView = label
    self.style = style
    self.disabled = disabled
    self.env = env
    #if canImport(AppKit)
      self.button = NSButton()
    #endif
    super.init(frame: .zero)
    configureButton()
    installThemeObservers()
    embedLabel(label)
    accessibility = WuiControlAccessibility(
      consuming: semanticLabel,
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

  /// Label padding inside the button chrome, styled after the platform's
  /// own defaults: SwiftUI's bordered iOS buttons sit at roughly (14, 7)
  /// and macOS push bezels leave wide side insets around the title.
  private var contentPadding: (horizontal: CGFloat, vertical: CGFloat) {
    #if canImport(UIKit)
      switch style {
      case WuiButtonStyle_Link:
        (0, 0)
      case WuiButtonStyle_Bordered, WuiButtonStyle_BorderedProminent:
        (14, 7)
      default:
        (8, 4)
      }
    #elseif canImport(AppKit)
      switch style {
      case WuiButtonStyle_Link:
        (0, 0)
      case WuiButtonStyle_Automatic, WuiButtonStyle_Bordered, WuiButtonStyle_BorderedProminent:
        (16, 5)
      default:
        (8, 4)
      }
    #endif
  }

  // MARK: - WuiComponent

  func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
    // Button has stretchAxis = .none, so it always reports its content size.
    // When width/height is constrained, the label measures with that constraint
    // (allowing text to wrap) and the button grows in the cross-axis as needed.
    let (horizontalPadding, verticalPadding) = contentPadding

    var labelProposal = WuiProposalSize()
    if let proposedWidth = proposal.width {
      labelProposal.width = max(proposedWidth - Float(horizontalPadding * 2), 0)
    }
    if let proposedHeight = proposal.height {
      labelProposal.height = max(proposedHeight - Float(verticalPadding * 2), 0)
    }

    let labelSize = labelView.sizeThatFits(labelProposal)
    return CGSize(
      width: labelSize.width + horizontalPadding * 2,
      height: labelSize.height + verticalPadding * 2
    )
  }

  // MARK: - Configuration

  private func configureButton() {
    button.translatesAutoresizingMaskIntoConstraints = false
    labelContainer.translatesAutoresizingMaskIntoConstraints = false
    #if canImport(UIKit)
      // The embedded label should not intercept touches meant for the button.
      labelContainer.isUserInteractionEnabled = false
    #endif

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
    #elseif canImport(AppKit)
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
      case WuiButtonStyle_Plain, WuiButtonStyle_Link, WuiButtonStyle_Borderless:
        button.isBordered = false
        button.isTransparent = true
      default:
        fatalError("Unsupported WaterUI button style: \(style.rawValue)")
      }
    #endif
  }

  private func installThemeObservers() {
    accentObservation = WuiComputedObservation(
      themeColor: WuiColorSlot_Accent,
      env: env
    ) { [weak self] _, _ in
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
      // to on iOS: .bordered is the tinted fill, .borderedProminent the
      // filled accent capsule. Insets stay zero because the WaterUI label
      // view is overlaid and padded by this component.
      var configuration: UIButton.Configuration =
        switch style {
        case WuiButtonStyle_Bordered:
          .tinted()
        case WuiButtonStyle_BorderedProminent:
          .filled()
        default:
          .plain()
        }
      configuration.contentInsets = .zero
      button.configuration = configuration
    #elseif canImport(AppKit)
      if style == WuiButtonStyle_BorderedProminent {
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

  private func embedLabel(_ view: WuiAnyView) {
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

  #if canImport(AppKit)
    nonisolated override var isFlipped: Bool { true }
  #endif
}
