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

use alloc::boxed::Box;
use alloc::rc::Rc;
use core::cell::RefCell;
use core::ffi::c_void;

use cocoa_ui::PlatformView;
use waterui_core::layout::ProposalSize;

use crate::seam::{WateruiProposalSize, WateruiSubView};

/// How a mounted child's selected proposal reaches its leaf.
enum Channel {
    /// A Rust leaf's sink — the `setPlacementProposal` a Rust component
    /// answers.
    Sink(Rc<dyn Fn(ProposalSize)>),
    /// A Swift leaf's wire `place` callback, kept with its context so the
    /// call reaches `WuiComponent.setPlacementProposal` on the other side.
    Seam {
        /// The leaf's wire context; valid while the registration lives —
        /// the [`SeamGuard`] removes the entry before the context drops.
        context: *mut c_void,
        /// The wire `place` callback paired with `context`.
        place: unsafe extern "C" fn(*mut c_void, WateruiProposalSize),
    },
}

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
    let channel = CHANNELS.with(|channels| {
        let channels = channels.borrow();
        match channels.get(&view_key) {
            Some(Channel::Sink(sink)) => Some(Channel::Sink(sink.clone())),
            Some(Channel::Seam { context, place }) => Some(Channel::Seam {
                context: *context,
                place: *place,
            }),
            None => None,
        }
    });
    match channel {
        Some(Channel::Sink(sink)) => sink(proposal),
        Some(Channel::Seam { context, place }) => {
            // SAFETY: `context` is alive for as long as the registration —
            // `SeamGuard`'s drop removes the entry before the wire context
            // is released.
            unsafe { place(context, WateruiProposalSize::from_proposal(proposal)) };
        }
        None => {}
    }
}

/// Registers `sink` as the channel `view` answers placement proposals
/// through; the returned guard unregisters on drop.
pub fn register_sink(view: &PlatformView, sink: impl Fn(ProposalSize) + 'static) -> SinkGuard {
    CHANNELS.with(|channels| {
        channels
            .borrow_mut()
            .insert(key(view), Channel::Sink(Rc::new(sink)));
    });
    SinkGuard { view: key(view) }
}

/// Registers a Swift leaf's wire `place` callback as `view`'s channel; the
/// returned guard unregisters on drop — and must drop before `subview`
/// does, since the channel's context is freed with it.
pub fn register_seam(view: &PlatformView, subview: &WateruiSubView) -> SeamGuard {
    CHANNELS.with(|channels| {
        channels.borrow_mut().insert(
            key(view),
            Channel::Seam {
                context: subview.context,
                place: subview.place,
            },
        );
    });
    SeamGuard { view: key(view) }
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

/// The guard [`register_seam`] returns; drops the registration.
#[derive(Debug)]
pub struct SeamGuard {
    view: usize,
}

impl Drop for SeamGuard {
    fn drop(&mut self) {
        CHANNELS.with(|channels| {
            channels.borrow_mut().remove(&self.view);
        });
    }
}

/// The `WateruiSubView` a Rust leaf's `place` callback reads through: the
/// layout face plus the view key the callback looks its sink up by.
pub struct WirePayload {
    /// The leaf's layout face.
    pub(crate) subview: Box<dyn waterui_core::layout::SubView>,
    /// The leaf's view as a [`CHANNELS`] key — the sink lookup.
    pub(crate) view_key: usize,
}
