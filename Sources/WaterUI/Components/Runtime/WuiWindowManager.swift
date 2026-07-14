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
import OSLog

#if canImport(AppKit)
  import AppKit
  import QuartzCore
#elseif canImport(UIKit)
  import UIKit
#endif

// MARK: - Window Show Implementation

private struct WuiWindowManagerInvocation: @unchecked Sendable {
  let context: UnsafeMutableRawPointer?
  let window: WuiWindow
}

/// C-compatible function pointer for showing windows.
/// Called by Rust when a Window view is rendered.
private let showWindowImpl: @convention(c) (UnsafeMutableRawPointer?, WuiWindow) -> Void = {
  context, wuiWindow in
  precondition(Thread.isMainThread, "WindowManager must be invoked on WaterUI's UI executor")
  let invocation = WuiWindowManagerInvocation(context: context, window: wuiWindow)
  MainActor.assumeIsolated {
    guard let context = invocation.context else {
      fatalError("WaterUI WindowManager received a null owner context")
    }
    let services = Unmanaged<WuiNativeServices>.fromOpaque(context).takeUnretainedValue()
    guard let env = services.environment else {
      fatalError("WaterUI WindowManager outlived its application environment")
    }
    #if os(macOS)
      // Preserve the owned descriptor until the parent body evaluation returns.
      DispatchQueue.main.async {
        services.windowManager.showWindow(invocation.window, env: env)
      }
    #else
      fatalError("WaterUI multi-window is unsupported on iOS")
    #endif
  }
}

#if os(macOS)
  @MainActor
  private final class WindowResources {
    var titleObservation: WuiComputedObservation<WuiStr>?

    var frameBinding: WuiBinding<CWaterUI.WuiRect>?
    var frameWatcher: WatcherGuard?
    private var isApplyingFrame = false

    var stateBinding: WuiBinding<CWaterUI.WuiWindowState>?
    var stateWatcher: WatcherGuard?
    weak var window: NSWindow?

    var minSizeObservation: WuiComputedObservation<CWaterUI.WuiSize>?

    var maxSizeObservation: WuiComputedObservation<CWaterUI.WuiSize>?
    var backgroundObservation: WuiComputedObservation<WuiResolvedColor>?

    func stopWatchers() {
      titleObservation = nil
      frameWatcher = nil
      stateWatcher = nil
      minSizeObservation = nil
      maxSizeObservation = nil
      backgroundObservation = nil
    }

    @MainActor deinit {
      stopWatchers()
    }

    var initialFrame: NSRect {
      guard let frameBinding else {
        fatalError("Window frame binding was not installed")
      }
      let frame = WuiRect(frameBinding.value).cgRect
      precondition(frame.width > 0 && frame.height > 0, "Window frame must have non-zero size")
      return frame
    }

    func startWatchingFrame(window: NSWindow) {
      guard let frameBinding else {
        fatalError("Window frame binding was not installed")
      }
      frameWatcher = frameBinding.watch { [weak self, weak window] rawFrame, metadata in
        guard let self, let window else { return }
        let frame = WuiRect(rawFrame).cgRect
        precondition(frame.width > 0 && frame.height > 0, "Window frame must have non-zero size")
        guard window.frame != frame else { return }
        isApplyingFrame = true
        window.setFrame(frame, display: true, animate: metadata.animation != nil)
        isApplyingFrame = false
      }

      let frame = WuiRect(frameBinding.value).cgRect
      precondition(frame.width > 0 && frame.height > 0, "Window frame must have non-zero size")
      if window.frame != frame {
        isApplyingFrame = true
        window.setFrame(frame, display: true)
        isApplyingFrame = false
      }
    }

    func publishFrame(of window: NSWindow) {
      guard !isApplyingFrame else { return }
      guard let frameBinding else {
        fatalError("Window frame binding was not installed")
      }
      guard WuiRect(frameBinding.value).cgRect != window.frame else { return }
      frameBinding.set(WuiRect(window.frame).toCStruct())
    }

    func applyState(_ state: WuiWindowState) {
      guard let window else {
        fatalError("Window state binding outlived its NSWindow")
      }
      switch state {
      case WuiWindowState_Normal:
        if window.isMiniaturized {
          window.deminiaturize(nil)
        } else if window.styleMask.contains(.fullScreen) {
          window.toggleFullScreen(nil)
        }
      case WuiWindowState_Closed:
        window.close()
      case WuiWindowState_Minimized:
        if !window.isMiniaturized {
          window.miniaturize(nil)
        }
      case WuiWindowState_Fullscreen:
        if !window.styleMask.contains(.fullScreen) {
          window.toggleFullScreen(nil)
        }
      default:
        fatalError("Unsupported Window state: \(state.rawValue)")
      }
    }

    func publishState(_ state: WuiWindowState) {
      guard let stateBinding else {
        fatalError("Window state binding was not installed")
      }
      guard stateBinding.value != state else { return }
      stateBinding.set(state)
    }
  }
