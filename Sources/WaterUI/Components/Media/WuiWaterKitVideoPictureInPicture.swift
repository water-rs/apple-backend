import Foundation
import Metal

private typealias WaterKitVideoRenderFrameFn =
  @convention(c) (
    UnsafeMutableRawPointer?,
    UnsafeMutableRawPointer?,
    UInt32,
    UInt32
  ) -> Bool

private typealias WaterKitVideoSetExternalRenderingFn =
  @convention(c) (
    UnsafeMutableRawPointer?,
    Bool
  ) -> Void

@_silgen_name("waterkit_video_apple_register_gpu_surface_host")
private func waterkitVideoAppleRegisterGpuSurfaceHost(
  _: UInt64,
  _: UnsafeMutableRawPointer?,
  _: WaterKitVideoRenderFrameFn,
  _: WaterKitVideoSetExternalRenderingFn
)

@_silgen_name("waterkit_video_apple_unregister_gpu_surface_host")
private func waterkitVideoAppleUnregisterGpuSurfaceHost(_: UInt64)

private func wuiWaterKitVideoPictureInPictureRenderFrame(
  userData: UnsafeMutableRawPointer?,
  texturePtr: UnsafeMutableRawPointer?,
  width: UInt32,
  height: UInt32
) -> Bool {
  guard let userData, let texturePtr else {
    fatalError("waterkit-video Apple PiP callbacks require non-null user data and texture")
  }
  precondition(Thread.isMainThread, "waterkit-video PiP rendering must run on the UI thread")
  let userDataAddress = UInt(bitPattern: userData)
  let textureAddress = UInt(bitPattern: texturePtr)
  return MainActor.assumeIsolated {
    let userData = UnsafeMutableRawPointer(bitPattern: userDataAddress)!
    let texturePtr = UnsafeMutableRawPointer(bitPattern: textureAddress)!
    let bridge = Unmanaged<WuiWaterKitVideoPictureInPictureHostBridge>
      .fromOpaque(userData)
      .takeUnretainedValue()
    return bridge.renderFrame(texturePtr: texturePtr, width: width, height: height)
  }
}

private func wuiWaterKitVideoPictureInPictureSetExternalRendering(
  userData: UnsafeMutableRawPointer?,
  enabled: Bool
) {
  guard let userData else {
    fatalError("waterkit-video Apple PiP setExternalRendering callback requires user data")
  }
  precondition(Thread.isMainThread, "waterkit-video PiP state must run on the UI thread")
  let userDataAddress = UInt(bitPattern: userData)
  MainActor.assumeIsolated {
    let userData = UnsafeMutableRawPointer(bitPattern: userDataAddress)!
    let bridge = Unmanaged<WuiWaterKitVideoPictureInPictureHostBridge>
      .fromOpaque(userData)
      .takeUnretainedValue()
    bridge.setExternalRendering(enabled)
  }
}

@MainActor
final class WuiWaterKitVideoPictureInPictureHostBridge {
  private let hostId: UInt64
  private weak var surface: WuiGpuSurface?
  private var externalRenderingActive = false
  private var isRegistered = true

  init(hostId: UInt64, surface: WuiGpuSurface) {
    self.hostId = hostId
    self.surface = surface

    waterkitVideoAppleRegisterGpuSurfaceHost(
      hostId,
      Unmanaged.passUnretained(self).toOpaque(),
      wuiWaterKitVideoPictureInPictureRenderFrame,
      wuiWaterKitVideoPictureInPictureSetExternalRendering
    )
  }

  func renderFrame(
    texturePtr: UnsafeMutableRawPointer,
    width: UInt32,
    height: UInt32
  ) -> Bool {
    guard let surface else { return false }
    let texture = Unmanaged<MTLTexture>.fromOpaque(texturePtr).takeUnretainedValue()
    guard surface.prepareExternalRender(texture: texture) else { return false }
    surface.renderPreparedExternalTexture(
      texture: texture,
      width: width,
      height: height,
      completion: {}
    )
    return true
  }

  func setExternalRendering(_ enabled: Bool) {
    precondition(isRegistered, "Picture-in-picture rendering host is not registered")
    precondition(
      externalRenderingActive != enabled,
      "Picture-in-picture external rendering state did not change"
    )
    guard let surface else {
      fatalError("Picture-in-picture rendering host lost its GpuSurface")
    }
    if enabled {
      surface.beginExternalRendering()
    } else {
      surface.endExternalRendering()
    }
    externalRenderingActive = enabled
  }

  func shutdown() {
    precondition(isRegistered, "Picture-in-picture rendering host may only be shut down once")
    waterkitVideoAppleUnregisterGpuSurfaceHost(hostId)
    isRegistered = false
    if externalRenderingActive {
      guard let surface else {
        fatalError("Picture-in-picture rendering host lost its GpuSurface")
      }
      surface.endExternalRendering()
      externalRenderingActive = false
    }
    surface = nil
  }

  @MainActor deinit {
    precondition(!isRegistered, "Picture-in-picture rendering host was not shut down")
  }
}
