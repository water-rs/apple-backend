import CWaterUI
import Foundation

final class WuiRedrawCallbackBox: @unchecked Sendable {
  private let wake: @MainActor @Sendable () -> Void

  init(wake: @escaping @MainActor @Sendable () -> Void) {
    self.wake = wake
  }

  func requestWake() {
    if Thread.isMainThread {
      MainActor.assumeIsolated {
        wake()
      }
    } else {
      DispatchQueue.main.async { [self] in
        wake()
      }
    }
  }
}

let wuiRedrawWakeCallback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { context in
  guard let context else {
    fatalError("GPU redraw callback received a null context")
  }
  Unmanaged<WuiRedrawCallbackBox>
    .fromOpaque(context)
    .takeUnretainedValue()
    .requestWake()
}

let wuiRedrawDropCallback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { context in
  guard let context else {
    fatalError("GPU redraw callback drop received a null context")
  }
  _ = Unmanaged<WuiRedrawCallbackBox>.fromOpaque(context).takeRetainedValue()
}

final class WuiGpuCaptureCompletionBox: @unchecked Sendable {
  private let completion: @MainActor @Sendable () -> Void

  init(completion: @escaping @MainActor @Sendable () -> Void) {
    self.completion = completion
  }

  func enqueueCompletion() {
    DispatchQueue.main.async { [completion] in
      completion()
    }
  }
}

let wuiGpuCaptureCompletionCallback: @convention(c) (UnsafeMutableRawPointer?) -> Void = {
  context in
  guard let context else {
    fatalError("GPU capture completion received a null context")
  }
  Unmanaged<WuiGpuCaptureCompletionBox>
    .fromOpaque(context)
    .takeUnretainedValue()
    .enqueueCompletion()
}

let wuiGpuCaptureCompletionDrop: @convention(c) (UnsafeMutableRawPointer?) -> Void = { context in
  guard let context else {
    fatalError("GPU capture completion drop received a null context")
  }
  _ = Unmanaged<WuiGpuCaptureCompletionBox>.fromOpaque(context).takeRetainedValue()
}

@MainActor
func observeGpuCaptureFence(
  _ fence: OpaquePointer,
  completion: @escaping @MainActor @Sendable () -> Void
) {
  let box = WuiGpuCaptureCompletionBox(completion: completion)
  waterui_gpu_capture_fence_on_complete(
    fence,
    Unmanaged.passRetained(box).toOpaque(),
    wuiGpuCaptureCompletionCallback,
    wuiGpuCaptureCompletionDrop
  )
}
