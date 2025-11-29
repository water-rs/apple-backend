#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

/// A native AppKit container that uses the Rust layout engine for child positioning.
/// This is the primary layout container for WaterUI on macOS.
@MainActor
final class AppKitLayoutContainer: NSView, WaterUILayoutMeasurable {
    private var rustLayout: WuiLayout
    private var childViews: [NSView] = []
    private let bridge = NativeLayoutBridge()
    
    // Cached measurements for layout pass
    private var cachedMeasurements: [NativeLayoutBridge.ChildMeasurement] = []
    private var cachedParentProposal: WuiProposalSize?

    var descriptor: PlatformViewDescriptor {
        PlatformViewDescriptor(typeId: "", isSpacer: false)
    }

    init(layout: WuiLayout, children: [NSView]) {
        self.rustLayout = layout
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
            layout: rustLayout,
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
                // Fallback for non-WaterUI views - use fittingSize
                let targetSize = NSSize(
                    width: childProposal.width.map { CGFloat($0) } ?? CGFloat.greatestFiniteMagnitude,
                    height: childProposal.height.map { CGFloat($0) } ?? CGFloat.greatestFiniteMagnitude
                )
                measuredSize = child.fittingSize
                _ = targetSize // suppress warning, fittingSize ignores proposals
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
            layout: rustLayout,
            parentProposal: proposal,
            measurements: measurements,
            layoutContext: layoutContext
        )
    }

    override func layout() {
        super.layout()
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
            layout: rustLayout,
            bounds: bounds,
            parentProposal: parentProposal,
            measurements: cachedMeasurements,
            layoutContext: layoutContext
        )

        // Apply frames to children
        // Note: AppKit uses flipped coordinates (origin at top-left) when isFlipped = true
        for (index, placement) in placements.enumerated() {
            guard index < childViews.count else { break }
            var rect = placement.cgRect
            guard rect.isValidForLayout else {
                print("Warning: AppKitLayoutContainer received invalid rect for child \(index): \(rect)")
                continue
            }
            
            // Convert to AppKit coordinate system if not flipped
            if !isFlipped {
                rect.origin.y = bounds.height - rect.origin.y - rect.height
            }
            
            childViews[index].frame = rect
            
            // If child is also a layout container, pass down the child context
            if let childContainer = childViews[index] as? AppKitLayoutContainer {
                childContainer.updateLayoutContext(placement.context)
            }
        }
    }

    override var fittingSize: NSSize {
        measure(in: WuiProposalSize())
    }

    override var intrinsicContentSize: NSSize {
        measure(in: WuiProposalSize())
    }

    // Use flipped coordinates (origin at top-left) to match UIKit behavior
    override var isFlipped: Bool { true }

    // MARK: - Child Management

    func setChildren(_ newChildren: [NSView]) {
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
        needsLayout = true
    }

    // MARK: - Safe Area

    private var inheritedLayoutContext: WuiLayoutContext?

    func updateLayoutContext(_ context: WuiLayoutContext) {
        inheritedLayoutContext = context
        needsLayout = true
    }

    private func buildLayoutContext() -> WuiLayoutContext {
        // If we have an inherited context from parent, use it
        if let inherited = inheritedLayoutContext {
            return inherited
        }
        
        // macOS doesn't have safe area insets like iOS
        // but we can get them from the window's safe area
        if let window = window {
            let contentRect = window.contentLayoutRect
            let frameRect = window.contentView?.bounds ?? .zero
            
            let insets = NSEdgeInsets(
                top: frameRect.maxY - contentRect.maxY,
                left: contentRect.minX - frameRect.minX,
                bottom: contentRect.minY - frameRect.minY,
                right: frameRect.maxX - contentRect.maxX
            )
            return WuiLayoutContext(safeArea: WuiSafeAreaInsets(from: insets))
        }
        
        return .empty
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Re-layout when moved to a window (safe area may change)
        cachedMeasurements = []
        needsLayout = true
    }
}
#endif

