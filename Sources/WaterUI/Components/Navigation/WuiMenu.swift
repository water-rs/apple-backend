import CWaterUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit

  private final class WuiMenuButton: NSButton {
    override func hitTest(_ point: NSPoint) -> NSView? {
      bounds.contains(point) ? self : nil
    }
  }
#endif

@MainActor
final class WuiMenu: PlatformView, WuiComponent {
  static var rawId: CWaterUI.WuiTypeId { waterui_menu_id() }

  private let labelView: any WuiComponent
  private let env: WuiEnvironment
  private var tree: WuiMenuTree!
  private var accessibilityObservation: WuiComputedObservation<WuiStyledStr>?

  #if canImport(UIKit)
    private let button = UIButton(type: .system)
  #elseif canImport(AppKit)
    private let button = WuiMenuButton()
    private let indicatorView = NSImageView()
    private var nativeMenu = NSMenu()
  #endif

  var stretchAxis: WuiStretchAxis { .none }

  required init(anyview: OpaquePointer, env: WuiEnvironment) {
    let menu = waterui_force_as_menu(anyview)
    guard let items = menu.items else {
      fatalError("WuiMenu.items is null")
    }

    self.env = env
    self.labelView = WuiAnyView.resolve(anyview: menu.label, env: env)
    super.init(frame: .zero)

    tree = WuiMenuTree(consuming: items) { [weak self] metadata in
      guard let self else { return }
      withPlatformAnimation(metadata) {
        self.rebuildNativeMenu()
      }
    }
    setupButton()
    rebuildNativeMenu()

    if let accessibilityLabel = menu.accessibility_label {
      let observation = WuiComputedObservation(
        WuiComputed<WuiStyledStr>(OpaquePointer(UnsafeMutableRawPointer(accessibilityLabel)))
      ) { [weak self] value, _ in
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

  private func setupButton() {
    button.translatesAutoresizingMaskIntoConstraints = false
    labelView.translatesAutoresizingMaskIntoConstraints = false
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

    #if canImport(UIKit)
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
      button.bezelStyle = .rounded
      button.title = ""
      button.target = self
      button.action = #selector(showMenu)
      // macOS menus are pull-downs: the trailing up/down chevron is part of
      // the native control language and tells the user this pops a menu.
      guard
        let indicator = NSImage(
          systemSymbolName: "chevron.up.chevron.down",
          accessibilityDescription: nil
        )
      else {
        fatalError("SF Symbol chevron.up.chevron.down is unavailable")
      }
      indicatorView.image = indicator
      indicatorView.symbolConfiguration = NSImage.SymbolConfiguration(
        pointSize: NSFont.smallSystemFontSize,
        weight: .semibold
      )
      indicatorView.contentTintColor = .secondaryLabelColor
      indicatorView.translatesAutoresizingMaskIntoConstraints = false
      button.addSubview(indicatorView)
      NSLayoutConstraint.activate([
        labelView.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 8),
        indicatorView.leadingAnchor.constraint(equalTo: labelView.trailingAnchor, constant: 4),
        indicatorView.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -8),
        indicatorView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
      ])
    #endif
  }

  private func rebuildNativeMenu() {
    #if canImport(UIKit)
      button.menu = buildUIKitMenu(title: "", from: tree.nodes) { [weak self] command in
        guard let self else { return }
        waterui_call_shared_action(command.action, self.env.inner)
      }
    #elseif canImport(AppKit)
      let menu = NSMenu()
      appendAppKitMenuItems(
        tree.nodes, to: menu, target: self, action: #selector(menuItemClicked(_:)))
      nativeMenu = menu
    #endif
    invalidateCapturedRendering()
  }

  private func applySemanticAccessibilityLabel(_ styled: WuiStyledStr) {
    let text = styled.toString()
    #if canImport(UIKit)
      button.accessibilityLabel = text
      button.isAccessibilityElement = true
    #elseif canImport(AppKit)
      button.setAccessibilityLabel(text)
      button.toolTip = text
    #endif
  }

  #if canImport(AppKit)
    @objc private func showMenu() {
      nativeMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
    }

    @objc private func menuItemClicked(_ sender: NSMenuItem) {
      guard let action = sender.representedObject as? MenuActionRef else {
        fatalError("WaterUI menu item has no semantic action")
      }
      waterui_call_shared_action(action.command.action, env.inner)
    }
  #endif

  func layoutPriority() -> Int32 { 0 }

  func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
    let verticalPadding: CGFloat = 8
    #if canImport(UIKit)
      let horizontalPadding: CGFloat = 16
    #elseif canImport(AppKit)
      // Side padding plus the pull-down indicator and its spacing.
      let horizontalPadding: CGFloat = 16 + indicatorView.intrinsicContentSize.width + 4
    #endif
    var labelProposal = WuiProposalSize()
    if let proposedWidth = proposal.width {
      labelProposal.width = max(proposedWidth - Float(horizontalPadding), 0)
    }
    if let proposedHeight = proposal.height {
      labelProposal.height = max(proposedHeight - Float(verticalPadding), 0)
    }
    let labelSize = labelView.sizeThatFits(labelProposal)
    return CGSize(
      width: labelSize.width + horizontalPadding,
      height: labelSize.height + verticalPadding
    )
  }

  #if canImport(AppKit)
    override var isFlipped: Bool { true }
  #endif
}
