import CWaterUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

@MainActor
private func makeMenuLabelEnvironment(parent: WuiEnvironment) -> WuiEnvironment {
  #if canImport(UIKit)
    // SwiftUI tints a menu trigger's label with the accent colour, so the
    // label resolves its Foreground slot from the theme accent.
    guard let childPointer = waterui_clone_env(parent.inner) else {
      fatalError("Failed to clone the WaterUI environment for a menu label")
    }
    let child = WuiEnvironment(childPointer)
    guard let accent = waterui_theme_color(parent.inner, WuiColorSlot_Accent) else {
      fatalError("WaterUI theme is missing required color slot \(WuiColorSlot_Accent.rawValue)")
    }
    waterui_theme_install_color(child.inner, WuiColorSlot_Foreground, accent)
    return child
  #elseif canImport(AppKit)
    // SwiftUI's macOS menu trigger is a popup button whose title draws in the
    // label colour — no tint.
    return parent
  #endif
}

@MainActor
final class WuiMenu: PlatformView, WuiComponent {
  static var rawId: CWaterUI.WuiTypeId { waterui_menu_id() }

  private let labelView: any WuiComponent
  private let callAction: @MainActor (OpaquePointer) -> Void
  private let accent: WuiComputed<WuiResolvedColor>
  private var accentObservation: WuiComputedObservation<WuiResolvedColor>?
  private var tree: WuiMenuTree!
  private var accessibilityObservation: WuiComputedObservation<WuiStyledStr>?

  #if canImport(UIKit)
    let button = UIButton(type: .system)
  #elseif canImport(AppKit)
    /// SwiftUI's macOS menu trigger is a slim pull-down popup button —
    /// `SwiftUIPopupButton` is an `NSPopUpButton` subclass.
    let popUp = NSPopUpButton(frame: .zero, pullsDown: true)
  #endif

  var stretchAxis: WuiStretchAxis { .none }

  // MARK: - WuiComponent Init

  convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
    let menu = waterui_force_as_menu(anyview)
    guard let items = menu.items else {
      fatalError("WuiMenu.items is null")
    }
    let labelEnv = makeMenuLabelEnvironment(parent: env)
    let labelView = WuiAnyView.resolve(anyview: menu.label, env: labelEnv)
    guard let accent = waterui_theme_color(env.inner, WuiColorSlot_Accent) else {
      fatalError("WaterUI theme is missing required color slot \(WuiColorSlot_Accent.rawValue)")
    }
    self.init(
      label: labelView,
      accent: WuiComputed<WuiResolvedColor>(accent),
      accessibilityLabel: menu.accessibility_label.map {
        WuiComputed<WuiStyledStr>(OpaquePointer(UnsafeMutableRawPointer($0)))
      },
      items: items,
      callAction: { waterui_call_shared_action($0, env.inner) }
    )
  }

  // MARK: - Designated Init

  init(
    label: any WuiComponent,
    accent: WuiComputed<WuiResolvedColor>,
    accessibilityLabel: WuiComputed<WuiStyledStr>?,
    items: OpaquePointer,
    callAction: @escaping @MainActor (OpaquePointer) -> Void
  ) {
    self.labelView = label
    self.accent = accent
    self.callAction = callAction
    super.init(frame: .zero)

    tree = WuiMenuTree(consuming: items) { [weak self] metadata in
      guard let self else { return }
      withPlatformAnimation(metadata) {
        self.rebuildNativeMenu()
      }
    }
    setupButton()
    installAccentObservation()
    rebuildNativeMenu()

    if let accessibilityLabel {
      let observation = WuiComputedObservation(accessibilityLabel) { [weak self] value, _ in
        self?.applySemanticAccessibilityLabel(value)
      }
      accessibilityObservation = observation
      applySemanticAccessibilityLabel(observation.value)
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func installAccentObservation() {
    accentObservation = WuiComputedObservation(accent) { [weak self] value, _ in
      self?.applyAccent(value)
    }
    if let accent = accentObservation {
      applyAccent(accent.value)
    }
  }

  private func applyAccent(_ accent: WuiResolvedColor) {
    #if canImport(UIKit)
      // SwiftUI's menu trigger presents its label in the accent colour.
      button.tintColor = accent.toUIColor()
    #endif
  }

  private func setupButton() {
    labelView.translatesAutoresizingMaskIntoConstraints = false

    #if canImport(UIKit)
      button.translatesAutoresizingMaskIntoConstraints = false
      addSubview(button)
      button.addSubview(labelView)
      NSLayoutConstraint.activate([
        button.leadingAnchor.constraint(equalTo: leadingAnchor),
        button.trailingAnchor.constraint(equalTo: trailingAnchor),
        button.topAnchor.constraint(equalTo: topAnchor),
        button.bottomAnchor.constraint(equalTo: bottomAnchor),
        labelView.topAnchor.constraint(equalTo: button.topAnchor, constant: 4),
        labelView.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -4),
      ])
      labelView.isUserInteractionEnabled = false
      // SwiftUI's Menu renders a plain accent-tinted label, not a filled
      // capsule.
      button.configuration = .plain()
      button.showsMenuAsPrimaryAction = true
      NSLayoutConstraint.activate([
        labelView.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 8),
        labelView.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -8),
      ])
    #elseif canImport(AppKit)
      popUp.translatesAutoresizingMaskIntoConstraints = false
      addSubview(popUp)
      popUp.addSubview(labelView)
      // The pull-down face keeps its title left-aligned 12 pt in and
      // reserves ~36 pt on the right for the chevron — the same geometry
      // `SwiftUIPopupButton` reports.
      NSLayoutConstraint.activate([
        popUp.leadingAnchor.constraint(equalTo: leadingAnchor),
        popUp.trailingAnchor.constraint(equalTo: trailingAnchor),
        popUp.topAnchor.constraint(equalTo: topAnchor),
        popUp.bottomAnchor.constraint(equalTo: bottomAnchor),
        labelView.leadingAnchor.constraint(equalTo: popUp.leadingAnchor, constant: 12),
        labelView.trailingAnchor.constraint(equalTo: popUp.trailingAnchor, constant: -36),
        labelView.topAnchor.constraint(equalTo: popUp.topAnchor, constant: 4),
        labelView.bottomAnchor.constraint(equalTo: popUp.bottomAnchor, constant: -4),
      ])
    #endif
  }

  private func rebuildNativeMenu() {
    #if canImport(UIKit)
      button.menu = buildUIKitMenu(title: "", from: tree.nodes) { [weak self] command in
        guard let self else { return }
        self.callAction(command.action)
      }
    #elseif canImport(AppKit)
      let menu = NSMenu()
      // A pull-down list takes its face title from the first item and never
      // shows that item in the popped list — the overlay label draws the
      // trigger, so the title slot stays empty.
      menu.addItem(NSMenuItem(title: "", action: nil, keyEquivalent: ""))
      appendAppKitMenuItems(
        tree.nodes, to: menu, target: self, action: #selector(menuItemClicked(_:)))
      popUp.menu = menu
    #endif
    invalidateCapturedRendering()
  }

  private func applySemanticAccessibilityLabel(_ styled: WuiStyledStr) {
    let text = styled.toString()
    #if canImport(UIKit)
      button.accessibilityLabel = text
      button.isAccessibilityElement = true
    #elseif canImport(AppKit)
      popUp.setAccessibilityLabel(text)
      popUp.toolTip = text
    #endif
  }

  #if canImport(AppKit)
    @objc private func menuItemClicked(_ sender: NSMenuItem) {
      guard let action = sender.representedObject as? MenuActionRef else {
        fatalError("WaterUI menu item has no semantic action")
      }
      callAction(action.command.action)
    }
  #endif

  func layoutPriority() -> Int32 { 0 }

  /// The proposal the parent layout selected when it placed this menu — the
  /// label's offer derives from it exactly as `sizeThatFits` computes the
  /// label proposal under the same value.
  private var selectedProposal: WuiProposalSize?

  private var labelPaddings: (horizontal: CGFloat, vertical: CGFloat) {
    let verticalPadding: CGFloat = 8
    #if canImport(UIKit)
      let horizontalPadding: CGFloat = 16
    #elseif canImport(AppKit)
      // The pull-down face's title area: 12 pt leading plus 36 pt for the
      // chevron.
      let horizontalPadding: CGFloat = 48
    #endif
    return (horizontalPadding, verticalPadding)
  }

  /// The offer the embedded label is measured under — the menu's own
  /// proposal minus its padding. Layout delivers the same derived value for
  /// the proposal the parent selected, so the label's own layout pass sees
  /// the negotiated offer, not its resolved frame.
  private func labelOffer(from base: WuiProposalSize) -> WuiProposalSize {
    let (horizontalPadding, verticalPadding) = labelPaddings
    var labelProposal = WuiProposalSize()
    if let proposedWidth = base.width {
      labelProposal.width = max(proposedWidth - Float(horizontalPadding), 0)
    }
    if let proposedHeight = base.height {
      labelProposal.height = max(proposedHeight - Float(verticalPadding), 0)
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

  func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
    let (horizontalPadding, verticalPadding) = labelPaddings
    let labelSize = labelView.sizeThatFits(labelOffer(from: proposal))
    return CGSize(
      width: labelSize.width + horizontalPadding,
      height: labelSize.height + verticalPadding
    )
  }

  #if canImport(UIKit)
    override func layoutSubviews() {
      super.layoutSubviews()
      // Natively hosted menus fall back to a bounded offer from the rect
      // they fill — the same boundary rule containers use.
      labelView.setPlacementProposal(
        labelOffer(from: selectedProposal ?? WuiProposalSize(size: bounds.size)))
    }
  #elseif canImport(AppKit)
    nonisolated override var isFlipped: Bool { true }

    override func layout() {
      super.layout()
      labelView.setPlacementProposal(
        labelOffer(from: selectedProposal ?? WuiProposalSize(size: bounds.size)))
    }
  #endif
}
