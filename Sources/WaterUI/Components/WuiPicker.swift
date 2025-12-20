// WuiPicker.swift
// Picker component - select from a list of options
//
// # Layout Behavior
// Picker sizes itself to fit its content and never stretches to fill extra space.
// In a stack, it takes only the space it needs.

import CWaterUI
import os.log

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

private let logger = Logger(subsystem: "dev.waterui", category: "WuiPicker")

/// Represents a picker item with an id and text content
struct PickerItemData {
    let id: WuiId
    let text: String
}

@MainActor
final class WuiPicker: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_picker_id() }

    #if canImport(UIKit)
    private let picker = UISegmentedControl()
    #elseif canImport(AppKit)
    private let picker = NSPopUpButton()
    #endif

    private var items: [PickerItemData] = []
    private var selectionBinding: WuiBinding<WuiId>
    private var itemsComputed: WuiComputed<CWaterUI.WuiArray_WuiPickerItem>
    private var itemsWatcher: WatcherGuard?
    private var selectionWatcher: WatcherGuard?
    private var isSyncingFromBinding = false
    private var env: WuiEnvironment

    // MARK: - WuiComponent Init

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
        let ffiPicker: CWaterUI.WuiPicker = waterui_force_as_picker(anyview)
        self.init(
            items: WuiComputed<CWaterUI.WuiArray_WuiPickerItem>(ffiPicker.items!),
            selection: WuiBinding<WuiId>(ffiPicker.selection!),
            env: env
        )
    }

    // MARK: - Designated Init

    init(
        items: WuiComputed<CWaterUI.WuiArray_WuiPickerItem>,
        selection: WuiBinding<WuiId>,
        env: WuiEnvironment
    ) {
        self.itemsComputed = items
        self.selectionBinding = selection
        self.env = env
        super.init(frame: .zero)
        configureSubviews()
        updateItems(items.value)
        startWatching()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - WuiComponent

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        #if canImport(UIKit)
        return picker.intrinsicContentSize
        #elseif canImport(AppKit)
        return picker.intrinsicContentSize
        #endif
    }

    // MARK: - Layout

    #if canImport(AppKit)
    override var isFlipped: Bool { true }
    #endif

    #if canImport(UIKit)
    override func layoutSubviews() {
        super.layoutSubviews()
        picker.frame = bounds
    }
    #elseif canImport(AppKit)
    override func layout() {
        super.layout()
        picker.frame = bounds
    }
    #endif

    // MARK: - Configuration

    private func configureSubviews() {
        #if canImport(UIKit)
        picker.translatesAutoresizingMaskIntoConstraints = false
        addSubview(picker)
        NSLayoutConstraint.activate([
            picker.leadingAnchor.constraint(equalTo: leadingAnchor),
            picker.trailingAnchor.constraint(equalTo: trailingAnchor),
            picker.topAnchor.constraint(equalTo: topAnchor),
            picker.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        picker.addTarget(self, action: #selector(selectionChanged), for: .valueChanged)
        #elseif canImport(AppKit)
        picker.translatesAutoresizingMaskIntoConstraints = false
        addSubview(picker)
        NSLayoutConstraint.activate([
            picker.leadingAnchor.constraint(equalTo: leadingAnchor),
            picker.trailingAnchor.constraint(equalTo: trailingAnchor),
            picker.topAnchor.constraint(equalTo: topAnchor),
            picker.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        picker.target = self
        picker.action = #selector(selectionChanged)
        #endif
    }

    private func updateItems(_ array: CWaterUI.WuiArray_WuiPickerItem) {
        let slice = array.vtable.slice(array.data)
        guard let head = slice.head else {
            items = []
            rebuildPicker()
            return
        }

        var newItems: [PickerItemData] = []
        for i in 0..<slice.len {
            let item = head.advanced(by: Int(i)).pointee
            let text = extractText(from: item.content)
            newItems.append(PickerItemData(id: item.tag, text: text))
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
        picker.removeAllSegments()
        for (index, item) in items.enumerated() {
            picker.insertSegment(withTitle: item.text, at: index, animated: false)
        }
        #elseif canImport(AppKit)
        picker.removeAllItems()
        for item in items {
            picker.addItem(withTitle: item.text)
        }
        #endif
    }

    private func syncSelectionFromBinding() {
        isSyncingFromBinding = true
        let currentId = selectionBinding.value
        if let index = items.firstIndex(where: { $0.id == currentId }) {
            #if canImport(UIKit)
            picker.selectedSegmentIndex = index
            #elseif canImport(AppKit)
            picker.selectItem(at: index)
            #endif
        }
        isSyncingFromBinding = false
    }

    private func startWatching() {
        // Watch for items changes
        itemsWatcher = itemsComputed.watch { [weak self] value, metadata in
            guard let self else { return }
            withPlatformAnimation(metadata) {
                self.updateItems(value)
            }
        }

        // Watch for selection changes
        selectionWatcher = selectionBinding.watch { [weak self] value, metadata in
            guard let self, !isSyncingFromBinding else { return }
            withPlatformAnimation(metadata) {
                self.syncSelectionFromBinding()
            }
        }
    }

    @objc private func selectionChanged() {
        guard !isSyncingFromBinding else { return }

        #if canImport(UIKit)
        let selectedIndex = picker.selectedSegmentIndex
        #elseif canImport(AppKit)
        let selectedIndex = picker.indexOfSelectedItem
        #endif

        guard selectedIndex >= 0 && selectedIndex < items.count else { return }
        let selectedId = items[selectedIndex].id
        selectionBinding.set(selectedId)
    }
}
