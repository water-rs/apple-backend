// WuiWindowManager.swift
// Window manager service that creates and displays native windows
//
// # Platform Support
// - macOS: Uses NSWindow
// - iOS: Not supported (iOS doesn't support multiple windows in the same way)
//
// # Features
// - Creates native windows from WuiWindow configuration
// - Supports different window styles (Titled, Borderless, FullSizeContentView)
// - Supports window backgrounds (Opaque, Color)
// - Material blur effects are handled via MaterialBackground metadata on content

import CWaterUI
import os.log

#if canImport(AppKit)
import AppKit
import QuartzCore
#elseif canImport(UIKit)
import UIKit
#endif

private let logger = Logger(subsystem: "dev.waterui", category: "WindowManager")

// MARK: - Window Show Implementation

/// C-compatible function pointer for showing windows.
/// Called by Rust when a Window view is rendered.
private let showWindowImpl: @convention(c) (WuiWindow) -> Void = { wuiWindow in
    #if os(macOS)
    // Capture the window data to safely pass across actor boundaries
    nonisolated(unsafe) let capturedWindow = wuiWindow
    // Defer window creation to the next run loop iteration to avoid reentrancy
    // issues with the environment during the parent view's body() call
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            WindowManagerImpl.shared.showWindow(capturedWindow)
        }
    }
    #else
    // iOS doesn't support creating new windows in the traditional sense
    logger.warning("Multi-window not supported on iOS.")
    #endif
}

/// Get the window title from a WuiWindow
@MainActor
private func getWindowTitle(_ titlePtr: OpaquePointer?) -> String {
    guard let titlePtr else { return "Untitled" }
    let ffiStr = waterui_read_computed_str(titlePtr)
    return WuiStr(ffiStr).toString()
}

private final class WindowResources {
    var title: OpaquePointer?
    var titleWatcher: WatcherGuard?

    var stateBinding: OpaquePointer?
    var stateWatcher: WatcherGuard?

    var minSize: OpaquePointer?
    var minSizeWatcher: WatcherGuard?

    var maxSize: OpaquePointer?
    var maxSizeWatcher: WatcherGuard?

    func stopWatchers() {
        titleWatcher = nil
        stateWatcher = nil
        minSizeWatcher = nil
        maxSizeWatcher = nil
    }

    deinit {
        stopWatchers()

        if let stateBinding {
            waterui_drop_binding_window_state(stateBinding)
        }
        if let title {
            waterui_drop_computed_str(title)
        }
        if let minSize {
            waterui_drop_computed_size(minSize)
        }
        if let maxSize {
            waterui_drop_computed_size(maxSize)
        }
    }
}

/// Installs the WindowManager into the environment.
/// Call this during WaterUI initialization to enable multi-window functionality.
public func installWindowManager(env: OpaquePointer?) {
    waterui_env_install_window_manager(env, showWindowImpl)
}

// MARK: - macOS Window Manager Implementation

#if os(macOS)

/// Swift implementation of WindowManager for macOS
@MainActor
final class WindowManagerImpl {
    static let shared = WindowManagerImpl()

    /// Track active windows to prevent deallocation
    private var activeWindows: [NSWindow] = []

    private init() {}

