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

  /// Whether anything is watching the accessibility tree.
  ///
  /// The walk below is only worth doing when something reads the result, so
  /// this is asked first and the tree costs nothing when no one is attached.
  static func wantsTree(env: WuiEnvironment) -> Bool {
    waterui_inspector_wants_tree(env.inner)
  }

  /// Publishes the view hierarchy under `root` as an accessibility tree.
  ///
  /// The platform's own accessibility protocol is the source: whatever a screen
  /// reader would be told is what the Inspector shows, so the two cannot drift
  /// apart. Identifiers are the views' own addresses, which are stable for as
  /// long as the views are.
  /// The inspector's id for a view: its address, stable for as long as the
  /// view is. `publishTree` keys the tree by it and `inspect(view:)` reveals
  /// by it, so the two must never compute it differently.
  static func identifier(_ view: PlatformView) -> UInt64 {
    UInt64(UInt(bitPattern: ObjectIdentifier(view).hashValue))
  }

  /// Reveals `view` in the inspector, publishing the tree it belongs to first
  /// when one is being read: the inspector cannot reveal what it has not been
  /// told about, and a selection made before it attaches waits for it.
  static func inspect(view: PlatformView, under root: PlatformView, env: WuiEnvironment) {
    publishTree(root: root, env: env)
    waterui_inspector_inspect_node(env.inner, identifier(view))
  }

  static func publishTree(root: PlatformView, env: WuiEnvironment) {
    guard wantsTree(env: env) else { return }

    var nodes: [WuiInspectorNode] = []
    var childStorage: [[UInt64]] = []

    func store(_ text: String) -> CWaterUI.WuiStr {
      WuiStr(string: text).intoInner()
    }

    func walk(_ view: PlatformView) {
      let children = view.subviews.map(identifier)
      childStorage.append(children)

      let frame = view.convert(view.bounds, to: nil)
      #if canImport(AppKit)
        let label = view.accessibilityLabel() ?? ""
        let role = String(describing: view.accessibilityRole()?.rawValue ?? "group")
        let enabled = view.isAccessibilityEnabled()
      #else
        let label = view.accessibilityLabel ?? ""
        let role = "group"
        let enabled = view.isUserInteractionEnabled
      #endif

      nodes.append(
        WuiInspectorNode(
          id: identifier(view),
          role: store(role.lowercased()),
          label: store(label),
          value: store(""),
          has_bounds: true,
          bounds: (Float(frame.origin.x), Float(frame.origin.y), Float(frame.width), Float(frame.height)),
          enabled: enabled,
          hidden: view.isHidden,
          selected: false,
          has_checked: false,
          checked: false,
          children: nil,
          children_len: UInt(children.count)
        )
      )

      for child in view.subviews {
        walk(child)
      }
    }

    walk(root)

    // Children pointers are filled after the arrays stop moving.
    nodes.withUnsafeMutableBufferPointer { nodeBuffer in
      for index in nodeBuffer.indices {
        childStorage[index].withUnsafeBufferPointer { children in
          nodeBuffer[index].children = children.baseAddress
        }
      }
      waterui_inspector_publish_tree(
        env.inner,
        identifier(root),
        false,
        0,
        nodeBuffer.baseAddress,
        UInt(nodeBuffer.count)
      )
    }
  }

  #if canImport(UIKit)
    /// Installs the gesture that brings the inspector up.
    ///
    /// Does nothing unless an endpoint is running, so a release build carries the
    /// call but never the menu. AppKit installs nothing: it delivers secondary
    /// clicks through `rightMouseDown`, which the host view overrides and routes
    /// to `presentMenu(for:in:env:)`; a gesture recognizer there would sit above
    /// every control and swallow the mouse tracking that sliders and drags
    /// depend on.
    static func installGesture(on view: PlatformView, env: WuiEnvironment) {
      guard isAvailable(env: env) else { return }

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
    }
  #endif
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
      let target = WuiInspectorMenuTarget(env: env, view: view, locationInWindow: event.locationInWindow)
      item.target = target
      item.representedObject = target  // the menu item is the only owner
      menu.addItem(item)
      NSMenu.popUpContextMenu(menu, with: event, for: view)
    }
  }

  /// Carries the environment and the clicked point from the menu item to the
  /// action.
  @MainActor
  private final class WuiInspectorMenuTarget: NSObject {
    private let env: WuiEnvironment
    private weak var view: NSView?
    private let locationInWindow: NSPoint

    init(env: WuiEnvironment, view: NSView?, locationInWindow: NSPoint) {
      self.env = env
      self.view = view
      self.locationInWindow = locationInWindow
    }

    @objc func inspect(_: NSMenuItem) {
      // The element under the secondary click, found the way AppKit itself
      // routes the event: `hitTest` takes the point in the receiver's
      // superview's coordinates, so the window point is converted there.
      guard let root = view?.window?.contentView else { return }
      let point = root.superview?.convert(locationInWindow, from: nil) ?? locationInWindow
      let hit = root.hitTest(point) ?? root
      WuiInspector.inspect(view: hit, under: root, env: env)
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
        let env = environments[ObjectIdentifier(sender)],
        let root = sender.view
      else { return }
      // The element under the press, found the way UIKit routes touches. The
      // recognizer sits on the host view, which is the tree `publishTree`
      // walks, so the hit is always one of the published nodes.
      let hit = root.hitTest(sender.location(in: root), with: nil) ?? root
      WuiInspector.inspect(view: hit, under: root, env: env)
    }
  }
#endif
