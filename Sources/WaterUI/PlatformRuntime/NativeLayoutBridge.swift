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
    func containerMeasure(
        layout: WuiLayout,
        parentProposal: WuiProposalSize,
        children: CachedSubViewArray
    ) -> WuiViewDimensions {
        children.resetMeasurements()
        return layout.measure(proposal: parentProposal, children: children)
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
    /// Rust will call back to measure each child as needed during placement.
    func placements(
        layout: WuiLayout,
        bounds: CGRect,
        children: CachedSubViewArray
    ) -> [CGRect] {
        children.resetMeasurements()
        return layout.place(bounds: bounds, children: children)
    }
}
