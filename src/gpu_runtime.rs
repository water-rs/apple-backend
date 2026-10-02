//! The process GPU runtime: created asynchronously on the shared executor,
//! installed into the environment before the fallback's services — the Rust
//! half of what `WuiGpuRuntime.swift` + the `waterui_gpu_runtime_*` FFI did.

use core::ffi::c_void;

use cocoa_ui::Retained;
use executor_core::{spawn, spawn_local};
use objc2_metal::{MTLTexture as _, MTLTextureType};
use waterui_backend_core::Environment;
use waterui_graphics::gpu::{GpuRuntime, SharedGpuContext};
use waterui_graphics::wgpu;
use wgpu_hal::{Api, api::Metal as MetalApi};

type MetalTexture = objc2::runtime::ProtocolObject<dyn objc2_metal::MTLTexture>;

/// The `MTLPixelFormat` a wgpu texture format presents as — the formats the
/// backend's own import/export surfaces use.
///
/// # Panics
///
/// When `format` has no backend mapping.
pub fn metal_pixel_format(format: wgpu::TextureFormat) -> objc2_metal::MTLPixelFormat {
    match format {
        wgpu::TextureFormat::Bgra8Unorm => objc2_metal::MTLPixelFormat::BGRA8Unorm,
        wgpu::TextureFormat::Bgra8UnormSrgb => objc2_metal::MTLPixelFormat::BGRA8Unorm_sRGB,
        wgpu::TextureFormat::Rgba16Float => objc2_metal::MTLPixelFormat::RGBA16Float,
        other => panic!("Metal texture import: unsupported wgpu format {other:?}"),
    }
}

/// Imports a `MTLTexture` into the runtime's device — the wgpu-30 Metal
/// import path `cocoa_ui::metal::import_texture` predates.
///
/// # Safety
///
/// `texture` must be a live `MTLTexture` whose `format`, `width` and
/// `height` match the arguments, and the caller must keep it alive as long
/// as wgpu may still reference it.
pub unsafe fn import_texture(
    context: &SharedGpuContext,
    texture: Retained<MetalTexture>,
    format: wgpu::TextureFormat,
    width: u32,
    height: u32,
    usage: wgpu::TextureUsages,
    label: &'static str,
) -> wgpu::Texture {
    let metal_format = metal_pixel_format(format);
    assert_eq!(
        texture.pixelFormat(),
        metal_format,
        "Metal texture import: format describes a different texture"
    );
    // SAFETY: `texture` is the retained texture passed in, and the format,
    // type and extent describe that same resource.
    let hal_texture = unsafe {
        <MetalApi as Api>::Device::texture_from_raw(
            texture,
            format,
            MTLTextureType::Type2D,
            1,
            1,
            wgpu_hal::CopyExtent {
                width,
                height,
                depth: 1,
            },
            None,
        )
    };
    let desc = wgpu::TextureDescriptor {
        label: Some(label),
        size: wgpu::Extent3d {
            width,
            height,
            depth_or_array_layers: 1,
        },
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format,
        usage,
        view_formats: &[],
    };
    // SAFETY: the HAL texture was created on the runtime's device — the
    // device `context` wraps.
    unsafe {
        context.device().create_texture_from_hal::<MetalApi>(
            hal_texture,
            &desc,
            wgpu::wgt::TextureUses::COLOR_TARGET,
        )
    }
}

/// Creates the runtime on the shared executor, installs it into `env` on the
/// main thread, then runs `then`. Called once per launch before the seam's
/// `waterui_swift_prepare_env`; `env` is lent for the process, so it is taken
/// as a raw pointer.
///
/// # Safety
///
/// `env` must be a valid, live `Environment` for the rest of the process and
/// `then` runs on the main thread.
pub unsafe fn prepare(env: *mut Environment, then: impl FnOnce() + 'static) {
    let (sender, receiver) = async_channel::bounded(1);
    spawn(async move {
        let runtime = GpuRuntime::new().await;
        let _ = sender.send(runtime).await;
    })
    .detach();
    spawn_local(async move {
        let runtime = receiver
            .recv()
            .await
            .expect("GPU runtime creation task ended without producing a runtime")
            .unwrap_or_else(|error| panic!("GPU runtime creation failed: {error}"));
        // SAFETY: `env` is lent for the process and this task is pinned to the
        // main executor — the same thread the launch handler runs on.
        let env = unsafe { &mut *env };
        env.insert(runtime);
        then();
    })
    .detach();
}

/// The environment's GPU runtime.
///
/// # Panics
///
/// When no runtime was installed — [`prepare`] runs before any surface or
/// effect can render, so a missing runtime is a launch error.
pub fn runtime(env: &Environment) -> GpuRuntime {
    env.get::<GpuRuntime>()
        .expect("GPU runtime is not installed in the WaterUI environment")
        .clone()
}

/// The `MTLDevice` the environment's GPU runtime owns, as a borrowed pointer
/// valid while the runtime lives — the replacement for
/// `waterui_gpu_runtime_metal_device`.
///
/// # Safety
///
/// `env` must be a valid `Environment` pointer containing an installed
/// [`GpuRuntime`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn waterui_apple_gpu_metal_device(env: *const c_void) -> *mut c_void {
    // SAFETY: the caller contract makes `env` a valid, live environment.
    let env = unsafe { &*env.cast::<Environment>() };
    let context = runtime(env).context();
    // SAFETY: this backend is Metal-only, so the runtime's device has
    // `MetalApi` as its HAL type.
    let device = unsafe { context.device().as_hal::<MetalApi>() }
        .expect("WaterUI GPU runtime did not create a Metal device");
    cocoa_ui::Retained::as_ptr(device.raw_device())
        .cast_mut()
        .cast()
}

/// Installs a GPU runtime into `env` asynchronously, then calls `complete`
/// with `context` on the main thread — the seam-visible replacement for
/// `waterui_gpu_runtime_create` + `waterui_env_install_gpu_runtime`, for the
/// surviving Swift launch path.
///
/// `drop_context` releases `context` after `complete` runs.
///
/// # Safety
///
/// `env` must be valid for the process; `context`, `complete` and
/// `drop_context` must stay valid until `complete` fires.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn waterui_apple_install_gpu_runtime(
    env: *mut c_void,
    context: *mut c_void,
    complete: unsafe extern "C" fn(*mut c_void),
    drop_context: unsafe extern "C" fn(*mut c_void),
) {
    // SAFETY: `env` is lent for the process; the callback pair follows the
    // seam's one-shot context contract.
    unsafe {
        prepare(env.cast::<Environment>(), move || {
            complete(context);
            drop_context(context);
        });
    }
}
