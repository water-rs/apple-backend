// WuiNavigationStack.swift
// Navigation stack container component with full push/pop support
//
// # Layout Behavior
// NavigationStack stretches to fill available space (greedy).
// Manages a stack of navigation views with native platform navigation.
//
// # Architecture
// Creates a NavigationController (via FFI) that receives push/pop calls from Rust.
// On iOS, uses UINavigationController for native gestures (swipe-back).
// On macOS, uses a custom view stack with animations.

import CWaterUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Navigation Controller Wrapper

/// Wrapper class that receives push/pop callbacks from Rust via FFI.
/// This is retained by the navigation controller and bridged via C callbacks.
@MainActor
final class NavigationControllerWrapper {
    weak var delegate: WuiNavigationStack?

    func push(_ navView: CWaterUI.WuiNavigationView) {
        delegate?.handlePush(navView)
    }

    func pop() {
        delegate?.handlePop()
    }
}

// MARK: - WuiNavigationStack

@MainActor
final class WuiNavigationStack: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_navigation_stack_id() }

    private(set) var stretchAxis: WuiStretchAxis = .both

    private let childEnv: WuiEnvironment
    private var wrapper: NavigationControllerWrapper?

    #if canImport(UIKit)
    private var navController: UINavigationController!
    private var viewStack: [UIViewController] = []
    #elseif canImport(AppKit)
    private var viewStack: [(view: WuiAnyView, title: String)] = []
    private var currentIndex: Int = 0
    #endif

    // MARK: - WuiComponent Init

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
        let ffiStack: CWaterUI.WuiNavigationStack = waterui_force_as_navigation_stack(anyview)

        // Clone the environment to create a child environment
        guard let childEnvPtr = waterui_clone_env(env.inner) else {
            fatalError("Failed to clone environment")
        }
        let childEnv = WuiEnvironment(childEnvPtr)

        // Create the wrapper that will receive push/pop callbacks
        let wrapper = NavigationControllerWrapper()

        // Create FFI callbacks that bridge to the wrapper
        let wrapperPtr = Unmanaged.passRetained(wrapper).toOpaque()

        // Create and install the navigation controller
        let controllerPtr = waterui_navigation_controller_new(
            wrapperPtr,
            { data, navView in
                guard let data = data else { return }
                let wrapper = Unmanaged<NavigationControllerWrapper>.fromOpaque(data).takeUnretainedValue()
                Task { @MainActor in
                    wrapper.push(navView)
                }
            },
            { data in
                guard let data = data else { return }
                let wrapper = Unmanaged<NavigationControllerWrapper>.fromOpaque(data).takeUnretainedValue()
                Task { @MainActor in
                    wrapper.pop()
                }
            },
            { data in
                guard let data = data else { return }
                // Release the retained wrapper
                _ = Unmanaged<NavigationControllerWrapper>.fromOpaque(data).takeRetainedValue()
            }
        )

        // Install the controller into the child environment
        waterui_env_install_navigation_controller(childEnv.inner, controllerPtr)

        // Render root view with the child environment (which has NavigationController)
        let rootView = WuiAnyView(anyview: ffiStack.root, env: childEnv)

        self.init(rootView: rootView, childEnv: childEnv, wrapper: wrapper)
    }

    // MARK: - Designated Init

    init(rootView: WuiAnyView, childEnv: WuiEnvironment, wrapper: NavigationControllerWrapper) {
        self.childEnv = childEnv
        self.wrapper = wrapper
        super.init(frame: .zero)

        wrapper.delegate = self
        configureNavigation(with: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Configuration

    private func configureNavigation(with rootView: WuiAnyView) {
        #if canImport(UIKit)
        // iOS: Use UINavigationController for native swipe-back gesture
        let rootVC = makeViewController(for: rootView, title: nil)
        navController = UINavigationController(rootViewController: rootVC)
        navController.view.translatesAutoresizingMaskIntoConstraints = true
        addSubview(navController.view)
        viewStack.append(rootVC)
        #elseif canImport(AppKit)
        // macOS: Custom view stack
        rootView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(rootView)
        viewStack.append((view: rootView, title: ""))
        #endif
    }

    // MARK: - Push/Pop Handlers

    func handlePush(_ navView: CWaterUI.WuiNavigationView) {
        // Extract title from the navigation bar
        var titleString = ""
        if let contentPtr = navView.bar.title.content {
            let titleContent = WuiComputed<WuiStyledStr>(contentPtr)
            titleString = titleContent.value.toString()
        }

        // Render the content view
        let contentView = WuiAnyView(anyview: navView.content, env: childEnv)

        #if canImport(UIKit)
        let vc = makeViewController(for: contentView, title: titleString)
        navController.pushViewController(vc, animated: true)
        viewStack.append(vc)
        #elseif canImport(AppKit)
        pushView(contentView, title: titleString)
        #endif
    }

    func handlePop() {
        #if canImport(UIKit)
        guard viewStack.count > 1 else { return }
        navController.popViewController(animated: true)
        viewStack.removeLast()
        #elseif canImport(AppKit)
        popView()
        #endif
    }

    #if canImport(UIKit)
    private func makeViewController(for view: WuiAnyView, title: String?) -> UIViewController {
        let vc = UIViewController()
        vc.title = title
        view.translatesAutoresizingMaskIntoConstraints = true
        vc.view.addSubview(view)
        view.frame = vc.view.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        return vc
    }
    #endif

    #if canImport(AppKit)
    private func pushView(_ view: WuiAnyView, title: String) {
        // Hide current view
        if let currentView = viewStack.last?.view {
            currentView.isHidden = true
        }

        // Add new view
        view.translatesAutoresizingMaskIntoConstraints = true
        view.frame = bounds
        view.alphaValue = 0
        addSubview(view)
        viewStack.append((view: view, title: title))

        // Animate in
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            view.animator().alphaValue = 1
            view.animator().frame = bounds
        }
    }

    private func popView() {
        guard viewStack.count > 1 else { return }

        let currentEntry = viewStack.removeLast()
        let currentView = currentEntry.view

        // Animate out
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            currentView.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in
                currentView.removeFromSuperview()
            }
        })

        // Show previous view
        if let previousView = viewStack.last?.view {
            previousView.isHidden = false
        }
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
        navController?.view.frame = bounds
    }
    #elseif canImport(AppKit)
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        // Layout all views in stack to match bounds
        for entry in viewStack {
            entry.view.frame = bounds
        }
    }
    #endif
}
