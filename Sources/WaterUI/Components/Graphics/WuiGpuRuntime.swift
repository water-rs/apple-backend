// Compiled out when the app disables WaterUI's `gpu` feature: the
// `waterui_*` GPU symbols this file binds do not exist in that build.
#if !WATERUI_NO_GPU
@_exported import CWaterUI
import Metal

private final class WuiGpuRuntimeInstallRequest: @unchecked Sendable {
  let continuation: CheckedContinuation<Void, Never>

  init(continuation: CheckedContinuation<Void, Never>) {
    self.continuation = continuation
  }
}

private let wuiGpuRuntimeInstallComplete: @convention(c) (UnsafeMutableRawPointer?) -> Void = {
  context in
  guard let context else {
    fatalError("GpuRuntime install completed without its continuation context")
  }
  let request = Unmanaged<WuiGpuRuntimeInstallRequest>.fromOpaque(context).takeUnretainedValue()
  request.continuation.resume()
}

private let wuiGpuRuntimeInstallContextDrop: @convention(c) (UnsafeMutableRawPointer?) -> Void = {
  context in
  guard let context else {
    fatalError("GpuRuntime install dropped a null continuation context")
  }
  Unmanaged<WuiGpuRuntimeInstallRequest>.fromOpaque(context).release()
}

/// Installs the Rust-side `GpuRuntime` into `env` — the Rust host installs
/// before `waterui_swift_prepare_env`; the Swift launch path calls this.
@MainActor
func installGpuRuntime(env: OpaquePointer) async {
  await withCheckedContinuation { continuation in
    let request = WuiGpuRuntimeInstallRequest(continuation: continuation)
    waterui_apple_install_gpu_runtime(
      UnsafeMutableRawPointer(env),
      Unmanaged.passRetained(request).toOpaque(),
      wuiGpuRuntimeInstallComplete,
      wuiGpuRuntimeInstallContextDrop
    )
  }
}

@MainActor
func wuiMetalDevice(environment: WuiEnvironment) -> MTLDevice {
  guard let pointer = waterui_apple_gpu_metal_device(UnsafeMutableRawPointer(environment.inner)) else {
    fatalError("WaterUI environment has no GPU runtime Metal device")
  }
  let object = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
  guard let device = object as? MTLDevice else {
    fatalError("WaterUI GPU runtime returned a non-MTLDevice object")
  }
  return device
}
#endif  // !WATERUI_NO_GPU
