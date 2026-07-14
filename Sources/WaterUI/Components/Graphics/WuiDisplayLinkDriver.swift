import Foundation
import QuartzCore

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

@MainActor
final class WuiDisplayLinkDriver {
  @MainActor
  private final class Target: NSObject {
    let onFrame: @MainActor () -> Void

    init(onFrame: @escaping @MainActor () -> Void) {
      self.onFrame = onFrame
    }

    @objc func renderFrame() {
      onFrame()
    }
  }

  private let target: Target
  private var displayLink: CADisplayLink?

  init(onFrame: @escaping @MainActor () -> Void) {
    self.target = Target(onFrame: onFrame)
  }

  func start(for view: PlatformView) {
    guard displayLink == nil else { return }
    #if canImport(UIKit)
      guard let screen = view.window?.screen else {
        fatalError("A WaterUI display link requires an attached UIKit view")
      }
      let link = CADisplayLink(target: target, selector: #selector(Target.renderFrame))
    #elseif canImport(AppKit)
      guard let window = view.window else {
        fatalError("A WaterUI display link requires an attached AppKit view")
      }
      guard let screen = window.screen else {
        fatalError("A WaterUI display link requires an AppKit window on a display")
      }
      let link = window.displayLink(target: target, selector: #selector(Target.renderFrame))
    #endif
    let maximumFramesPerSecond = Float(screen.maximumFramesPerSecond)
    link.preferredFrameRateRange = CAFrameRateRange(
      minimum: min(60, maximumFramesPerSecond),
      maximum: maximumFramesPerSecond,
      preferred: maximumFramesPerSecond
    )
    link.add(to: .main, forMode: .common)
    displayLink = link
  }

  func stop() {
    displayLink?.invalidate()
    displayLink = nil
  }

  @MainActor deinit {
    stop()
  }
}
