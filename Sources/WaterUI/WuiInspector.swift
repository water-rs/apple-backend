import CWaterUI
import Foundation

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

/// Bringing up the inspector from a gesture, the way a browser does.
///
/// A debug build listens on a port and publishes where it is, so the only thing
/// missing from the native side is a way to ask for it. This attaches that ask
/// to the window's own view, below anything an application installs, so a view
/// with a context menu of its own still wins.
///
/// On a Mac the inspector runs alongside the application and this opens it. On a
/// phone or a simulator it runs on the developer's computer instead, so asking
/// here reports the endpoint to the log and reveals the element as soon as that
/// inspector attaches.
@MainActor
enum WuiInspector {
  /// Whether this build has an inspector endpoint to talk to.
  ///
  /// False in a release build, where the gesture is never installed at all
  /// rather than offering something that does nothing.
  static func isAvailable(env: WuiEnvironment) -> Bool {
    waterui_inspector_is_available(env.inner)
  }

  /// Opens the inspector on this application.
  static func open(env: WuiEnvironment) {
    waterui_inspector_open(env.inner)
  }

  /// Reveals one accessibility node in the inspector.
  static func inspect(node: UInt64, env: WuiEnvironment) {
    waterui_inspector_inspect_node(env.inner, node)
  }

  /// Installs the gesture that brings the inspector up.
  ///
  /// Does nothing unless an endpoint is running, so a release build carries the
  /// call but never the menu.
  static func installGesture(on view: PlatformView, env: WuiEnvironment) {
    guard isAvailable(env: env) else { return }

    #if canImport(AppKit)
      // Nothing to install: AppKit delivers secondary clicks through
      // `rightMouseDown`, which the host view overrides. A gesture recognizer
      // here would sit above every control and swallow the mouse tracking that
      // sliders and drags depend on.
      _ = view
    #elseif canImport(UIKit)
      // A phone has no secondary click. A two-finger long press is not something
      // an application is likely to have claimed, and is awkward enough not to
      // be triggered by accident.
      let recognizer = UILongPressGestureRecognizer(
        target: WuiInspectorLongPressTarget.shared,
        action: #selector(WuiInspectorLongPressTarget.handle(_:))
      )
      recognizer.numberOfTouchesRequired = 2
      recognizer.cancelsTouchesInView = false
      WuiInspectorLongPressTarget.shared.register(recognizer: recognizer, env: env)
      view.addGestureRecognizer(recognizer)
    #endif
  }
}

#if canImport(AppKit)
  extension WuiInspector {
    /// Offers "Inspect Element" where the user secondary-clicked.
    ///
    /// Raised from the host view's `rightMouseDown`, so it runs only for the
    /// secondary button and leaves every other event untouched — a view with a
    /// context menu of its own handles the click before it reaches here.
    static func presentMenu(for event: NSEvent, in view: NSView, env: WuiEnvironment) {
      guard isAvailable(env: env) else { return }

      let menu = NSMenu()
      let item = NSMenuItem(
        title: "Inspect Element",
        action: #selector(WuiInspectorMenuTarget.inspect(_:)),
        keyEquivalent: ""
      )
      let target = WuiInspectorMenuTarget(env: env)
      item.target = target
      item.representedObject = target  // the menu item is the only owner
      menu.addItem(item)
      NSMenu.popUpContextMenu(menu, with: event, for: view)
    }
  }

  /// Carries the environment from the menu item to the action.
  @MainActor
  private final class WuiInspectorMenuTarget: NSObject {
    private let env: WuiEnvironment

    init(env: WuiEnvironment) {
      self.env = env
    }

    @objc func inspect(_ sender: NSMenuItem) {
      WuiInspector.open(env: env)
    }
  }
#endif

#if canImport(UIKit)
  /// Holds the environment for each installed recognizer.
  ///
  /// A gesture recognizer does not own its target, so this outlives the call
  /// that installed it and keeps one entry per recognizer.
  @MainActor
  private final class WuiInspectorLongPressTarget {
    static let shared = WuiInspectorLongPressTarget()

    private var environments: [ObjectIdentifier: WuiEnvironment] = [:]

    func register(recognizer: UIGestureRecognizer, env: WuiEnvironment) {
      environments[ObjectIdentifier(recognizer)] = env
    }

    @objc func handle(_ sender: UILongPressGestureRecognizer) {
      guard sender.state == .began,
        let env = environments[ObjectIdentifier(sender)]
      else { return }
      WuiInspector.open(env: env)
    }
  }
#endif
