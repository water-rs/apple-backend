import CWaterUI
import Metal

private struct WuiOwnedGpuRuntime: @unchecked Sendable {
  let pointer: OpaquePointer
}

private final class WuiGpuRuntimeCreateRequest: @unchecked Sendable {
  let continuation: CheckedContinuation<WuiOwnedGpuRuntime, Never>

  init(continuation: CheckedContinuation<WuiOwnedGpuRuntime, Never>) {
    self.continuation = continuation
  }
}

private let wuiGpuRuntimeCreateComplete:
  @convention(c) (UnsafeMutableRawPointer?, OpaquePointer?) -> Void = { context, runtime in
    guard let context else {
      fatalError("GpuRuntime creation completed without its continuation context")
    }
    guard let runtime else {
      fatalError("GpuRuntime creation completed without a runtime")
    }
    let request = Unmanaged<WuiGpuRuntimeCreateRequest>.fromOpaque(context).takeUnretainedValue()
    request.continuation.resume(returning: WuiOwnedGpuRuntime(pointer: runtime))
  }

private let wuiGpuRuntimeCreateContextDrop: @convention(c) (UnsafeMutableRawPointer?) -> Void = {
  context in
  guard let context else {
    fatalError("GpuRuntime creation dropped a null continuation context")
  }
  Unmanaged<WuiGpuRuntimeCreateRequest>.fromOpaque(context).release()
}

@MainActor
func createWuiGpuRuntime() async -> OpaquePointer {
  let runtime: WuiOwnedGpuRuntime = await withCheckedContinuation { continuation in
    let request = WuiGpuRuntimeCreateRequest(continuation: continuation)
    waterui_gpu_runtime_create(
      Unmanaged.passRetained(request).toOpaque(),
      wuiGpuRuntimeCreateComplete,
      wuiGpuRuntimeCreateContextDrop
    )
  }
  return runtime.pointer
}

@MainActor
func wuiMetalDevice(environment: WuiEnvironment) -> MTLDevice {
  guard let pointer = waterui_gpu_runtime_metal_device(environment.inner) else {
    fatalError("WaterUI environment has no GPU runtime Metal device")
  }
  let object = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
  guard let device = object as? MTLDevice else {
    fatalError("WaterUI GPU runtime returned a non-MTLDevice object")
  }
  return device
}
