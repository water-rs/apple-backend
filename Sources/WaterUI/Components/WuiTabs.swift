// WuiTabs.swift
// Tab container component with customizable position
//
// # Layout Behavior
// Tabs stretches to fill available space (greedy).
// Contains a tab bar and content area.
// Tab bar can be positioned at top or bottom.

import CWaterUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
final class WuiTabs: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_tabs_id() }

    private(set) var stretchAxis: WuiStretchAxis = .both

    private let env: WuiEnvironment
    private let position: WuiTabPosition

    // Tab data
    private var tabs: [(id: UInt64, label: WuiAnyView, contentPtr: OpaquePointer?)] = []
    private var currentTabIndex: Int = 0
    private var currentContentView: WuiAnyView?

    // Selection binding
    private var selectionBinding: WuiBinding<WuiId>?
    private var selectionWatcher: WatcherGuard?

    #if canImport(UIKit)
    private let tabBar: UITabBar = UITabBar()
    private let contentContainer: UIView = UIView()
    private let tabBarHeight: CGFloat = 49.0
    #elseif canImport(AppKit)
    private let tabBar: NSSegmentedControl = NSSegmentedControl()
    private let contentContainer: NSView = NSView()
    private let tabBarHeight: CGFloat = 28.0
    #endif

    // MARK: - WuiComponent Init

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
        let ffiTabs: CWaterUI.WuiTabs = waterui_force_as_tabs(anyview)
        self.init(ffiTabs: ffiTabs, env: env)
    }

    // MARK: - Designated Init

    init(ffiTabs: CWaterUI.WuiTabs, env: WuiEnvironment) {
        self.env = env
        self.position = ffiTabs.position

        super.init(frame: .zero)

        // Extract tabs from FFI array
        extractTabs(from: ffiTabs.tabs)

        // Setup selection binding
        setupSelectionBinding(ffiTabs.selection)

        // Configure views
        configureTabBar()
        configureContentContainer()

        // Show initial tab
        if !tabs.isEmpty {
            showTab(at: 0)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Tab Extraction

    private func extractTabs(from array: WuiArray_WuiTab) {
        let slice = array.vtable.slice(array.data)
        guard let head = slice.head else { return }

        for i in 0..<slice.len {
            let tab = head.advanced(by: Int(i)).pointee
            let labelView = WuiAnyView(anyview: tab.label, env: env)
            // tab.content is already an OpaquePointer (WuiTabContent*)
            tabs.append((id: tab.id, label: labelView, contentPtr: tab.content))
        }
    }

    // MARK: - Selection Binding

    private func setupSelectionBinding(_ bindingPtr: OpaquePointer?) {
        guard let bindingPtr = bindingPtr else { return }

        let binding = WuiBinding<WuiId>(bindingPtr)
        self.selectionBinding = binding

        // Find initial tab index - WuiId.inner is Int32, tab.id is UInt64
        let selectedIdValue = UInt64(binding.value.inner)
        if let index = tabs.firstIndex(where: { $0.id == selectedIdValue }) {
            currentTabIndex = index
        }

        // Watch for selection changes
        selectionWatcher = binding.watch { [weak self] newId, _ in
            guard let self = self else { return }
            let newIdValue = UInt64(newId.inner)
            if let index = self.tabs.firstIndex(where: { $0.id == newIdValue }) {
                self.showTab(at: index)
            }
        }
    }

    // MARK: - Configuration

    private func configureTabBar() {
        #if canImport(UIKit)
        tabBar.translatesAutoresizingMaskIntoConstraints = true
        tabBar.delegate = self
        tabBar.items = tabs.enumerated().map { index, tab in
            let item = UITabBarItem(title: "Tab \(index + 1)", image: nil, tag: index)
            return item
        }
        if !tabs.isEmpty {
            tabBar.selectedItem = tabBar.items?.first
        }
        addSubview(tabBar)
        #elseif canImport(AppKit)
        tabBar.translatesAutoresizingMaskIntoConstraints = true
        tabBar.segmentCount = tabs.count
        tabBar.segmentStyle = .automatic
        tabBar.trackingMode = .selectOne

        for (index, _) in tabs.enumerated() {
            tabBar.setLabel("Tab \(index + 1)", forSegment: index)
        }

        if !tabs.isEmpty {
            tabBar.selectedSegment = 0
        }

        tabBar.target = self
        tabBar.action = #selector(tabChanged(_:))
        addSubview(tabBar)
        #endif
    }

    private func configureContentContainer() {
        contentContainer.translatesAutoresizingMaskIntoConstraints = true
        addSubview(contentContainer)
    }

    // MARK: - Tab Switching

    private func showTab(at index: Int) {
        guard index >= 0 && index < tabs.count else { return }

        currentTabIndex = index

        // Remove old content
        currentContentView?.removeFromSuperview()

        // Get or create content view
        let tab = tabs[index]
        if let contentPtr = tab.contentPtr {
            // Call waterui_tab_content to build the NavigationView
            let navView = waterui_tab_content(contentPtr)
            let contentView = WuiAnyView(anyview: navView.content, env: env)
            currentContentView = contentView
            contentView.translatesAutoresizingMaskIntoConstraints = true
            contentContainer.addSubview(contentView)
        }

        // Update selection binding (avoid infinite loop)
        // Convert UInt64 tab.id back to Int32 for WuiId comparison
        let tabIdAsInt32 = Int32(tab.id)
        if selectionBinding?.value.inner != tabIdAsInt32 {
            selectionBinding?.set(WuiId(inner: tabIdAsInt32))
        }

        // Update native tab bar selection
        #if canImport(UIKit)
        if let items = tabBar.items, index < items.count {
            tabBar.selectedItem = items[index]
        }
        #elseif canImport(AppKit)
        tabBar.selectedSegment = index
        #endif

        #if canImport(UIKit)
        setNeedsLayout()
        layoutIfNeeded()
        #elseif canImport(AppKit)
        needsLayout = true
        #endif
    }

    #if canImport(AppKit)
    @objc private func tabChanged(_ sender: NSSegmentedControl) {
        showTab(at: sender.selectedSegment)
    }
    #endif

    // MARK: - WuiComponent

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        let width = proposal.width.map { CGFloat($0) } ?? 320
        let height = proposal.height.map { CGFloat($0) } ?? 480
        return CGSize(width: width, height: height)
    }

    #if canImport(UIKit)
    override func layoutSubviews() {
        super.layoutSubviews()
        performLayout()
    }
    #elseif canImport(AppKit)
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        performLayout()
    }
    #endif

    private func performLayout() {
        let isTop = position == WuiTabPosition_Top

        if isTop {
            // Tab bar at top
            tabBar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: tabBarHeight)
            contentContainer.frame = CGRect(
                x: 0,
                y: tabBarHeight,
                width: bounds.width,
                height: bounds.height - tabBarHeight
            )
        } else {
            // Tab bar at bottom
            let tabBarY = bounds.height - tabBarHeight
            tabBar.frame = CGRect(x: 0, y: tabBarY, width: bounds.width, height: tabBarHeight)
            contentContainer.frame = CGRect(
                x: 0,
                y: 0,
                width: bounds.width,
                height: bounds.height - tabBarHeight
            )
        }

        // Layout content view
        currentContentView?.frame = contentContainer.bounds
    }
}

#if canImport(UIKit)
extension WuiTabs: UITabBarDelegate {
    func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
        showTab(at: item.tag)
    }
}
#endif
