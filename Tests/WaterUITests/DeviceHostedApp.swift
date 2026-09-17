// DeviceHostedApp.swift
// Hosts a real WaterUI application in a UIKit window for device-backed tests.
//
// The package resolves `waterui_*` symbols by dynamic lookup, so the test
// bundle can drive a real application only when an example's static archive
// is linked into it. `.github/scripts/run-ios-device-tests.sh` builds an
// example for the simulator and runs `xcodebuild test` with the archive in
// `OTHER_LDFLAGS`; without it the device-backed tests skip and the rest of
// the suite still runs.

#if canImport(UIKit)
  import UIKit
  import XCTest

  @testable import WaterUI

  /// The single hosted application the device-backed tests share.
  ///
  /// `waterui_init` installs process-wide state, so a suite gets one context.
  @MainActor
  enum DeviceHostedApp {
    private static var context: WuiRootContext?
    private static var window: UIWindow?

    /// Whether a WaterUI application archive is linked into this bundle.
    static var isAvailable: Bool {
      dlsym(dlopen(nil, RTLD_LAZY), "waterui_app") != nil
    }

    /// Hosts the app's main-window content in a compact-width window and
    /// returns the context once layout has run.
    @discardableResult
    static func load() async throws -> WuiRootContext {
      if let context { return context }
      guard isAvailable else {
        throw XCTSkip(
          "no WaterUI app archive is linked into the test bundle — run "
            + ".github/scripts/run-ios-device-tests.sh <example>")
      }
      let context = await WuiRootContext()
      // The window must belong to the foreground scene: view capture (tab and
      // navigation icons go through the view renderer) requires a scene that
      // contains a key window, and a scene-less window never lands in one.
      let scene = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .first { $0.activationState == .foregroundActive }
      let frame = CGRect(x: 0, y: 0, width: 393, height: 852)
      let window = scene.map(UIWindow.init(windowScene:)) ?? UIWindow(frame: frame)
      let controller = UIViewController()
      window.rootViewController = controller
      let rootView = context.rootView
      rootView.frame = window.bounds
      controller.view.addSubview(rootView)
      window.makeKeyAndVisible()
      self.context = context
      self.window = window
      return context
    }

    /// Drives the run loop so layout, display, and cell realization finish.
    static func pump(_ seconds: TimeInterval = 0.5) {
      RunLoop.main.run(until: Date(timeIntervalSinceNow: seconds))
    }

    /// The first view in `root`'s subtree satisfying `predicate`, depth-first.
    static func findView(in root: UIView, where predicate: (UIView) -> Bool) -> UIView? {
      if predicate(root) { return root }
      for subview in root.subviews {
        if let found = findView(in: subview, where: predicate) { return found }
      }
      return nil
    }

    /// The first view controller of `type` in the hosted window's controller
    /// hierarchy, depth-first.
    static func findViewController<Controller: UIViewController>(
      ofType type: Controller.Type
    ) -> Controller? {
      func walk(_ controller: UIViewController) -> Controller? {
        if let match = controller as? Controller { return match }
        for child in controller.children {
          if let found = walk(child) { return found }
        }
        return nil
      }
      guard let window else { return nil }
      return window.rootViewController.flatMap(walk)
    }
  }
#endif
