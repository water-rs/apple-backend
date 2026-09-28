//! The registration table: every claim the backend makes, in one place.
//!
//! A component port adds a `components/<name>.rs` module exposing
//! `pub(crate) fn install(&mut Dispatcher)` and one line here. This file is
//! the shared merge point the coordinator integrates.
//!
//! Entries must be sorted by the group they belong to; the comment names the
//! wave group they arrived with.

use crate::dispatch::Dispatcher;

/// Fills `dispatcher` with every claim the backend owns. Called exactly
/// once, before the first render, inside [`crate::dispatch::dispatcher`].
pub const fn install(_dispatcher: &mut Dispatcher) {
    // Stage 0: Rust owns the root; every component still renders through the
    // Swift fallback. Ports land here one line at a time.
}
