#if canImport(UIKit)
import UIKit

/// A native UIKit container that uses the Rust layout engine for child positioning.
/// This is the primary layout container for WaterUI on iOS/iPadOS/tvOS.
@MainActor
final class UIKitLayoutContainer: UIView, WaterUILayoutMeasurable {
    private var layout: WuiLayout
    private var childViews: [UIView] = []
    private let bridge = NativeLayoutBridge()
    
    // Cached measurements for layout pass
    private var cachedMeasurements: [NativeLayoutBridge.ChildMeasurement] = []
    private var cachedParentProposal: WuiProposalSize?

    var descriptor: PlatformViewDescriptor {
        PlatformViewDescriptor(typeId: "", isSpacer: false)
    }

    init(layout: WuiLayout, children: [UIView]) {
        self.layout = layout
        self.childViews = children
        super.init(frame: .zero)
        
        for child in children {
            child.translatesAutoresizingMaskIntoConstraints = true
            addSubview(child)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func layoutPriority() -> UInt8 { 0 }

    func measure(in proposal: WuiProposalSize) -> CGSize {
        let layoutContext = buildLayoutContext()
        
        // Build child contexts
        let childContexts = childViews.map { child -> NativeLayoutBridge.ChildContext in
            if let measurable = child as? WaterUILayoutMeasurable {
                return NativeLayoutBridge.ChildContext(
                    descriptor: measurable.descriptor,
                    priority: measurable.layoutPriority()
                )
            }
            return NativeLayoutBridge.ChildContext(
                descriptor: PlatformViewDescriptor(typeId: "", isSpacer: false),
                priority: 0
            )
        }

        // 1. Propose - get proposals for each child from Rust layout engine
        let childProposals = bridge.requestChildProposals(
            layout: layout,
            parentProposal: proposal,
            contexts: childContexts,
            layoutContext: layoutContext
        )

        // 2. Measure - each child measures with its proposal
        var measurements: [NativeLayoutBridge.ChildMeasurement] = []
        measurements.reserveCapacity(childViews.count)

        for (index, child) in childViews.enumerated() {
            let childProposal = index < childProposals.count ? childProposals[index] : WuiProposalSize()
            let childContext = childContexts[index]
            
            let measuredSize: CGSize
            if let measurable = child as? WaterUILayoutMeasurable {
                measuredSize = measurable.measure(in: childProposal)
            } else {
                // Fallback for non-WaterUI views
                measuredSize = child.sizeThatFits(CGSize(
                    width: childProposal.width.map { CGFloat($0) } ?? .greatestFiniteMagnitude,
                    height: childProposal.height.map { CGFloat($0) } ?? .greatestFiniteMagnitude
                ))
            }

            measurements.append(NativeLayoutBridge.ChildMeasurement(
                context: childContext,
                proposal: WuiProposalSize(size: measuredSize),
                measuredSize: measuredSize
            ))
        }

        // Cache for layout pass
        cachedMeasurements = measurements
        cachedParentProposal = proposal

        // 3. Size - get container size from Rust layout engine
        return bridge.containerSize(
            layout: layout,
            parentProposal: proposal,
            measurements: measurements,
            layoutContext: layoutContext
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !childViews.isEmpty else { return }

        let layoutContext = buildLayoutContext()
        let parentProposal = cachedParentProposal ?? WuiProposalSize(size: bounds.size)

        // If we don't have cached measurements, re-measure
        if cachedMeasurements.isEmpty {
            _ = measure(in: parentProposal)
        }

        guard !cachedMeasurements.isEmpty else { return }

        // Get placements from Rust layout engine
        let placements = bridge.placements(
            layout: layout,
            bounds: bounds,
            parentProposal: parentProposal,
            measurements: cachedMeasurements,
            layoutContext: layoutContext
        )

        // Apply frames to children
        for (index, placement) in placements.enumerated() {
            guard index < childViews.count else { break }
            let rect = placement.cgRect
            guard rect.isValidForLayout else {
                print("Warning: UIKitLayoutContainer received invalid rect for child \(index): \(rect)")
                continue
            }
            childViews[index].frame = rect
            
            // If child is also a layout container, pass down the child context
            if let childContainer = childViews[index] as? UIKitLayoutContainer {
                childContainer.updateLayoutContext(placement.context)
            }
        }
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let proposal = WuiProposalSize(size: size)
        return measure(in: proposal)
    }

    override var intrinsicContentSize: CGSize {
        measure(in: WuiProposalSize())
    }

    // MARK: - Child Management

    func setChildren(_ newChildren: [UIView]) {
        // Remove old children
        for child in childViews {
            child.removeFromSuperview()
        }
        
        // Add new children
        childViews = newChildren
        for child in newChildren {
            child.translatesAutoresizingMaskIntoConstraints = true
            addSubview(child)
        }
        
        // Clear cache and request layout
        cachedMeasurements = []
        cachedParentProposal = nil
        setNeedsLayout()
    }

    // MARK: - Safe Area

    private var inheritedLayoutContext: WuiLayoutContext?

    func updateLayoutContext(_ context: WuiLayoutContext) {
        inheritedLayoutContext = context
        setNeedsLayout()
    }

    private func buildLayoutContext() -> WuiLayoutContext {
        // If we have an inherited context from parent, use it
        if let inherited = inheritedLayoutContext {
            return inherited
        }
        
        // Otherwise, build from our own safe area insets
        let layoutDirection = effectiveUserInterfaceLayoutDirection
        return WuiLayoutContext(from: safeAreaInsets, layoutDirection: layoutDirection)
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        // Re-layout when safe area changes
        cachedMeasurements = []
        setNeedsLayout()
    }
}
#endif

