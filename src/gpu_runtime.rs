//! The process GPU runtime: created asynchronously on the shared executor,
//! installed into the environment before the fallback's services — the Rust
//! half of what `WuiGpuRuntime.swift` + the `waterui_gpu_runtime_*` FFI did.

use executor_core::{spawn, spawn_local};
use waterui_backend_core::Environment;
use waterui_graphics::gpu::GpuRuntime;

/// Creates the runtime on the shared executor, installs it into `env` on the
/// main thread, then runs `then`. The owner retains `env` until setup and
/// the completion callback finish.
///
/// # Safety
///
/// `env` must be a valid, live `Environment` until `then` finishes and
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
#[cfg(feature = "gpu_surface")]
pub fn runtime(env: &Environment) -> GpuRuntime {
    env.get::<GpuRuntime>()
        .expect("GPU runtime is not installed in the WaterUI environment")
        .clone()
}
