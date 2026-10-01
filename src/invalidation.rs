//! `invalidateCapturedRendering`: the superview walk to an enclosing
//! effect view's rendered-content sink.
//!
//! Leaves that change what they drew (a shape's fill, a picture's bitmap)
//! call [`invalidate_rendered_content`]; an enclosing `view_effect` leaf
//! registered its content view through [`register_sink`] and re-renders its
//! capture — `WuiRenderedContentInvalidationSink`.

use alloc::rc::{Rc, Weak};
use std::collections::HashMap;
use std::sync::Mutex;

use cocoa_ui::PlatformView;

/// Mounted content view → the owning effect's invalidation callback.
/// `Weak` entries are only ever upgraded on the main queue — the sinks are
/// main-thread objects crossing through the shared table.
struct SendableWeak(Weak<dyn Fn()>);

// SAFETY: `invalidate` runs the closure through the main queue, so the weak
// target is only touched where it lives.
#[allow(clippy::non_send_fields_in_send_ty)]
unsafe impl Send for SendableWeak {}

static SINKS: Mutex<Option<HashMap<usize, SendableWeak>>> = Mutex::new(None);

/// The map key for a platform view.
fn key(view: &PlatformView) -> usize {
    core::ptr::from_ref(view).cast::<u8>() as usize
}

/// Registers `callback` as the rendered-content invalidation sink for
/// `view` — the identity `WuiRenderedContentInvalidationSink` conformed to.
///
/// The entry is weak: it clears itself when the owning leaf drops.
#[allow(clippy::needless_pass_by_value)]
pub fn register_sink(view: &PlatformView, callback: Rc<dyn Fn()>) {
    SINKS
        .lock()
        .expect("rendered-content invalidation registry")
        .get_or_insert_with(HashMap::new)
        .insert(key(view), SendableWeak(Rc::downgrade(&callback)));
}

/// Removes the sink for `view`, if any — a leaf tearing down before its
/// callback would die on its own.
pub fn unregister_sink(view: &PlatformView) {
    if let Some(sinks) = SINKS
        .lock()
        .expect("rendered-content invalidation registry")
        .as_mut()
    {
        sinks.remove(&key(view));
    }
}

/// Walks `view`'s superview chain to the nearest registered sink and calls
/// it — `PlatformView.invalidateCapturedRendering`.
pub fn invalidate_rendered_content(view: &PlatformView) {
    let mut ancestor = cocoa_ui::view::superview(view);
    while let Some(current) = ancestor {
        let sink = SINKS
            .lock()
            .expect("rendered-content invalidation registry")
            .as_ref()
            .and_then(|sinks| sinks.get(&key(&current)).map(|sink| sink.0.clone()))
            .and_then(|sink| sink.upgrade());
        if let Some(sink) = sink {
            sink();
            return;
        }
        ancestor = cocoa_ui::view::superview(&current);
    }
}
