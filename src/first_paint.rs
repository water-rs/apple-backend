//! The `waterui_first_paint_ms` marker CI reads.
//!
//! Measures process start to the first window's first painted frame, once per
//! process, exactly as `WuiLaunchTiming` did: wait until the leaf's
//! first-paint participants report ready, commit a display pass, then log
//! `waterui_first_paint_ms=<millis>` on `os_log` subsystem `dev.waterui`.
//! `os_log` is the one channel `water run` streams back on both platforms —
//! `open -W` leaves a macOS app's stdout unreachable, and a simulator app's
//! stdout is not captured either.

use core::ffi::c_void;
use core::sync::atomic::{AtomicBool, Ordering};

/// The marker source's once-per-process latch.
static REPORTED: AtomicBool = AtomicBool::new(false);

/// Marks first paint for `view` — a leaf's platform view — once the platform
/// reports it ready; later calls are no-ops. The platform performs the
/// display pass itself — the caller's continuation runs on the main thread
/// inside the readiness callback, before the run loop hands the frame to the
/// window.
pub fn mark(view: *mut c_void) {
    if REPORTED.swap(true, Ordering::Relaxed) {
        return;
    }
    // SAFETY: `view` is a live platform view for the duration of the
    // callback; `waterui_swift_when_ready` delivers the callback once, on the
    // main thread, while the view is still alive.
    unsafe {
        crate::seam::waterui_swift_when_ready(view, core::ptr::null_mut(), on_ready);
    }
}

extern "C" fn on_ready(_context: *mut c_void) {
    cocoa_ui::core_animation::flush_transaction();
    match cocoa_ui::process::time_since_start() {
        Ok(elapsed) => {
            cocoa_ui::log::Log::new("dev.waterui", "Startup").notice(&alloc::format!(
                "waterui_first_paint_ms={}",
                elapsed.as_millis()
            ));
        }
        Err(error) => {
            tracing::warn!("could not measure first paint: {error}");
        }
    }
}
