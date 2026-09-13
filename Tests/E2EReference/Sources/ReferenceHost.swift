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

#if os(iOS)
  import UIKit

  @main
  class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
      _: UIApplication,
      didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
      let window = UIWindow(frame: UIScreen.main.bounds)
      window.rootViewController = UIHostingController(rootView: TwinRoot())
      window.makeKeyAndVisible()
      self.window = window
      return true
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
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
      true
    }
  }
#endif