    /// Show a window using the WuiWindow configuration
    func showWindow(_ wuiWindow: WuiWindow) {
        logger.debug("showWindow called")

        guard let rawContent = wuiWindow.content else {
            logger.error("Window content is nil, cannot show window")
            return
        }
        // Convert UnsafeMutablePointer to OpaquePointer via UnsafeMutableRawPointer
        let contentPtr = OpaquePointer(UnsafeMutableRawPointer(rawContent))
        logger.debug("Content pointer: \(String(describing: contentPtr))")

        // Use the global environment for rendering window content
        guard let globalEnv = globalEnvironment else {
            logger.error("Global environment is nil, cannot show window")
            return
        }
        logger.debug("Global environment: \(String(describing: globalEnv.inner))")

        let resources = WindowResources()
        resources.title = wuiWindow.title.map { OpaquePointer(UnsafeMutableRawPointer($0)) }
        resources.stateBinding = wuiWindow.state.map { OpaquePointer(UnsafeMutableRawPointer($0)) }
        resources.minSize = wuiWindow.min_size.map { OpaquePointer(UnsafeMutableRawPointer($0)) }
        resources.maxSize = wuiWindow.max_size.map { OpaquePointer(UnsafeMutableRawPointer($0)) }

        // Get window title
        let title = getWindowTitle(resources.title)
        logger.debug("Creating window: \(title)")

        // Create window with appropriate style
        let styleMask = windowStyleMask(from: wuiWindow.style)
        let contentRect = NSRect(x: 100, y: 100, width: 800, height: 600)

        let window = NSWindow(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )

        window.title = title
        window.isReleasedWhenClosed = false

        // Configure window properties
        if wuiWindow.resizable {
            window.styleMask.insert(.resizable)
        }
        if !wuiWindow.closable {
            window.styleMask.remove(.closable)
        }

        // Optional toolbar content rendered in the titlebar.
        // This uses NSTitlebarAccessoryViewController so the toolbar automatically
        // benefits from the system titlebar materials (macOS “liquid glass”).
        if let rawToolbar = wuiWindow.toolbar {
            let toolbarPtr = OpaquePointer(UnsafeMutableRawPointer(rawToolbar))
            let toolbarView = WuiAnyView(anyview: toolbarPtr, env: globalEnv)

            let accessory = NSTitlebarAccessoryViewController()
            accessory.view = toolbarView
            accessory.layoutAttribute = .top
            window.addTitlebarAccessoryViewController(accessory)

            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true

            objc_setAssociatedObject(window, "windowToolbarAccessory", accessory, .OBJC_ASSOCIATION_RETAIN)
        }

        // Create content view by rendering the WuiAnyView with the global environment
        let contentView = WuiAnyView(anyview: contentPtr, env: globalEnv)

        // Create container and apply background
        // Note: Material blur is now handled via MaterialBackground metadata on content,
        // not as a window background style. Window only supports Opaque and Color.
        let containerView = NSView(frame: contentRect)
        containerView.wantsLayer = true

        switch wuiWindow.background.tag {
        case WuiWindowBackground_Color:
            if let colorPtr = wuiWindow.background.color.color {
                // Native takes ownership of the color pointer passed in `WuiWindowBackground::Color`.
                // Resolve it once for the NSWindow and then drop the pointer.
                let env = globalEnv.inner
                let ownedColor = OpaquePointer(UnsafeMutableRawPointer(colorPtr))
                defer { waterui_drop_color(ownedColor) }

                if let resolvedSignal = waterui_resolve_color(ownedColor, env) {
                    let resolvedColor = waterui_read_computed_resolved_color(resolvedSignal)
                    let nsColor = NSColor(
                        red: CGFloat(resolvedColor.red),
                        green: CGFloat(resolvedColor.green),
                        blue: CGFloat(resolvedColor.blue),
                        alpha: CGFloat(resolvedColor.opacity)
                    )
                    window.backgroundColor = nsColor
                    window.isOpaque = resolvedColor.opacity >= 1.0
                    window.hasShadow = true
                    waterui_drop_computed_resolved_color(resolvedSignal)
                }
            }

        default: // Opaque
            window.backgroundColor = .windowBackgroundColor
            window.isOpaque = true
        }

        // Add content on top of container
        containerView.addSubview(contentView)
        window.contentView = containerView

        // Set up window delegate to track state changes and update binding on native close
        let delegate = WindowDelegate(
            resources: resources,
            contentView: contentView,
            onClose: { [weak self] closedWindow in
                self?.removeWindow(closedWindow)
            }
        )
        window.delegate = delegate

        // Keep delegate alive
        objc_setAssociatedObject(window, "windowDelegate", delegate, .OBJC_ASSOCIATION_RETAIN)

        // Watch the window's state binding for programmatic changes (close/minimize/fullscreen)
        if let stateBindingPtr = resources.stateBinding {
            resources.stateWatcher = watchWindowState(stateBindingPtr, window: window)
        }

        // Watch title for live updates
        if let titlePtr = resources.title {
            let watcher = makeStrWatcher { [weak window] str, _ in
                guard let window else { return }
                window.title = str.toString()
            }
            if let guardPtr = waterui_watch_computed_str(titlePtr, watcher) {
                resources.titleWatcher = WatcherGuard(guardPtr)
            }
        }

        // Explicit Window::min_size: overrides the measured-content resize floor
        // (without it, the content view keeps deriving contentMinSize from layout).
        if let minPtr = resources.minSize {
            let initial = waterui_read_computed_size(minPtr)
            contentView.explicitWindowMinSize = NSSize(
                width: CGFloat(initial.width), height: CGFloat(initial.height))
            let watcher = makeSizeWatcher { [weak contentView] size, _ in
                contentView?.explicitWindowMinSize = NSSize(
                    width: CGFloat(size.width), height: CGFloat(size.height))
            }
            if let guardPtr = waterui_watch_computed_size(minPtr, watcher) {
                resources.minSizeWatcher = WatcherGuard(guardPtr)
            }
        }

        // Explicit Window::max_size: without one the window stays unconstrained.
        if let maxPtr = resources.maxSize {
            let initial = waterui_read_computed_size(maxPtr)
            window.contentMaxSize = NSSize(
                width: CGFloat(initial.width), height: CGFloat(initial.height))
            let watcher = makeSizeWatcher { [weak window] size, _ in
                window?.contentMaxSize = NSSize(
                    width: CGFloat(size.width), height: CGFloat(size.height))
            }
            if let guardPtr = waterui_watch_computed_size(maxPtr, watcher) {
                resources.maxSizeWatcher = WatcherGuard(guardPtr)
            }
        }

        // Track the window
        activeWindows.append(window)

        // Ensure mouse move events are delivered for hover-driven interactions (e.g. GpuSurface pointer tracking)
        window.acceptsMouseMovedEvents = true

        // Layout the content with autoresizing (before waiting for ready)
        contentView.frame = containerView.bounds
        contentView.autoresizingMask = [.width, .height]
        contentView.needsLayout = true
        contentView.refreshWindowMinSize(force: true)

        // IMPORTANT (GpuSurface first frame on macOS):
        // CAMetalLayer-backed swapchains often can't produce a drawable until the window is
        // actually on-screen. To keep native/GPU content appearing consistently, keep the window
        // transparent while warm-up runs, then reveal once ready() completes.
        window.center()
        window.alphaValue = 0.0
        window.makeKeyAndOrderFront(nil)

        Task {
            await contentView.ready()

            await MainActor.run {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.12
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    window.animator().alphaValue = 1.0
                }
                logger.debug("Window '\(title)' shown successfully")
            }
        }
    }

    /// Watch the window state binding for programmatic close requests
    private func watchWindowState(_ binding: OpaquePointer, window: NSWindow) -> WatcherGuard? {
        // Create a watcher to monitor state changes
        let windowRef = Unmanaged.passUnretained(window).toOpaque()

        let watcher = waterui_new_watcher_window_state(
            windowRef,
            { data, state, _ in
                guard let data = data else { return }
                let window = Unmanaged<NSWindow>.fromOpaque(data).takeUnretainedValue()

                if state == WuiWindowState_Closed {
                    Task { @MainActor in
                        window.close()
                    }
                } else if state == WuiWindowState_Minimized {
                    Task { @MainActor in
                        window.miniaturize(nil)
                    }
                } else if state == WuiWindowState_Fullscreen {
                    Task { @MainActor in
                        window.toggleFullScreen(nil)
                    }
                }
            },
            nil  // No drop needed - window lifecycle manages this
        )

        if let watcher = watcher, let guard_ = waterui_watch_binding_window_state(binding, watcher) {
            return WatcherGuard(guard_)
        }
        return nil
    }

    /// Remove a window from tracking
    private func removeWindow(_ window: NSWindow) {
        activeWindows.removeAll { $0 === window }
    }

    /// Convert WuiWindowStyle to NSWindow.StyleMask
    private func windowStyleMask(from style: WuiWindowStyle) -> NSWindow.StyleMask {
        switch style {
        case WuiWindowStyle_Titled:
            return [.titled, .closable, .miniaturizable]
        case WuiWindowStyle_Borderless:
            return [.borderless]
        case WuiWindowStyle_FullSizeContentView:
            return [.titled, .closable, .miniaturizable, .fullSizeContentView]
        default:
            return [.titled, .closable, .miniaturizable]
        }
    }
}

/// Window delegate to track state changes and cleanup
private class WindowDelegate: NSObject, NSWindowDelegate {
    private var resources: WindowResources?
    let onClose: (NSWindow) -> Void
    /// Reference to the content view for dynamic min size updates
    weak var contentView: WuiAnyView?

    init(resources: WindowResources, contentView: WuiAnyView?, onClose: @escaping (NSWindow) -> Void) {
        self.resources = resources
        self.contentView = contentView
        self.onClose = onClose
        super.init()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }

        // Update the state binding to Closed so Rust knows the window was closed
        if let binding = resources?.stateBinding {
            waterui_set_binding_window_state(binding, WuiWindowState_Closed)
        }

        // Stop watchers first to avoid callbacks racing during teardown.
        resources?.stopWatchers()
        resources = nil

        onClose(window)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        contentView?.refreshWindowMinSize(force: true)
    }
}

#endif