#endif

/// Installs the WindowManager into the environment.
/// Call this during WaterUI initialization to enable multi-window functionality.
@MainActor
func installWindowManager(env: OpaquePointer, services: WuiNativeServices) {
  waterui_env_install_window_manager(
    env,
    retainWuiNativeServices(services),
    showWindowImpl,
    dropWuiNativeServices
  )
}

// MARK: - macOS Window Manager Implementation

#if os(macOS)

  /// Swift implementation of WindowManager for macOS
  @MainActor
  final class WindowManagerImpl {
    /// Track active windows to prevent deallocation
    private var activeWindows: [NSWindow] = []

    init() {}

    /// Show a window using the WuiWindow configuration
    func showWindow(_ wuiWindow: WuiWindow, env: WuiEnvironment) {
      Logger.waterui.debug("showWindow called")

      guard let rawContent = wuiWindow.content else {
        fatalError("Window content is null")
      }
      // Convert UnsafeMutablePointer to OpaquePointer via UnsafeMutableRawPointer
      let contentPtr = OpaquePointer(UnsafeMutableRawPointer(rawContent))
      Logger.waterui.debug("Content pointer: \(String(describing: contentPtr))")

      Logger.waterui.debug("Environment: \(String(describing: env.inner))")

      let resources = WindowResources()
      guard let rawTitle = wuiWindow.title else {
        fatalError("Window title signal is null")
      }
      let titleObservation = WuiComputedObservation(
        WuiComputed<WuiStr>(OpaquePointer(UnsafeMutableRawPointer(rawTitle)))
      ) { [weak resources] title, _ in
        resources?.window?.title = title.toString()
      }
      resources.titleObservation = titleObservation

      guard let frame = wuiWindow.frame else {
        fatalError("Window frame binding is null")
      }
      resources.frameBinding = WuiBinding<CWaterUI.WuiRect>(
        OpaquePointer(UnsafeMutableRawPointer(frame))
      )

      guard let state = wuiWindow.state else {
        fatalError("Window state binding is null")
      }
      let stateBinding = WuiBinding<CWaterUI.WuiWindowState>(
        OpaquePointer(UnsafeMutableRawPointer(state))
      )
      resources.stateBinding = stateBinding

      Logger.waterui.debug("Creating window: \(titleObservation.value.toString())")

      // Create window with appropriate style
      var styleMask = windowStyleMask(from: wuiWindow.style)
      if wuiWindow.resizable {
        styleMask.insert(.resizable)
      }
      if !wuiWindow.closable {
        styleMask.remove(.closable)
      }
      let frameRect = resources.initialFrame
      let contentRect = NSWindow.contentRect(forFrameRect: frameRect, styleMask: styleMask)

      let window = NSWindow(
        contentRect: contentRect,
        styleMask: styleMask,
        backing: .buffered,
        defer: false
      )

      window.isReleasedWhenClosed = false
      resources.window = window
      window.title = titleObservation.value.toString()

      // Optional toolbar content rendered in the titlebar.
      // This uses NSTitlebarAccessoryViewController so the toolbar automatically
      // benefits from the system titlebar materials (macOS “liquid glass”).
      if let rawToolbar = wuiWindow.toolbar {
        let toolbarPtr = OpaquePointer(UnsafeMutableRawPointer(rawToolbar))
        let toolbarView = WuiAnyView(anyview: toolbarPtr, env: env)

        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = toolbarView
        accessory.layoutAttribute = .top
        window.addTitlebarAccessoryViewController(accessory)

        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true

        objc_setAssociatedObject(
          window, "windowToolbarAccessory", accessory, .OBJC_ASSOCIATION_RETAIN)
      }

      let contentView = WuiAnyView(anyview: contentPtr, env: env)

      // Create container and apply background
      // Note: Material blur is now handled via MaterialBackground metadata on content,
      // not as a window background style. Window only supports Opaque and Color.
      let containerView = NSView(frame: NSRect(origin: .zero, size: contentRect.size))
      containerView.wantsLayer = true

      switch wuiWindow.background.tag {
      case WuiWindowBackground_Color:
        guard let colorPtr = wuiWindow.background.color.color else {
          fatalError("Window color background has no Color handle")
        }
        let ownedColor = OpaquePointer(UnsafeMutableRawPointer(colorPtr))
        let resolved = waterui_resolve_color(ownedColor, env.inner)
        waterui_drop_color(ownedColor)
        guard let resolved else {
          fatalError("Window color background could not be resolved")
        }
        resources.backgroundObservation = observeWindowBackground(
          WuiComputed<WuiResolvedColor>(resolved),
          window: window
        )
      case WuiWindowBackground_Opaque:
        guard let background = waterui_theme_color(env.inner, WuiColorSlot_Background) else {
          fatalError("Window background requires the theme Background color")
        }
        resources.backgroundObservation = observeWindowBackground(
          WuiComputed<WuiResolvedColor>(background),
          window: window
        )
      default:
        fatalError("Unsupported window background: \(wuiWindow.background.tag.rawValue)")
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
      resources.stateWatcher = stateBinding.watch { [weak resources] state, _ in
        resources?.applyState(state)
      }
      resources.startWatchingFrame(window: window)

      // Explicit Window::min_size: overrides the measured-content resize floor
      // (without it, the content view keeps deriving contentMinSize from layout).
      if let rawMinSize = wuiWindow.min_size {
        let observation = WuiComputedObservation(
          WuiComputed<CWaterUI.WuiSize>(
            OpaquePointer(UnsafeMutableRawPointer(rawMinSize))
          )
        ) { [weak contentView] size, _ in
          contentView?.explicitWindowMinSize = NSSize(
            width: CGFloat(size.width), height: CGFloat(size.height))
        }
        resources.minSizeObservation = observation
        let size = observation.value
        contentView.explicitWindowMinSize = NSSize(
          width: CGFloat(size.width), height: CGFloat(size.height)
        )
      }

      // Explicit Window::max_size: without one the window stays unconstrained.
      if let rawMaxSize = wuiWindow.max_size {
        let observation = WuiComputedObservation(
          WuiComputed<CWaterUI.WuiSize>(
            OpaquePointer(UnsafeMutableRawPointer(rawMaxSize))
          )
        ) { [weak window] size, _ in
          window?.contentMaxSize = NSSize(
            width: CGFloat(size.width), height: CGFloat(size.height))
        }
        resources.maxSizeObservation = observation
        let size = observation.value
        window.contentMaxSize = NSSize(
          width: CGFloat(size.width), height: CGFloat(size.height)
        )
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
      window.alphaValue = 0.0
      window.makeKeyAndOrderFront(nil)
      resources.applyState(stateBinding.value)

      Task { @MainActor in
        await contentView.ready()

        await NSAnimationContext.runAnimationGroup { context in
          context.duration = 0.12
          context.timingFunction = CAMediaTimingFunction(name: .easeOut)
          window.animator().alphaValue = 1.0
        }
        Logger.waterui.debug("Window '\(window.title)' shown successfully")
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
        fatalError("Unsupported window style: \(style.rawValue)")
      }
    }
  }

  @MainActor
  private func observeWindowBackground(
    _ color: WuiComputed<WuiResolvedColor>,
    window: NSWindow
  ) -> WuiComputedObservation<WuiResolvedColor> {
    let observation = WuiComputedObservation(color) { [weak window] color, _ in
      guard let window else { return }
      applyWindowBackground(color, to: window)
    }
    applyWindowBackground(observation.value, to: window)
    return observation
  }

  @MainActor
  private func applyWindowBackground(_ color: WuiResolvedColor, to window: NSWindow) {
    window.backgroundColor = color.toNSColor()
    window.isOpaque = color.opacity >= 1
    window.hasShadow = true
  }

  /// Window delegate to track state changes and cleanup
  @MainActor
  private class WindowDelegate: NSObject, NSWindowDelegate {
    private var resources: WindowResources?
    let onClose: (NSWindow) -> Void
    /// Reference to the content view for dynamic min size updates
    weak var contentView: WuiAnyView?

    init(
      resources: WindowResources, contentView: WuiAnyView?, onClose: @escaping (NSWindow) -> Void
    ) {
      self.resources = resources
      self.contentView = contentView
      self.onClose = onClose
      super.init()
    }

    func windowWillClose(_ notification: Notification) {
      guard let window = notification.object as? NSWindow else {
        fatalError("Window close notification has no NSWindow")
      }

      // Update the state binding to Closed so Rust knows the window was closed
      resources?.publishState(WuiWindowState_Closed)

      // Stop watchers first to avoid callbacks racing during teardown.
      resources?.stopWatchers()
      resources = nil

      onClose(window)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
      contentView?.refreshWindowMinSize(force: true)
    }

    func windowDidMove(_ notification: Notification) {
      guard let window = notification.object as? NSWindow else {
        fatalError("Window move notification has no NSWindow")
      }
      resources?.publishFrame(of: window)
    }

    func windowDidResize(_ notification: Notification) {
      guard let window = notification.object as? NSWindow else {
        fatalError("Window resize notification has no NSWindow")
      }
      resources?.publishFrame(of: window)
    }

    func windowDidMiniaturize(_ notification: Notification) {
      resources?.publishState(WuiWindowState_Minimized)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
      resources?.publishState(WuiWindowState_Normal)
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
      resources?.publishState(WuiWindowState_Fullscreen)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
      resources?.publishState(WuiWindowState_Normal)
    }
  }

#endif
