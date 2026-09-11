import Foundation
import OSLog
#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

extension PlatformView {
  /// Whether wgpu would skip a frame presented from this view as occluded.
  ///
  /// Mirrors wgpu-hal's Metal `acquire_texture` workaround for
  /// gfx-rs/wgpu#8309: on macOS a window whose `occlusionState` lacks `.visible`
  /// yields no drawable, and the frame is reported as still pending. A frame
  /// clock that re-arms on "pending" therefore spins at display-link rate for as
  /// long as the window stays covered, so the pending frame has to wait for the
  /// occlusion state to change instead. A view with no window is not occluded:
  /// it cannot present at all, which is its caller's check.
  ///
  /// A window on no display is not occluded either, and the distinction is
  /// load-bearing rather than pedantic. `occlusionState` reports `.visible`
  /// only for a window a user could see, so the preview renderer's offscreen
  /// capture window never carries it — and a frame clock that waits for the
  /// occlusion state to change waits for a notification that window will never
  /// send, because nothing is ever going to uncover it. That stranded every
  /// `AppliedFilter` in `water preview` on macOS: the support app went idle
  /// without answering and the render timed out. Being covered is a state a
  /// window leaves; being off every display is one it was born in.
  var isPresentationOccluded: Bool {
    #if canImport(AppKit)
      guard let window, window.screen != nil else { return false }
      return !window.occlusionState.contains(.visible)
    #else
      return false
    #endif
  }
}

#if canImport(AppKit)
  /// Re-evaluates a view's frame clock when its window's occlusion changes.
  ///
  /// Owned by the presenting view and pointed at its current window from
  /// `viewDidMoveToWindow`; the observation follows the window and ends with
  /// the observer.
  @MainActor
  final class WuiWindowOcclusionObserver {
    private let onChange: @MainActor () -> Void
    private weak var observedWindow: NSWindow?
    private var token: NSObjectProtocol?

    init(onChange: @escaping @MainActor () -> Void) {
      self.onChange = onChange
    }

    func observe(window: NSWindow?) {
      if observedWindow === window { return }
      removeToken()
      observedWindow = window
      guard let window else { return }
      let onChange = onChange
      token = NotificationCenter.default.addObserver(
        forName: NSWindow.didChangeOcclusionStateNotification,
        object: window,
        queue: .main
      ) { [weak window] _ in
        MainActor.assumeIsolated {
          let visible = window?.occlusionState.contains(.visible) ?? false
          Logger.graphics.debug("Window occlusion changed: visible=\(visible)")
          onChange()
        }
      }
    }

    private func removeToken() {
      if let token {
        NotificationCenter.default.removeObserver(token)
      }
      token = nil
    }

    @MainActor deinit {
      removeToken()
    }
  }
#endif
