import CoreGraphics

/// Shared helper that drives measurements and placement using the Rust layout FFI.
/// Uses the SubView callback protocol - Rust calls back to Swift to measure children.
@MainActor
struct NativeLayoutBridge {
    /// Creates SubViewProxy instances for each child view.
    /// The measure closure will be called by Rust during layout.
    func createSubViewProxies<V: WuiComponent>(
        children: [V],
        measureChild: @escaping (V, WuiProposalSize) -> CGSize
    ) -> [SubViewProxy] {
        children.map { child in
            SubViewProxy(
                stretchAxis: child.stretchAxis,
                priority: child.layoutPriority()
            ) { proposal in
                measureChild(child, proposal)
            }
        }
    }

    /// Calculate the container size using Rust layout engine.
    /// Rust will call back to measure each child as needed.
    func containerSize(
        layout: WuiLayout,
        parentProposal: WuiProposalSize,
        children: [SubViewProxy]
    ) -> CGSize {
        layout.sizeThatFits(proposal: parentProposal, children: children)
    }

    /// Get placement rects for all children.
    /// Rust will call back to measure each child as needed during placement.
    func placements(
        layout: WuiLayout,
        bounds: CGRect,
        children: [SubViewProxy]
    ) -> [CGRect] {
        layout.place(bounds: bounds, children: children)
    }
}
