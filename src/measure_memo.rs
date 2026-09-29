//! Persistent measure memoization at the leaf boundary.
//!
//! Core's `with_memoized_children` dedups child measures inside a single
//! layout call, but nothing dedups across calls: a nested stack negotiates
//! each leaf at a handful of distinct proposals per level, and an unmemoized
//! leaf re-runs its whole compute — probing every child — on every consult.
//! Call counts then multiply by the probe fan-out at each level, which is
//! exponential over nested containers (a depth-8 eager stack drives hundreds
//! of millions of leaf measures and never reaches first paint).
//!
//! Every `NativeLeaf` wraps its `SubView` in a [`MemoizingSubView`], so each
//! consult at a repeated proposal hits the leaf's cache instead of
//! re-descending its subtree — containers, delegates, metadata wrappers and
//! seam faces alike. Entries are keyed on the proposal's bits and stamped
//! with the global generation; any measure-relevant mutation anywhere calls
//! [`invalidate`], which bumps the generation and stales every cache at
//! once. The policy is deliberately conservative — a leaf that forgets to
//! invalidate is the failure mode, so every port calls `invalidate` from the
//! same places it would request a relayout, plus content mutations that
//! resize without one (text rebuilds, container resyncs, lazy viewport
//! measurements).

use std::cell::RefCell;
use std::collections::HashMap;
use std::fmt;
use std::sync::atomic::{AtomicU64, Ordering};

use waterui_core::layout::{ProposalSize, StretchAxis, SubView, ViewDimensions};

/// The negotiation epoch: bumped by every measure-affecting mutation.
static GENERATION: AtomicU64 = AtomicU64::new(0);

/// Marks every memoized measure stale tree-wide. Call it wherever a leaf's
/// measure-relevant inputs change — content rebuilds, child resyncs, bound
/// value updates that resize.
pub fn invalidate() {
    GENERATION.fetch_add(1, Ordering::Relaxed);
}

/// `ProposalSize` bits packed into a key — `None` is `0`, so `Some(-0.0)`
/// never aliases it and NaN proposals key consistently.
fn key(proposal: ProposalSize) -> u64 {
    let w = proposal.width.map_or(0_u64, |v| u64::from(v.to_bits()) + 1);
    let h = proposal
        .height
        .map_or(0_u64, |v| u64::from(v.to_bits()) + 1);
    (w << 32) | h
}

/// A leaf's `(proposal -> dimensions)` cache for the current epoch.
///
/// Entries outliving a bound flush lazily: at 128 entries the map clears,
/// which bounds memory and amortizes the re-miss into the next epoch.
struct MeasureMemo {
    inner: RefCell<HashMap<u64, (u64, ViewDimensions)>>,
}

impl MeasureMemo {
    /// Answers `compute()` cached on `proposal` for the current epoch.
    fn measure(
        &self,
        proposal: ProposalSize,
        compute: impl FnOnce() -> ViewDimensions,
    ) -> ViewDimensions {
        let generation = GENERATION.load(Ordering::Relaxed);
        let key = key(proposal);
        if let Some((stamped, dimensions)) = self.inner.borrow().get(&key)
            && *stamped == generation
        {
            return dimensions.clone();
        }
        let dimensions = compute();
        let mut map = self.inner.borrow_mut();
        if map.len() >= 128 {
            map.clear();
        }
        map.insert(key, (generation, dimensions.clone()));
        dimensions
    }
}

/// Wraps any leaf `SubView` in a [`MeasureMemo`]: repeated probes at the same
/// proposal hit the cache instead of re-running the leaf's compute. Wrapping
/// at the `NativeLeaf` boundary memoizes delegates (env/metadata wrappers,
/// `AnyView`, seam faces) that have no memo of their own.
pub struct MemoizingSubView {
    inner: Box<dyn SubView>,
    memo: MeasureMemo,
}

impl MemoizingSubView {
    pub fn new(inner: Box<dyn SubView>) -> Self {
        Self {
            inner,
            memo: MeasureMemo {
                inner: RefCell::new(HashMap::new()),
            },
        }
    }
}

impl fmt::Debug for MemoizingSubView {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("MemoizingSubView").finish_non_exhaustive()
    }
}

impl SubView for MemoizingSubView {
    fn measure(&self, proposal: ProposalSize) -> ViewDimensions {
        self.memo.measure(proposal, || self.inner.measure(proposal))
    }
    fn stretch_axis(&self) -> StretchAxis {
        self.inner.stretch_axis()
    }
    fn priority(&self) -> i32 {
        self.inner.priority()
    }
    fn is_empty(&self) -> bool {
        self.inner.is_empty()
    }
}
