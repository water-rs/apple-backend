// WuiPicker.swift
// Picker component - select from a list of options
//
// # Layout Behavior
// Picker sizes itself to fit its content and never stretches to fill extra space.
// In a stack, it takes only the space it needs.

import CWaterUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

private struct PickerItemData {
    let id: WuiId
    let text: String
}

enum PickerStyle {
    case automatic
    case menu
    case radio

    init(_ style: CWaterUI.WuiPickerStyle) {
        switch style {
        case WuiPickerStyle_Menu:
            self = .menu
        case WuiPickerStyle_Radio:
            self = .radio
        default:
            self = .automatic
        }
    }
}

@MainActor
final class WuiPicker: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_picker_id() }

    #if canImport(UIKit)
    private let segmentedControl = UISegmentedControl()
    private let menuButton = UIButton(type: .system)
    private let radioStack = UIStackView()
    #elseif canImport(AppKit)
    private let popupButton = NSPopUpButton()
    private let radioStack = NSStackView()
    #endif

    private var items: [PickerItemData] = []
    private let style: PickerStyle
    private var selectionBinding: WuiBinding<WuiId>
    private var itemsComputed: WuiComputed<CWaterUI.WuiArray_WuiPickerItem>
    private var itemsWatcher: WatcherGuard?
    private var selectionWatcher: WatcherGuard?
    private var isSyncingFromBinding = false

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
        let ffiPicker: CWaterUI.WuiPicker = waterui_force_as_picker(anyview)
        self.init(
            items: WuiComputed<CWaterUI.WuiArray_WuiPickerItem>(ffiPicker.items!),
            selection: WuiBinding<WuiId>(ffiPicker.selection!),
            style: PickerStyle(ffiPicker.style)
        )
    }

    init(
        items: WuiComputed<CWaterUI.WuiArray_WuiPickerItem>,
        selection: WuiBinding<WuiId>,
        style: PickerStyle
    ) {
        self.itemsComputed = items
        self.selectionBinding = selection
        self.style = style
        super.init(frame: .zero)
        configureSubviews()
        updateItems(items.value)
        startWatching()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        #if canImport(UIKit)
        switch style {
        case .automatic:
            return segmentedControl.intrinsicContentSize
        case .menu:
            return menuButton.intrinsicContentSize
        case .radio:
            return radioStack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        }
        #elseif canImport(AppKit)
        switch style {
        case .automatic, .menu:
            return popupButton.intrinsicContentSize
        case .radio:
            return radioStack.fittingSize
        }
        #endif
    }

    #if canImport(AppKit)
    override var isFlipped: Bool { true }
    #endif

    private func configureSubviews() {
        #if canImport(UIKit)
        segmentedControl.translatesAutoresizingMaskIntoConstraints = false
        menuButton.translatesAutoresizingMaskIntoConstraints = false
        radioStack.translatesAutoresizingMaskIntoConstraints = false
        radioStack.axis = .vertical
        radioStack.spacing = 8.0
        menuButton.showsMenuAsPrimaryAction = true
        segmentedControl.addTarget(self, action: #selector(segmentedChanged), for: .valueChanged)
        addSubview(activeControl)
        NSLayoutConstraint.activate(fillConstraints(for: activeControl))
        #elseif canImport(AppKit)
        popupButton.translatesAutoresizingMaskIntoConstraints = false
        radioStack.translatesAutoresizingMaskIntoConstraints = false
        radioStack.orientation = .vertical
        radioStack.spacing = 8.0
        popupButton.target = self
        popupButton.action = #selector(popupChanged)
        addSubview(activeControl)
        NSLayoutConstraint.activate(fillConstraints(for: activeControl))
        #endif
    }

    #if canImport(UIKit)
    private var activeControl: UIView {
        switch style {
        case .automatic:
            segmentedControl
        case .menu:
            menuButton
        case .radio:
            radioStack
        }
    }

    private func fillConstraints(for view: UIView) -> [NSLayoutConstraint] {
        [
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ]
    }
    #elseif canImport(AppKit)
    private var activeControl: NSView {
        switch style {
        case .automatic, .menu:
            popupButton
        case .radio:
            radioStack
        }
    }

    private func fillConstraints(for view: NSView) -> [NSLayoutConstraint] {
        [
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ]
    }
    #endif

    private func updateItems(_ array: CWaterUI.WuiArray_WuiPickerItem) {
        let slice = array.vtable.slice(array.data)
        guard let head = slice.head else {
            items = []
            rebuildPicker()
            return
        }

        var newItems: [PickerItemData] = []
        for i in 0 ..< slice.len {
            let item = head.advanced(by: Int(i)).pointee
            newItems.append(PickerItemData(id: item.tag, text: extractText(from: item.content)))
        }

        items = newItems
        rebuildPicker()
        syncSelectionFromBinding()
    }

    private func extractText(from text: CWaterUI.WuiText) -> String {
        let styledStr = WuiStyledStr(waterui_read_computed_styled_str(text.content))
        return styledStr.toString()
    }

    private func rebuildPicker() {
        #if canImport(UIKit)
        switch style {
        case .automatic:
            segmentedControl.removeAllSegments()
            for (index, item) in items.enumerated() {
                segmentedControl.insertSegment(withTitle: item.text, at: index, animated: false)
            }
        case .menu:
            rebuildMenuButton()
        case .radio:
            rebuildRadioButtons()
        }
        #elseif canImport(AppKit)
        switch style {
        case .automatic, .menu:
            popupButton.removeAllItems()
            items.forEach { popupButton.addItem(withTitle: $0.text) }
        case .radio:
            rebuildRadioButtons()
        }
        #endif
    }

    #if canImport(UIKit)
    private func rebuildMenuButton() {
        let currentId = selectionBinding.value
        let selectedTitle = items.first(where: { $0.id == currentId })?.text ?? "Select"
        menuButton.setTitle(selectedTitle, for: .normal)
        let actions = items.map { item in
            UIAction(
                title: item.text,
                state: item.id == currentId ? .on : .off
            ) { [weak self] _ in
                self?.selectionBinding.set(item.id)
            }
        }
        menuButton.menu = UIMenu(title: "", children: actions)
    }

    private func rebuildRadioButtons() {
        radioStack.arrangedSubviews.forEach {
            radioStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for (index, item) in items.enumerated() {
            let button = UIButton(type: .system)
            button.tag = index
            button.contentHorizontalAlignment = .left
            button.addTarget(self, action: #selector(radioTapped(_:)), for: .touchUpInside)
            radioStack.addArrangedSubview(button)
        }
        syncRadioButtons()
    }

    private func syncRadioButtons() {
        let currentId = selectionBinding.value
        for (index, subview) in radioStack.arrangedSubviews.enumerated() {
            guard let button = subview as? UIButton, index < items.count else { continue }
            let item = items[index]
            let imageName = item.id == currentId ? "circle.inset.filled" : "circle"
            button.setImage(UIImage(systemName: imageName), for: .normal)
            button.setTitle("  \(item.text)", for: .normal)
        }
    }
    #elseif canImport(AppKit)
    private func rebuildRadioButtons() {
        radioStack.arrangedSubviews.forEach {
            radioStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for (index, item) in items.enumerated() {
            let button = NSButton(radioButtonWithTitle: item.text, target: self, action: #selector(radioTapped(_:)))
            button.tag = index
            radioStack.addArrangedSubview(button)
        }
        syncRadioButtons()
    }

    private func syncRadioButtons() {
        let currentId = selectionBinding.value
        for (index, subview) in radioStack.arrangedSubviews.enumerated() {
            guard let button = subview as? NSButton, index < items.count else { continue }
            button.state = items[index].id == currentId ? .on : .off
        }
    }
    #endif

    private func syncSelectionFromBinding() {
        isSyncingFromBinding = true
        let currentId = selectionBinding.value
        if let index = items.firstIndex(where: { $0.id == currentId }) {
            #if canImport(UIKit)
            switch style {
            case .automatic:
                segmentedControl.selectedSegmentIndex = index
            case .menu:
                rebuildMenuButton()
            case .radio:
                syncRadioButtons()
            }
            #elseif canImport(AppKit)
            switch style {
            case .automatic, .menu:
                popupButton.selectItem(at: index)
            case .radio:
                syncRadioButtons()
            }
            #endif
        }
        isSyncingFromBinding = false
    }

    private func startWatching() {
        itemsWatcher = itemsComputed.watch { [weak self] value, metadata in
            guard let self else { return }
            withPlatformAnimation(metadata) {
                self.updateItems(value)
            }
        }

        selectionWatcher = selectionBinding.watch { [weak self] _, metadata in
            guard let self, !isSyncingFromBinding else { return }
            withPlatformAnimation(metadata) {
                self.syncSelectionFromBinding()
            }
        }
    }

    #if canImport(UIKit)
    @objc private func segmentedChanged() {
        guard !isSyncingFromBinding else { return }
        let selectedIndex = segmentedControl.selectedSegmentIndex
        guard selectedIndex >= 0 && selectedIndex < items.count else { return }
        let selectedId = items[selectedIndex].id
        guard selectedId != selectionBinding.value else { return }
        selectionBinding.set(selectedId)
    }

    @objc private func radioTapped(_ sender: UIButton) {
        guard !isSyncingFromBinding, sender.tag >= 0, sender.tag < items.count else { return }
        let selectedId = items[sender.tag].id
        guard selectedId != selectionBinding.value else { return }
        selectionBinding.set(selectedId)
    }
    #elseif canImport(AppKit)
    @objc private func popupChanged() {
        guard !isSyncingFromBinding else { return }
        let selectedIndex = popupButton.indexOfSelectedItem
        guard selectedIndex >= 0 && selectedIndex < items.count else { return }
        let selectedId = items[selectedIndex].id
        guard selectedId != selectionBinding.value else { return }
        selectionBinding.set(selectedId)
    }

    @objc private func radioTapped(_ sender: NSButton) {
        guard !isSyncingFromBinding, sender.tag >= 0, sender.tag < items.count else { return }
        let selectedId = items[sender.tag].id
        guard selectedId != selectionBinding.value else { return }
        selectionBinding.set(selectedId)
    }
    #endif
}
