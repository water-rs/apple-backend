//! Core Animation, the compositor both frameworks draw through.

use objc2_quartz_core::CATransaction;

/// Commits the current Core Animation transaction to the render server now,
/// rather than at the end of this turn of the run loop.
///
/// After this returns, every layer change made so far has been handed to the
/// compositor, which is the point at which a frame can be said to have been
/// submitted.
pub fn flush_transaction() {
    CATransaction::flush();
}
