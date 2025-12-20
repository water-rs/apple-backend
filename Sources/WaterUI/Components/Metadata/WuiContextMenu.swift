import CWaterUI
import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Component for Metadata<ContextMenu>.
///
/// Attaches a context menu to the wrapped content view.
/// - iOS: Long press triggers the context menu
/// - macOS: Right-click triggers the context menu
@MainActor
final class WuiContextMenu: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_metadata_context_menu_id() }

    private let contentView: any WuiComponent
    private let env: WuiEnvironment
    private let itemsPtr: OpaquePointer?
    private var disposeBag: [() -> Void] = []

    var stretchAxis: WuiStretchAxis {
        contentView.stretchAxis
    }

    required init(anyview: OpaquePointer, env: WuiEnvironment) {
        let metadata = waterui_force_as_metadata_context_menu(anyview)

        self.env = env
        if let ptr = metadata.value.items {
            self.itemsPtr = OpaquePointer(UnsafeRawPointer(ptr))
        } else {
            self.itemsPtr = nil
        }

        // Resolve the content
        self.contentView = WuiAnyView.resolve(anyview: metadata.content, env: env)

        super.init(frame: .zero)

        contentView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(contentView)

        // Setup context menu
        setupContextMenu()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupContextMenu() {
        #if canImport(UIKit)
        let interaction = UIContextMenuInteraction(delegate: self)
        self.addInteraction(interaction)
        self.isUserInteractionEnabled = true
        #elseif canImport(AppKit)
        // On macOS, we use the menu property and override rightMouseDown
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
            // Get the label text
            guard let textPtr = item.label.content else { continue }
            let styledStr = waterui_read_computed_styled_str(textPtr)
            let label = extractPlainText(from: styledStr)

            var actionPtr: OpaquePointer? = nil
            if let ptr = item.action {
                actionPtr = OpaquePointer(UnsafeRawPointer(ptr))
            }
            menuItems.append(MenuItemData(
                label: label,
                actionPtr: actionPtr
            ))
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

    func layoutPriority() -> Int32 {
        contentView.layoutPriority()
    }

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        contentView.sizeThatFits(proposal)
    }

    #if canImport(UIKit)
    override func layoutSubviews() {
        super.layoutSubviews()
        contentView.frame = bounds
    }
    #elseif canImport(AppKit)
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        contentView.frame = bounds
    }

    override func rightMouseDown(with event: NSEvent) {
        let menuItems = buildMenuItems()
        guard !menuItems.isEmpty else {
            super.rightMouseDown(with: event)
            return
        }

        let menu = NSMenu()
        for (index, item) in menuItems.enumerated() {
            let menuItem = NSMenuItem(
                title: item.label,
                action: #selector(menuItemClicked(_:)),
                keyEquivalent: ""
            )
            menuItem.target = self
            menuItem.tag = index
            menuItem.representedObject = item
            menu.addItem(menuItem)
        }

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func menuItemClicked(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? MenuItemData,
              let actionPtr = item.actionPtr else {
            return
        }
        waterui_call_shared_action(actionPtr, env.inner)
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

// MARK: - UIContextMenuInteractionDelegate (iOS)

#if canImport(UIKit)
extension WuiContextMenu: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        let menuItems = buildMenuItems()
        guard !menuItems.isEmpty else { return nil }

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self = self else { return nil }

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
    }
}
#endif
