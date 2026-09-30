//! `waterui-apple` — the `WaterUI` backend for Apple platforms.
//!
//! This crate owns the application's root on macOS and iOS: the executors,
//! the `Environment`, the system locale, the GPU runtime hand-off, the
//! services the rendered tree needs, the theme installs, font registration,
//! and the realization of the app's windows and (on macOS) menu bar — the
//! work `WuiRootContext` performs today in Swift. Views are dispatched in
//! Rust through [`dispatch`]; components this crate does not yet own cross
//! the [`seam`] to the Swift fallback, which renders them through the same
//! package as before.
//!
//! The generated application crate calls `export_app!`, which emits the
//! `waterui_apple_main` entry point. `main.swift` in the Xcode target is a
//! one-line call into it.
//!
//! # Safety
//!
//! The `unsafe` in this crate serves the seam: views, environments and
//! leaves cross the boundary as opaque pointers whose ownership rules the
//! declarations in [`seam`] spell out. Everything on the Rust side of the
//! boundary is ordinary safe Rust, and the platform side goes through
//! `cocoa-ui`, which is safe.

// The `with_env` feature name is fixed by the port contract.
#![allow(clippy::redundant_feature_names)]

extern crate alloc;

pub mod contract;
pub mod dispatch;
pub mod entry;
pub mod seam;

pub(crate) mod components;
pub(crate) mod first_paint;
pub(crate) mod fonts;
#[cfg(feature = "gpu_surface")]
mod gpu_input;
mod gpu_runtime;
mod invalidation;
pub(crate) mod locale;
pub(crate) mod measure_memo;
#[cfg(any(target_os = "macos", target_os = "ios"))]
pub(crate) mod menus;
pub(crate) mod proposal;
mod registry;
pub(crate) mod startup;
pub(crate) mod theme;
#[cfg(target_os = "macos")]
mod toolbar;
pub(crate) mod windows;

/// Generates the `waterui_apple_main` entry point for the application
/// crate that calls it.
///
/// The whole launch — process startup, the environment, the fallback's
/// services, the declared windows and the platform run loop — ends in
/// [`entry::run`], and the Xcode target's `main.swift` is a one-line call
/// into it.
#[macro_export]
macro_rules! export_app {
    ($app:path) => {
        /// The application's entry: the generated `main.swift` calls this
        /// and nothing else.
        ///
        /// `accessory` selects the macOS activation policy
        /// (`NSApplication.ActivationPolicy.accessory`); it is unused on
        /// iOS.
        ///
        /// # Safety
        ///
        /// Call once, on the platform main thread, as the process entry.
        #[unsafe(no_mangle)]
        pub unsafe extern "C" fn waterui_apple_main(accessory: bool) {
            let mut env = ::waterui::configure_environment!(::waterui::Environment::new());
            // SAFETY: this is the process's entry on the main thread, and
            // `env` lives in this frame — `run` never returns, so the
            // borrow outlives every use the seam keeps.
            unsafe {
                ::waterui_apple::entry::run(
                    |mut env| {
                        // The realizations this backend brings — the
                        // `MapKit` hook `waterui_map_gpu::install` yields
                        // to, the packaged CEF runtime — are declared on
                        // the environment before the application installs
                        // its own, exactly as `waterui_init` does on the
                        // embedding path. They run inside `run`'s launch
                        // handler so `spawn_local` users such as the CEF
                        // message pump see the local executor `run`
                        // installs at startup.
                        ::waterui_ffi::__configure_native_realizations(&mut env);
                        $app(env)
                    },
                    &mut env,
                    accessory,
                );
            }
        }
    };
}
