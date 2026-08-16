import CWaterUI
import Foundation

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

@MainActor
final class WuiContextMenu: PlatformView, WuiComponent {
  static var rawId: CWaterUI.WuiTypeId { waterui_metadata_context_menu_id() }

  private let contentView: any WuiComponent
  private let env: WuiEnvironment
  private var tree: WuiMenuTree!

  var stretchAxis: WuiStretchAxis { contentView.stretchAxis }

  required init(anyview: OpaquePointer, env: WuiEnvironment) {
    let metadata = waterui_force_as_metadata_context_menu(anyview)
    guard let items = metadata.value.items else {
      fatalError("ContextMenu.items is null")
    }

    self.env = env
    self.contentView = WuiAnyView.resolve(anyview: metadata.content, env: env)
    super.init(frame: .zero)

    tree = WuiMenuTree(consuming: items) { [weak self] _ in
      self?.invalidateCapturedRendering()
    }
    contentView.translatesAutoresizingMaskIntoConstraints = true
    addSubview(contentView)

    #if canImport(UIKit)
      addInteraction(UIContextMenuInteraction(delegate: self))
      isUserInteractionEnabled = true
    #endif
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func layoutPriority() -> Int32 { contentView.layoutPriority() }

  func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
    contentView.sizeThatFits(proposal)
  }

  #if canImport(UIKit)
    override func layoutSubviews() {
      super.layoutSubviews()
      contentView.frame = bounds
    }
  #elseif canImport(AppKit)
    nonisolated override var isFlipped: Bool { true }

    override func layout() {
      super.layout()
      contentView.frame = bounds
    }

    override func rightMouseDown(with event: NSEvent) {
      let menu = NSMenu()
      appendAppKitMenuItems(
        tree.nodes, to: menu, target: self, action: #selector(menuItemClicked(_:)))
      NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func menuItemClicked(_ sender: NSMenuItem) {
      guard let action = sender.representedObject as? MenuActionRef else {
        fatalError("WaterUI context-menu item has no semantic action")
      }
      waterui_call_shared_action(action.command.action, env.inner)
    }
  #endif
}

#if canImport(UIKit)
  extension WuiContextMenu: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(
      _ interaction: UIContextMenuInteraction,
      configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
      guard !tree.nodes.isEmpty else { return nil }
      return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
        guard let self else { return nil }
        return buildUIKitMenu(title: "", from: self.tree.nodes) { [weak self] command in
          guard let self else { return }
          waterui_call_shared_action(command.action, self.env.inner)
        }
      }
    }
  }
#endif
