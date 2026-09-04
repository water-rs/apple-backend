import Foundation
import OSLog
import QuartzCore

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

/// Drives per-frame callbacks for a GPU-backed view.
///
/// A view on a display is driven by a `CADisplayLink` locked to that display's
/// refresh rate. A view whose window has no display — the offscreen capture
/// window the preview renderer orders far off every screen, or a window being
/// dragged between displays — has no vsync to lock to, so frames are driven
/// from the main run loop instead. That is a distinct legitimate mode, not a
/// fallback for a failed display link: a screenless window is a normal runtime
/// state, and crashing on it would take down preview capture.
///
/// `start(for:)` re-evaluates the mode on every call, so a caller that already
/// pokes the driver whenever its window state changes automatically upgrades
/// from the run-loop clock to a real display link once the window lands on a
/// display.
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

  private enum Clock {
    case displayLink(CADisplayLink)
    case runLoop

    var isDisplayLink: Bool {
      if case .displayLink = self { return true }
      return false
    }
  }

  private let target: Target
  private var clock: Clock?
  private var runLoopWakeScheduled = false

  init(onFrame: @escaping @MainActor () -> Void) {
    self.target = Target(onFrame: onFrame)
  }

  func start(for view: PlatformView) {
    guard let window = view.window else {
      Logger.graphics.debug("Display link not started: the view has no window")
      stop()
      return
    }

    #if canImport(UIKit)
      let screen: UIScreen? = window.screen
    #elseif canImport(AppKit)
      let screen: NSScreen? = window.screen
    #endif

    guard let screen else {
      guard clock == nil else { return }
      Logger.graphics.debug("Window has no display; driving frames from the main run loop")
      clock = .runLoop
      scheduleRunLoopWake()
      return
    }

    if let clock, clock.isDisplayLink { return }
    // A run-loop clock upgrades to the display link now that there is a display.
    stop()

    #if canImport(UIKit)
      let link = CADisplayLink(target: target, selector: #selector(Target.renderFrame))
    #elseif canImport(AppKit)
      let link = window.displayLink(target: target, selector: #selector(Target.renderFrame))
    #endif
    let maximumFramesPerSecond = Float(screen.maximumFramesPerSecond)
    link.preferredFrameRateRange = CAFrameRateRange(
      minimum: min(60, maximumFramesPerSecond),
      maximum: maximumFramesPerSecond,
      preferred: maximumFramesPerSecond
    )
    link.add(to: .main, forMode: .common)
    clock = .displayLink(link)
    Logger.graphics.debug("Display link started at \(maximumFramesPerSecond, privacy: .public)fps")
  }

  func stop() {
    guard let clock else { return }
    if case .displayLink(let link) = clock {
      link.invalidate()
      Logger.graphics.debug("Display link stopped")
    }
    self.clock = nil
  }

  /// Wakes the run-loop clock once per main-queue turn while it is active.
  ///
  /// Each wake delivers exactly one frame callback; the driver keeps waking
  /// only while its owner keeps it started, so a capture that needs a single
  /// frame costs a single wake.
  private func scheduleRunLoopWake() {
    guard !runLoopWakeScheduled else { return }
    runLoopWakeScheduled = true
    DispatchQueue.main.async { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.runLoopWakeScheduled = false
        guard let clock = self.clock, !clock.isDisplayLink else { return }
        self.scheduleRunLoopWake()
        self.target.renderFrame()
      }
    }
  }

  @MainActor deinit {
    stop()
  }
}
