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
private func getWindowTitle(_ wuiWindow: WuiWindow) -> String {
    guard let titlePtr = wuiWindow.title else { return "Untitled" }
    let ffiStr = waterui_read_computed_str(titlePtr)
    return WuiStr(ffiStr).toString()
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

        // Get window title
        let title = getWindowTitle(wuiWindow)
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
                let env = globalEnv.inner
                if let resolvedSignal = waterui_resolve_color(colorPtr, env) {
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

        // Convert state binding to opaque pointer for use in delegate
        let stateBindingPtr: OpaquePointer? = wuiWindow.state.map {
            OpaquePointer(UnsafeMutableRawPointer($0))
        }

        // Set up window delegate to track state changes and update binding on native close
        let delegate = WindowDelegate(
            stateBinding: stateBindingPtr,
            onClose: { [weak self] closedWindow in
                self?.removeWindow(closedWindow)
            }
        )
        window.delegate = delegate

        // Keep delegate alive
        objc_setAssociatedObject(window, "windowDelegate", delegate, .OBJC_ASSOCIATION_RETAIN)

        // Watch the window's state binding for programmatic close
        if let stateBindingPtr {
            watchWindowState(stateBindingPtr, window: window)
        }

        // Track the window
        activeWindows.append(window)

        // Layout the content with autoresizing (before waiting for ready)
        contentView.frame = containerView.bounds
        contentView.autoresizingMask = [.width, .height]
        contentView.needsLayout = true

        // Wait for all GpuSurfaces to be ready before showing window
        // This prevents flicker from surfaces appearing one-by-one
        Task {
            await contentView.ready()

            // Show the window after all GPU surfaces are ready
            window.center()
            window.makeKeyAndOrderFront(nil)
            logger.debug("Window '\(title)' shown successfully")
        }
    }

    /// Watch the window state binding for programmatic close requests
    private func watchWindowState(_ binding: OpaquePointer, window: NSWindow) {
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
            // Store the watcher guard with the window to keep it alive
            let guardWrapper = WatcherGuard(guard_)
            objc_setAssociatedObject(window, "stateWatcherGuard", guardWrapper, .OBJC_ASSOCIATION_RETAIN)
        }
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
    /// The state binding to update when the native close button is clicked
    let stateBinding: OpaquePointer?
    let onClose: (NSWindow) -> Void

    init(stateBinding: OpaquePointer?, onClose: @escaping (NSWindow) -> Void) {
        self.stateBinding = stateBinding
        self.onClose = onClose
        super.init()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }

        // Update the state binding to Closed so Rust knows the window was closed
        if let binding = stateBinding {
            waterui_set_binding_window_state(binding, WuiWindowState_Closed)
        }

        onClose(window)
    }
}

#endif
