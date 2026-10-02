//! First presentation readiness for an owning application environment.

use cocoa_ui::PlatformView;
use std::{cell::Cell, rc::Rc};
use waterui_backend_core::Environment;

#[derive(Clone, Debug, Default)]
pub(crate) struct FirstPaint(Rc<Cell<bool>>);

pub(crate) fn mark(view: &PlatformView, env: &Environment) {
    let state = env
        .get::<FirstPaint>()
        .expect("first-paint state is installed");
    if state.0.replace(true) {
        return;
    }
    let view = cocoa_ui::view::retain_base(view);
    executor_core::spawn_local(async move {
        cocoa_ui::view::layout_immediately(&view);
        #[cfg(feature = "gpu_surface")]
        crate::components::gpu_surface::wait_for_first_frames(&view).await;
        cocoa_ui::view::display_immediately(&view);
        cocoa_ui::core_animation::flush_transaction();
        match cocoa_ui::process::time_since_start() {
            Ok(elapsed) => cocoa_ui::log::Log::new("dev.waterui", "Startup")
                .notice(&format!("waterui_first_paint_ms={}", elapsed.as_millis())),
            Err(error) => tracing::warn!("could not measure first paint: {error}"),
        }
    })
    .detach();
}
