import CWaterUI
import Foundation

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

struct MenuShortcutData {
  let keyEquivalent: String
  let command: Bool
  let shift: Bool
  let option: Bool
  let control: Bool

  #if canImport(UIKit)
    var modifierMask: UIKeyModifierFlags {
      var mask: UIKeyModifierFlags = []
      if command { mask.insert(.command) }
      if shift { mask.insert(.shift) }
      if option { mask.insert(.alternate) }
      if control { mask.insert(.control) }
      return mask
    }
  #elseif canImport(AppKit)
    var modifierMask: NSEvent.ModifierFlags {
      var mask: NSEvent.ModifierFlags = []
      if command { mask.insert(.command) }
      if shift { mask.insert(.shift) }
      if option { mask.insert(.option) }
      if control { mask.insert(.control) }
      return mask
    }
  #endif
}

@MainActor
final class WuiMenuCommandNode {
  let action: OpaquePointer
  let iconName: String?
  let shortcut: MenuShortcutData?

  private let labelObservation: WuiSemanticTextObservation
  private let disabledObservation: WuiComputedObservation<Bool>
  private let selectedObservation: WuiComputedObservation<Bool>

  var label: String { labelObservation.string }
  var isDisabled: Bool { disabledObservation.value }
  var isSelected: Bool { selectedObservation.value }

  init(
    consuming item: CWaterUI.WuiMenuItem,
    onChange: @escaping (WuiWatcherMetadata) -> Void
  ) {
    guard let label = item.label else {
      fatalError("Command menu item has no label")
    }
    guard let action = item.action else {
      fatalError("Command menu item has no action")
    }
    guard let disabled = item.disabled else {
      fatalError("Command menu item has no disabled signal")
    }
    guard let selected = item.selected else {
      fatalError("Command menu item has no selected signal")
    }

    self.action = OpaquePointer(UnsafeRawPointer(action))
    self.iconName = item.icon.map { icon in
      WuiStr(waterui_menu_item_take_icon(icon).name).toString()
    }
    self.shortcut = item.shortcut.map { pointer in
      let shortcut = waterui_menu_item_take_shortcut(pointer)
      return MenuShortcutData(
        keyEquivalent: WuiStr(shortcut.key).toString(),
        command: shortcut.modifiers.command,
        shift: shortcut.modifiers.shift,
        option: shortcut.modifiers.option,
        control: shortcut.modifiers.control
      )
    }
    self.labelObservation = WuiSemanticTextObservation(
      consuming: waterui_menu_item_take_label(label),
      onChange: { _, metadata in onChange(metadata) }
    )
    self.disabledObservation = WuiComputedObservation(
      WuiComputed<Bool>(disabled),
      onChange: { _, metadata in onChange(metadata) }
    )
    self.selectedObservation = WuiComputedObservation(
      WuiComputed<Bool>(selected),
      onChange: { _, metadata in onChange(metadata) }
    )
  }

  @MainActor deinit {
    waterui_drop_shared_action(action)
  }
}

@MainActor
final class WuiMenuSubmenuNode {
  let iconName: String?
  let items: WuiMenuTree

  private let labelObservation: WuiSemanticTextObservation

  var label: String { labelObservation.string }

  init(
    consuming item: CWaterUI.WuiMenuItem,
    onChange: @escaping (WuiWatcherMetadata) -> Void
  ) {
    guard let label = item.label else {
      fatalError("Nested menu has no label")
    }
    guard let items = item.items else {
      fatalError("Nested menu has no items collection")
    }

    self.iconName = item.icon.map { icon in
      WuiStr(waterui_menu_item_take_icon(icon).name).toString()
    }
    self.items = WuiMenuTree(consuming: items, onChange: onChange)
    self.labelObservation = WuiSemanticTextObservation(
      consuming: waterui_menu_item_take_label(label),
      onChange: { _, metadata in onChange(metadata) }
    )
  }
}

@MainActor
final class WuiMenuNode {
  enum Kind {
    case command(WuiMenuCommandNode)
    case divider
    case menu(WuiMenuSubmenuNode)
  }

  let id: Int32
  let kind: Kind

  init(
    id: Int32,
    consuming item: CWaterUI.WuiMenuItem,
    onChange: @escaping (WuiWatcherMetadata) -> Void
  ) {
    self.id = id
    switch item.tag {
    case WuiMenuItemTag_Command:
      self.kind = .command(WuiMenuCommandNode(consuming: item, onChange: onChange))
    case WuiMenuItemTag_Divider:
      self.kind = .divider
    case WuiMenuItemTag_Menu:
      self.kind = .menu(WuiMenuSubmenuNode(consuming: item, onChange: onChange))
    default:
      fatalError("Unsupported WuiMenuItemTag: \(item.tag.rawValue)")
    }
  }
}

@MainActor
final class WuiMenuTree {
  private let source: WuiAnyViews
  private let collection = WuiStableSemanticCollection<Int32, WuiMenuNode>()
  private var watcher: WatcherGuard?

  var nodes: [WuiMenuNode] { collection.ordered }

  init(
    consuming source: OpaquePointer,
    onChange: @escaping (WuiWatcherMetadata) -> Void
  ) {
    self.source = WuiAnyViews(source)
    watcher = watchAnyViewsIds(self.source) { [weak self] ids, metadata in
      self?.reconcile(ids: ids, onChange: onChange)
      onChange(metadata)
    }
    reconcile(ids: self.source.allIds(), onChange: onChange)
  }

