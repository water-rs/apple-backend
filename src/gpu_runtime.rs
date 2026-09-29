//! The process GPU runtime: created asynchronously on the shared executor,
//! installed into the environment before the fallback's services — the Rust
//! half of what `WuiGpuRuntime.swift` + the `waterui_gpu_runtime_*` FFI did.

use core::ffi::c_void;

use executor_core::{spawn, spawn_local};
use waterui_backend_core::Environment;
use waterui_graphics::shared_context::GpuRuntime;

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
    let gpu = runtime(env).context();
    // SAFETY: this backend is Metal-only, so the runtime's device has
    // `MetalApi` as its HAL type.
    let device = unsafe { gpu.device.as_hal::<wgpu_hal::api::Metal>() }
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
