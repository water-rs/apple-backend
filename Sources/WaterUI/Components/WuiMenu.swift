import CWaterUI
import os

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

private let logger = Logger(subsystem: "dev.waterui", category: "WuiMenu")

/// Menu component that displays a dropdown menu when tapped.
/// - iOS: Uses UIButton with UIMenu
/// - macOS: Uses NSPopUpButton
@MainActor
final class WuiMenu: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_menu_id() }

    private let labelView: any WuiComponent
    private let env: WuiEnvironment
    private let itemsPtr: OpaquePointer?
    private var disposeBag: [() -> Void] = []

    #if canImport(UIKit)
    private let button = UIButton(type: .system)
    #elseif canImport(AppKit)
    private let button = NSPopUpButton(frame: .zero, pullsDown: true)
    #endif

    var stretchAxis: WuiStretchAxis { .none }

    required init(anyview: OpaquePointer, env: WuiEnvironment) {
        let menu = waterui_force_as_menu(anyview)

        self.env = env
        if let ptr = menu.items {
            self.itemsPtr = OpaquePointer(UnsafeRawPointer(ptr))
        } else {
            self.itemsPtr = nil
        }

        // Resolve the label view
        self.labelView = WuiAnyView.resolve(anyview: menu.label, env: env)

        super.init(frame: .zero)

        setupButton()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupButton() {
        #if canImport(UIKit)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)

        // Add label as custom content
        labelView.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(labelView)

        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),

            labelView.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 8),
            labelView.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -8),
            labelView.topAnchor.constraint(equalTo: button.topAnchor, constant: 4),
            labelView.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -4)
        ])

        // Build and attach menu
        button.menu = buildUIMenu()
        button.showsMenuAsPrimaryAction = true

        #elseif canImport(AppKit)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.pullsDown = true
        button.bezelStyle = .regularSquare
        addSubview(button)

        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        // Build menu items
        rebuildMenu()
        #endif
    }

    private func buildMenuItems() -> [MenuItemData] {
        guard let itemsPtr = itemsPtr else { return [] }
        let items = waterui_read_computed_menu_items(itemsPtr)
        var menuItems: [MenuItemData] = []

        let slice = items.vtable.slice(items.data.assumingMemoryBound(to: Void.self))
        guard let head = slice.head else { return [] }

        for i in 0..<slice.len {
            let item = head.advanced(by: Int(i)).pointee
            guard let textPtr = item.label.content else { continue }
            let styledStr = waterui_read_computed_styled_str(textPtr)
            let label = extractPlainText(from: styledStr)

            var actionPtr: OpaquePointer? = nil
            if let ptr = item.action {
                actionPtr = OpaquePointer(UnsafeRawPointer(ptr))
            }
            menuItems.append(MenuItemData(label: label, actionPtr: actionPtr))
        }

        return menuItems
    }

    private func extractPlainText(from styledStr: CWaterUI.WuiStyledStr) -> String {
        var result = ""
        let chunks = styledStr.chunks
        let slice = chunks.vtable.slice(chunks.data.assumingMemoryBound(to: Void.self))
        guard let head = slice.head else { return "" }

        for i in 0..<slice.len {
            let chunk = head.advanced(by: Int(i)).pointee
            let text = WuiStr(chunk.text)
            result += text.toString()
        }

        return result
    }

    #if canImport(UIKit)
    private func buildUIMenu() -> UIMenu {
        let menuItems = buildMenuItems()
        var actions: [UIAction] = []

        for item in menuItems {
            let action = UIAction(title: item.label) { [weak self] _ in
                guard let self = self, let actionPtr = item.actionPtr else { return }
                waterui_call_shared_action(actionPtr, self.env.inner)
            }
            actions.append(action)
        }

        return UIMenu(title: "", children: actions)
    }
    #endif

    #if canImport(AppKit)
    private func rebuildMenu() {
        button.removeAllItems()

        // First item is the "title" shown when menu is closed
        // For pullsDown menus, the first item is displayed as the button title
        let labelText = extractLabelText()
        button.addItem(withTitle: labelText)

        let menuItems = buildMenuItems()
        for (index, item) in menuItems.enumerated() {
            button.addItem(withTitle: item.label)
            if let menuItem = button.item(at: index + 1) {
                menuItem.target = self
                menuItem.action = #selector(menuItemClicked(_:))
                menuItem.tag = index
                menuItem.representedObject = item
            }
        }
    }

    private func extractLabelText() -> String {
        // Try to extract text from the label view
        if let textBase = labelView as? WuiTextBase {
            return textBase.textField.stringValue
        }
        return "Menu"
    }

    @objc private func menuItemClicked(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? MenuItemData,
              let actionPtr = item.actionPtr else {
            return
        }
        waterui_call_shared_action(actionPtr, env.inner)
    }
    #endif

    func layoutPriority() -> Int32 { 0 }

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        let horizontalPadding: CGFloat = 16
        let verticalPadding: CGFloat = 8

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

    #if canImport(UIKit)
    override func layoutSubviews() {
        super.layoutSubviews()
    }
    #elseif canImport(AppKit)
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
    }
    #endif
}

// MARK: - Helper Types

private class MenuItemData {
    let label: String
    let actionPtr: OpaquePointer?

    init(label: String, actionPtr: OpaquePointer?) {
        self.label = label
        self.actionPtr = actionPtr
    }
}
