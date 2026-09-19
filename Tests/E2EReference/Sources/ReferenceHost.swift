// Entry point for the SwiftUI reference host.
//
// This deliberately mirrors the app scaffold the `water` CLI generates for
// playground projects (see cli/src/templates/apple/AppName/AppNameApp.swift.tpl
// in the waterui repository): a raw AppDelegate that builds the window by hand
// so window geometry, title and content-hosting behaviour are identical on both
// sides. The only difference is that the content view is an NSHostingView /
// UIHostingController holding the SwiftUI twin instead of a WaterUIView.
//
// Launch arguments:
//   -E2EExample <name>   which twin to render (must exist in twins.txt)
//   -E2ETitle <title>    window title; passed the example's Water.toml `name`

import SwiftUI
import os

/// The twin's first-paint marker, on the same `dev.waterui` subsystem the
/// example under test reports through.
///
/// The shard used to wait a fixed two seconds after launching this host and
/// then capture. A SwiftUI cold launch in the simulator regularly needs
/// longer, and a capture taken before the first frame is a blank screen —
/// which agrees with the next blank frame, so the settle loop accepts it
/// immediately and the run reports a parity regression against a correct
/// WaterUI render. The host therefore says when it has actually drawn.
private let wuiReferenceLog = Logger(subsystem: "dev.waterui", category: "Startup")
private let wuiReferenceLaunchInstant = Date()

/// Emits the marker once the initial render has been committed.
@MainActor
func wuiSignalReferenceFirstPaint() {
  DispatchQueue.main.async {
    CATransaction.begin()
    CATransaction.setCompletionBlock {
      let elapsed = Int(Date().timeIntervalSince(wuiReferenceLaunchInstant) * 1000)
      // `notice` rather than `debug`: every `log stream` configuration the
      // shard uses captures notice, while debug needs an explicit level.
      wuiReferenceLog.notice("waterui_reference_first_paint_ms=\(elapsed, privacy: .public)")
    }
    CATransaction.commit()
  }
}

#if os(iOS)
  import UIKit

  @main
  class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
      _: UIApplication,
      didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
      true
    }
  }

  // The window belongs to the scene, as in the scaffold: UIKit requires the
  // scene life cycle from the iOS 27 SDK on, and the Info.plist the build
  // script writes names this class by its Objective-C name.
  @objc(SceneDelegate)
  class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
      _ scene: UIScene,
      willConnectTo _: UISceneSession,
      options _: UIScene.ConnectionOptions
    ) {
      guard let windowScene = scene as? UIWindowScene else {
        fatalError("The application scene is not a window scene: \(scene)")
      }
      let window = UIWindow(windowScene: windowScene)
      window.rootViewController = UIHostingController(rootView: TwinRoot())
      window.makeKeyAndVisible()
      self.window = window
      wuiSignalReferenceFirstPaint()
    }
  }
#elseif os(macOS)
  import AppKit

  @main
  class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?

    static func main() {
      let app = NSApplication.shared
      let delegate = AppDelegate()
      app.delegate = delegate
      app.run()
    }

    func applicationDidFinishLaunching(_: Notification) {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered,
        defer: false
      )
      if let title = UserDefaults.standard.string(forKey: "E2ETitle") {
        window.title = title
      }
      let hostingView = NSHostingView(rootView: TwinRoot())
      // Do not let the SwiftUI content's ideal size drive the window size —
      // the waterui scaffold pins the content rect at 800×600 unconditionally.
      hostingView.sizingOptions = []
      window.contentView = hostingView
      window.center()
      window.makeKeyAndOrderFront(nil)
      self.window = window
      wuiSignalReferenceFirstPaint()

      // Mirror the chrome flags the WaterUI backend applies once a window has
      // a toolbar (WuiWindowToolbar): unified style + full-size content, which
      // is what lets a NavigationSplitView sidebar run the window's full
      // height with the traffic lights inside it — the presentation Apple's
      // own apps use. SwiftUI installs window.toolbar on first layout, so the
      // check runs after a turn of the main loop.
      DispatchQueue.main.async {
        if window.toolbar != nil {
          window.toolbarStyle = .unified
          window.styleMask.insert(.fullSizeContentView)
        }
      }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
      true
    }
  }
#endif
