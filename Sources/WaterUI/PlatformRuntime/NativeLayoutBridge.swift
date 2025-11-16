import CoreGraphics

/// Shared helper that drives measurements and placement using the Rust layout FFI.
@MainActor
struct NativeLayoutBridge {
    struct ChildContext {
        var descriptor: PlatformViewDescriptor
        var priority: UInt8

        init(descriptor: PlatformViewDescriptor, priority: UInt8) {
            self.descriptor = descriptor
            self.priority = priority
        }
    }

    struct ChildMeasurement {
        var context: ChildContext
        var proposal: WuiProposalSize
        var measuredSize: CGSize

        init(
            context: ChildContext,
            proposal: WuiProposalSize,
            measuredSize: CGSize
        ) {
            self.context = context
            self.proposal = proposal
            self.measuredSize = measuredSize
        }
    }

    func requestChildProposals(
        layout: WuiLayout,
        parentProposal: WuiProposalSize,
        contexts: [ChildContext]
    ) -> [WuiProposalSize] {
        let metadata = initialMetadata(from: contexts)
        return layout.propose(parent: parentProposal, children: metadata)
    }

    func containerSize(
        layout: WuiLayout,
        parentProposal: WuiProposalSize,
        measurements: [ChildMeasurement]
    ) -> CGSize {
        let metadata = measuredMetadata(from: measurements)
        return layout.size(parent: parentProposal, children: metadata)
    }

    func frames(
        layout: WuiLayout,
        bounds: CGRect,
        parentProposal: WuiProposalSize,
        measurements: [ChildMeasurement]
    ) -> [CGRect] {
        let metadata = measuredMetadata(from: measurements)
        return layout.place(bound: bounds, proposal: parentProposal, children: metadata)
    }

    func metadata(from measurements: [ChildMeasurement]) -> [WuiChildMetadata] {
        measuredMetadata(from: measurements)
    }

    private func initialMetadata(from contexts: [ChildContext]) -> [WuiChildMetadata] {
        contexts.map { context in
            WuiChildMetadata(
                proposal: WuiProposalSize(),
                priority: context.priority,
                stretch: context.descriptor.isSpacer
            )
        }
    }

    private func measuredMetadata(
        from measurements: [ChildMeasurement]
    ) -> [WuiChildMetadata] {
        measurements.map { measurement in
            let descriptor = measurement.context.descriptor
            let proposal = descriptor.isSpacer
                ? WuiProposalSize()
                : WuiProposalSize(size: measurement.measuredSize)

            return WuiChildMetadata(
                proposal: proposal,
                priority: measurement.context.priority,
                stretch: descriptor.isSpacer
            )
        }
    }
}
