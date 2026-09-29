//! The registration table: every claim the backend makes, in one place.
//!
//! A component port adds a `components/<name>.rs` module exposing
//! `pub(crate) fn install(&mut Dispatcher)`, a `#[cfg(feature = "<name>")]`
//! line here, and the matching Cargo feature. This file is the shared merge
//! point the coordinator integrates.
//!
//! Entries must be sorted by the group they belong to; the comment names the
//! wave group they arrived with.

use crate::dispatch::Dispatcher;

/// Fills `dispatcher` with every claim the backend owns. Called exactly
/// once, before the first render, inside [`crate::dispatch::dispatcher`].
pub fn install(dispatcher: &mut Dispatcher) {
    // Core — the unit view, always claimed: an unclaimed `Native<()>` crosses
    // the seam into a `body()` panic, which `panic = "abort"` makes fatal.
    crate::components::empty::install(dispatcher);

    // Wave A — trivial leaves.
    #[cfg(feature = "image")]
    crate::components::image::install(dispatcher);
    #[cfg(feature = "slider")]
    crate::components::slider::install(dispatcher);
    #[cfg(feature = "text")]
    crate::components::text::install(dispatcher);
    #[cfg(feature = "button")]
    crate::components::button::install(dispatcher);
    #[cfg(feature = "toggle")]
    crate::components::toggle::install(dispatcher);
    #[cfg(feature = "text_field")]
    crate::components::text_field::install(dispatcher);
}
