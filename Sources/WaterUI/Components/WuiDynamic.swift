// WuiDynamic.swift
// Dynamic view component - merged UIKit and AppKit implementation
//
// # Layout Behavior
// Dynamic view wraps a child that can change at runtime.
// Layout behavior matches the current child view.
//
// // INTERNAL: Layout Contract for Backend Implementers
// // - stretchAxis: Delegates to current child (WuiAnyView)
// // - sizeThatFits: Delegates to current child
// // - Priority: Delegates to current child

import CWaterUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
final class WuiDynamic: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_dynamic_id() }

    private var dynamicPtr: OpaquePointer
    private var env: WuiEnvironment
    private var currentChild: WuiAnyView?

    // MARK: - WuiComponent Init

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
        let dynamicPtr = waterui_force_as_dynamic(anyview)!
        self.init(dynamic: dynamicPtr, env: env)
    }

    // MARK: - Designated Init

    init(dynamic: OpaquePointer, env: WuiEnvironment) {
        self.dynamicPtr = dynamic
        self.env = env
        super.init(frame: .zero)
        setupWatcher()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - WuiComponent

    var stretchAxis: WuiStretchAxis {
        currentChild?.stretchAxis ?? .none
    }

    func layoutPriority() -> Int32 {
        currentChild?.layoutPriority() ?? 0
    }

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        currentChild?.sizeThatFits(proposal) ?? .zero
    }

    // MARK: - Watcher Setup

    private func setupWatcher() {
        let watcher = makeAnyViewWatcher(env: env) { [weak self] anyView in
            self?.updateChild(with: anyView)
        }
        waterui_dynamic_connect(dynamicPtr, watcher)
    }

    private func updateChild(with anyView: WuiAnyView) {
        currentChild?.removeFromSuperview()

        anyView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(anyView)
        currentChild = anyView

        // Invalidate layout up the entire view hierarchy
        invalidateLayoutHierarchy()

        // Force synchronous layout pass to ensure content updates immediately
        #if canImport(UIKit)
        layoutIfNeeded()
        #elseif canImport(AppKit)
        layoutSubtreeIfNeeded()
        #endif
    }

    #if canImport(UIKit)
    override func layoutSubviews() {
        super.layoutSubviews()
        currentChild?.frame = bounds
    }
    #elseif canImport(AppKit)
    override func layout() {
        super.layout()
        currentChild?.frame = bounds
    }
    #endif

    #if canImport(AppKit)
    override var isFlipped: Bool { true }
    #endif
}
