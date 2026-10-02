//! The placement-proposal channel: how a container's selected
//! [`ProposalSize`] reaches a leaf's `setPlacementProposal`.
//!
//! `SubView` has no placement hook — the wire's `place` callback answers
//! the question for leaves that crossed the seam, but a Rust parent holding
//! a mounted child only sees its `&dyn SubView`. A leaf that consumes
//! placement proposals (a layout container re-proposing its children)
//! registers a sink under its view here; the container delivering a
//! proposal asks [`deliver`], which answers through whichever channel the
//! child's leaf installed — a Rust sink, or the seam's own `place` callback
//! for a leaf that crossed from the fallback.
//!
//! Both directions live here so the registry stays the single place the
//! view-pointer ↔ placement-channel mapping exists.
//!
//! # Safety
//!
//! The `unsafe` calls the seam's `place` callback, which is a live entry
//! for as long as its leaf — the registration a [`SeamGuard`] drops when
//! the leaf's `WateruiSubView` drops — guarantees.

use alloc::rc::Rc;
use core::cell::RefCell;

use cocoa_ui::PlatformView;
use waterui_core::layout::ProposalSize;

type Channel = Rc<dyn Fn(ProposalSize)>;

thread_local! {
    /// The channel a leaf's platform view answers placement proposals
    /// through, keyed by the view's address.
    ///
    /// Views are main-thread objects and every caller is a layout pass, so a
    /// thread-local map needs no synchronization.
    static CHANNELS: RefCell<std::collections::HashMap<usize, Channel>> =
        RefCell::new(std::collections::HashMap::new());
}

/// The map key for `view`: its stable address.
fn key(view: &PlatformView) -> usize {
    core::ptr::from_ref::<PlatformView>(view) as usize
}

/// Delivers the proposal a parent layout selected for `view`.
///
/// Does nothing when the leaf registered no channel — the same answer the
/// Swift baseline's default `setPlacementProposal` gives.
pub fn deliver(view: &PlatformView, proposal: ProposalSize) {
    deliver_key(key(view), proposal);
}

/// [`deliver`] by map key, for callers holding only the address — the
/// seam's wire `place` callback.
pub fn deliver_key(view_key: usize, proposal: ProposalSize) {
    let channel = CHANNELS.with(|channels| channels.borrow().get(&view_key).cloned());
    if let Some(sink) = channel {
        sink(proposal);
    }
}

/// Registers `sink` as the channel `view` answers placement proposals
/// through; the returned guard unregisters on drop.
pub fn register_sink(view: &PlatformView, sink: impl Fn(ProposalSize) + 'static) -> SinkGuard {
    CHANNELS.with(|channels| {
        channels.borrow_mut().insert(key(view), Rc::new(sink));
    });
    SinkGuard { view: key(view) }
}

/// The guard [`register_sink`] returns; drops the registration.
#[derive(Debug)]
pub struct SinkGuard {
    view: usize,
}

impl Drop for SinkGuard {
    fn drop(&mut self) {
        CHANNELS.with(|channels| {
            channels.borrow_mut().remove(&self.view);
        });
    }
}
