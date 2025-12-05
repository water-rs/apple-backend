// WuiNavigationStack.swift
// Navigation stack container component
//
// # Layout Behavior
// NavigationStack stretches to fill available space (greedy).
// Manages a stack of navigation views.
//
// # Note
// Full push/pop functionality requires bidirectional FFI callbacks.
// This initial implementation renders the root view only.

import CWaterUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
final class WuiNavigationStack: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_navigation_stack_id() }

    private(set) var stretchAxis: WuiStretchAxis = .both

    private var rootView: WuiAnyView
    private let env: WuiEnvironment

    #if canImport(UIKit)
    // On iOS, we use UINavigationController for native navigation
    private var navigationController: UINavigationController?
    #endif

    // MARK: - WuiComponent Init

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
        let ffiStack: CWaterUI.WuiNavigationStack = waterui_force_as_navigation_stack(anyview)
        let rootView = WuiAnyView(anyview: ffiStack.root, env: env)
        self.init(root: rootView, env: env)
    }

    // MARK: - Designated Init

    init(root: WuiAnyView, env: WuiEnvironment) {
        self.rootView = root
        self.env = env
        super.init(frame: .zero)

        configureContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Configuration

    private func configureContent() {
        // For now, just embed the root view directly
        // Full navigation stack functionality will be added later
        // when bidirectional FFI callbacks are implemented
        rootView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(rootView)
    }

    // MARK: - WuiComponent

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        // NavigationStack takes all available space
        let width = proposal.width.map { CGFloat($0) } ?? 320
        let height = proposal.height.map { CGFloat($0) } ?? 480
        return CGSize(width: width, height: height)
    }

    #if canImport(UIKit)
    override func layoutSubviews() {
        super.layoutSubviews()
        rootView.frame = bounds
    }
    #elseif canImport(AppKit)
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        rootView.frame = bounds
    }
    #endif
}
