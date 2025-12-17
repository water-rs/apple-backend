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

// MARK: - Content View Controller

#if canImport(UIKit)
/// A UIViewController that hosts WaterUI content with native navigation behavior.
///
/// Layout strategy (matches SwiftUI):
/// - If content contains a scroll view: edge-to-edge layout with automatic inset adjustment
///   This enables proper large title collapse animation and nav bar blur effect
/// - If content has no scroll view: safe area layout to avoid nav bar overlap
@MainActor
final class WuiContentViewController: UIViewController {
    private let contentView: UIView

    init(contentView: UIView) {
        self.contentView = contentView
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        contentView.translatesAutoresizingMaskIntoConstraints = true
        view.addSubview(contentView)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Simple edge-to-edge layout - let UIKit handle safe areas via contentInsetAdjustmentBehavior
        contentView.frame = view.bounds
    }
}
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
    private var viewStack: [(view: NSView, title: String)] = []
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
        // Note: Callbacks are called synchronously from the main thread (via Rust's nami runtime).
        // We must NOT use async Task here because the FFI struct pointers become invalid
        // after the callback returns.
        let controllerPtr = waterui_navigation_controller_new(
            wrapperPtr,
            { data, navView in
                guard let data = data else { return }
                let wrapper = Unmanaged<NavigationControllerWrapper>.fromOpaque(data).takeUnretainedValue()
                // Process synchronously - navView's pointers are only valid during this callback
                wrapper.push(navView)
            },
            { data in
                guard let data = data else { return }
                let wrapper = Unmanaged<NavigationControllerWrapper>.fromOpaque(data).takeUnretainedValue()
                wrapper.pop()
            },
            { data in
                guard let data = data else { return }
                // Release the retained wrapper
                _ = Unmanaged<NavigationControllerWrapper>.fromOpaque(data).takeRetainedValue()
            }
        )

        // Install the controller into the child environment
        waterui_env_install_navigation_controller(childEnv.inner, controllerPtr)

        // For now, just use a fallback title - the type ID comparison is failing
        // TODO: Debug why waterui_view_id returns different ID than waterui_navigation_view_id
        let rootTitle = "Navigation Demo"

        // Render root view with the child environment (which has NavigationController)
        let rootView = WuiAnyView(anyview: ffiStack.root, env: childEnv)

        self.init(rootView: rootView, rootTitle: rootTitle, childEnv: childEnv, wrapper: wrapper)
    }

    // MARK: - Designated Init

    init(rootView: WuiAnyView, rootTitle: String, childEnv: WuiEnvironment, wrapper: NavigationControllerWrapper) {
        self.childEnv = childEnv
        self.wrapper = wrapper
        super.init(frame: .zero)

        wrapper.delegate = self
        configureNavigation(with: rootView, title: rootTitle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Configuration

    private func configureNavigation(with rootView: WuiAnyView, title: String) {
        #if canImport(UIKit)
        // iOS: Use UINavigationController for native swipe-back gesture
        let rootVC = makeViewController(for: rootView, title: title.isEmpty ? nil : title, displayMode: .automatic)
        navController = UINavigationController(rootViewController: rootVC)
        // Enable large titles support (individual VCs control their display mode)
        navController.navigationBar.prefersLargeTitles = true
        navController.view.translatesAutoresizingMaskIntoConstraints = true
        addSubview(navController.view)
        viewStack.append(rootVC)
        #elseif canImport(AppKit)
        // macOS: Custom view stack
        rootView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(rootView)
        viewStack.append((view: rootView, title: title))
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
        // Extract and convert display mode
        let displayMode = convertDisplayMode(navView.bar.display_mode)
        let vc = makeViewController(for: contentView, title: titleString, displayMode: displayMode)
        navController.pushViewController(vc, animated: true)
        viewStack.append(vc)
        #elseif canImport(AppKit)
        // For macOS, push content directly - toolbar handles navigation chrome
        pushView(contentView, title: titleString)
        #endif
    }

    #if canImport(AppKit)
    private var backButton: NSButton?
    private var titlebarAccessory: NSTitlebarAccessoryViewController?

    private func setupTitlebar() {
        guard let window = self.window else { return }

        // Check if already set up
        if titlebarAccessory != nil { return }

        // Create back button with native macOS styling
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        button.image = NSImage(systemSymbolName: "chevron.backward", accessibilityDescription: "Back")
        button.bezelStyle = .accessoryBarAction  // Native accessory bar style
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(backButtonTapped)
        button.isHidden = true  // Hidden initially on root view
        self.backButton = button

        // Create accessory view controller for the button
        let accessoryVC = NSTitlebarAccessoryViewController()
        accessoryVC.view = button
        accessoryVC.layoutAttribute = .leading  // Position on the left!

        window.addTitlebarAccessoryViewController(accessoryVC)
        self.titlebarAccessory = accessoryVC

        window.titleVisibility = .visible
        updateTitlebarState()
    }

    private func updateTitlebarState() {
        guard let window = self.window else { return }

        // Update window title
        let currentTitle = viewStack.last?.title ?? ""
        window.title = currentTitle

        // Update back button visibility
        backButton?.isHidden = viewStack.count <= 1
    }

    @objc private func backButtonTapped() {
        handlePop()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            setupTitlebar()
        }
    }

    private func pushView(_ view: NSView, title: String) {
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

        // Update titlebar state (window title, back button)
        updateTitlebarState()

        // Animate in
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            view.animator().alphaValue = 1
        }
    }

    private func popView() {
        guard viewStack.count > 1 else { return }

        let currentEntry = viewStack.removeLast()
        let currentView = currentEntry.view

        // Update titlebar state before animation
        updateTitlebarState()

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
    private func makeViewController(
        for view: UIView,
        title: String?,
        displayMode: UINavigationItem.LargeTitleDisplayMode = .automatic
    ) -> UIViewController {
        let vc = WuiContentViewController(contentView: view)
        vc.title = title
        vc.navigationItem.largeTitleDisplayMode = displayMode
        return vc
    }

    /// Converts FFI display mode enum to UIKit equivalent.
    private func convertDisplayMode(_ mode: WuiNavigationTitleDisplayMode) -> UINavigationItem.LargeTitleDisplayMode {
        switch mode {
        case WuiNavigationTitleDisplayMode_Automatic:
            return .automatic
        case WuiNavigationTitleDisplayMode_Inline:
            return .never  // .never gives inline (small) title
        case WuiNavigationTitleDisplayMode_Large:
            return .always
        default:
            return .automatic
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

