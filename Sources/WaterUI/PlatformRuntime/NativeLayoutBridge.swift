import CoreGraphics

/// Shared helper that drives measurements and placement using the Rust layout FFI.
/// Uses the SubView callback protocol - Rust calls back to Swift to measure children.
@MainActor
struct NativeLayoutBridge {
    /// Creates a cached SubView array for repeated Rust layout calls.
    /// The measure closure will be called by Rust during layout.
    func createCachedSubViewArray<V: WuiComponent>(
        children: [V],
        measureChild: @escaping (V, WuiProposalSize) -> WuiViewDimensions
    ) -> CachedSubViewArray {
        let proxies = children.map { child in
            SubViewProxy(
                stretchAxis: child.stretchAxis,
                priority: child.layoutPriority()
            ) { proposal in
                measureChild(child, proposal)
            }
        }
        return CachedSubViewArray(proxies)
    }

    /// Calculate the full measurement packet for a container.
    ///
    /// The child measurement cache persists across calls: a proxy's answer to a
    /// proposal only changes when the child's content changes, which is exactly
    /// what `invalidateIntrinsicContentSize` on the owning container reports
    /// (both Rust-side layout invalidation and a descendant's
    /// `invalidateLayoutHierarchy` reach it). Clearing the cache per session
    /// turned every nested container measure into a full subtree re-measure —
    /// exponential across depth (water-rs/apple-backend#164).
    func containerMeasure(
        layout: WuiLayout,
        parentProposal: WuiProposalSize,
        children: CachedSubViewArray
    ) -> WuiViewDimensions {
        layout.measure(proposal: parentProposal, children: children)
    }

    /// Calculate the container size using Rust layout engine.
    func containerSize(
        layout: WuiLayout,
        parentProposal: WuiProposalSize,
        children: CachedSubViewArray
    ) -> CGSize {
        containerMeasure(layout: layout, parentProposal: parentProposal, children: children).cgSize
    }

    /// Get placement rects for all children.
    /// Rust will call back to measure each child as needed during placement;
    /// those answers reuse the cache `containerMeasure` already populated.
    func placements(
        layout: WuiLayout,
        bounds: CGRect,
        children: CachedSubViewArray
    ) -> [CGRect] {
        layout.place(bounds: bounds, children: children)
    }
}