  private func reconcile(
    ids: [Int32],
    onChange: @escaping (WuiWatcherMetadata) -> Void
  ) {
    collection.reconcile(ids: ids) { [source] index, id in
      let item = waterui_force_as_menu_item(source.takeRawView(at: index))
      return WuiMenuNode(id: id, consuming: item, onChange: onChange)
    }
  }
}

#if canImport(UIKit)
  @MainActor
  func buildUIKitMenuElements(
    from nodes: [WuiMenuNode],
    handler: @escaping (WuiMenuCommandNode) -> Void
  ) -> [UIMenuElement] {
    let groups = splitMenuGroups(nodes)
    guard groups.count > 1 else {
      return groups.first.map { buildUIKitMenuGroup($0, handler: handler) } ?? []
    }

    return groups.map { group in
      UIMenu(
        title: "", options: .displayInline, children: buildUIKitMenuGroup(group, handler: handler))
    }
  }

  @MainActor
  func buildUIKitMenu(
    title: String,
    imageName: String? = nil,
    from nodes: [WuiMenuNode],
    handler: @escaping (WuiMenuCommandNode) -> Void
  ) -> UIMenu {
    UIMenu(
      title: title,
      image: uiMenuImage(named: imageName),
      identifier: nil,
      options: [],
      children: buildUIKitMenuElements(from: nodes, handler: handler)
    )
  }

  @MainActor
  private func buildUIKitMenuGroup(
    _ nodes: [WuiMenuNode],
    handler: @escaping (WuiMenuCommandNode) -> Void
  ) -> [UIMenuElement] {
    nodes.compactMap { node in
      switch node.kind {
      case .command(let command):
        return UIAction(
          title: command.label,
          image: uiMenuImage(named: command.iconName),
          identifier: nil,
          discoverabilityTitle: nil,
          attributes: command.isDisabled ? [.disabled] : [],
          state: command.isSelected ? .on : .off
        ) { _ in
          handler(command)
        }
      case .divider:
        return nil
      case .menu(let menu):
        return buildUIKitMenu(
          title: menu.label,
          imageName: menu.iconName,
          from: menu.items.nodes,
          handler: handler
        )
      }
    }
  }

  private func uiMenuImage(named name: String?) -> UIImage? {
    name.flatMap { UIImage(systemName: $0) }
  }

  @MainActor
  func buildUIKitSystemMenus(
    from nodes: [WuiMenuNode],
    handler: @escaping (WuiMenuCommandNode) -> Void
  ) -> [UIMenu] {
    nodes.map { node in
      guard case .menu(let menu) = node.kind else {
        fatalError("App::menu_bar only accepts top-level Menu values")
      }
      return UIMenu(
        title: menu.label,
        image: uiMenuImage(named: menu.iconName),
        identifier: UIMenu.Identifier("dev.waterui.menu.\(node.id)"),
        options: [],
        children: buildUIKitMenuElements(from: menu.items.nodes, handler: handler)
      )
    }
  }

  private func splitMenuGroups(_ nodes: [WuiMenuNode]) -> [[WuiMenuNode]] {
    var groups: [[WuiMenuNode]] = []
    var current: [WuiMenuNode] = []

    for node in nodes {
      if case .divider = node.kind {
        if !current.isEmpty {
          groups.append(current)
          current.removeAll(keepingCapacity: true)
        }
      } else {
        current.append(node)
      }
    }

    if !current.isEmpty {
      groups.append(current)
    }
    return groups
  }
#endif

#if canImport(AppKit)
  @MainActor
  final class MenuActionRef: NSObject {
    let command: WuiMenuCommandNode

    init(command: WuiMenuCommandNode) {
      self.command = command
    }
  }

  @MainActor
  func appendAppKitMenuItems(
    _ nodes: [WuiMenuNode],
    to menu: NSMenu,
    target: AnyObject,
    action: Selector
  ) {
    for node in nodes {
      switch node.kind {
      case .divider:
        menu.addItem(.separator())
      case .command(let command):
        let item = NSMenuItem(
          title: command.label,
          action: action,
          keyEquivalent: command.shortcut?.keyEquivalent ?? ""
        )
        item.target = target
        item.isEnabled = !command.isDisabled
        item.state = command.isSelected ? .on : .off
        item.keyEquivalentModifierMask = command.shortcut?.modifierMask ?? []
        item.image = appKitMenuImage(named: command.iconName)
        item.representedObject = MenuActionRef(command: command)
        menu.addItem(item)
      case .menu(let submenu):
        let item = NSMenuItem(title: submenu.label, action: nil, keyEquivalent: "")
        item.image = appKitMenuImage(named: submenu.iconName)
        let nested = NSMenu(title: submenu.label)
        appendAppKitMenuItems(submenu.items.nodes, to: nested, target: target, action: action)
        item.submenu = nested
        menu.addItem(item)
      }
    }
  }

  private func appKitMenuImage(named name: String?) -> NSImage? {
    name.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
  }

  @MainActor
  func appendAppKitMenuBarItems(
    _ nodes: [WuiMenuNode],
    to mainMenu: NSMenu,
    target: AnyObject,
    action: Selector
  ) {
    for node in nodes {
      guard case .menu(let menu) = node.kind else {
        fatalError("App::menu_bar only accepts top-level Menu values")
      }
      let item = NSMenuItem(title: menu.label, action: nil, keyEquivalent: "")
      item.image = appKitMenuImage(named: menu.iconName)
      let submenu = NSMenu(title: menu.label)
      appendAppKitMenuItems(menu.items.nodes, to: submenu, target: target, action: action)
      item.submenu = submenu
      mainMenu.addItem(item)
    }
  }
#endif
