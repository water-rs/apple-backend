import CWaterUI
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct WuiProposalSize {
    var width: Float?
    var height: Float?

    init(width: Float? = nil, height: Float? = nil) {
        self.width = width
        self.height = height
    }

    init(_ raw: CWaterUI.WuiProposalSize) {
        self.width = raw.width.isNaN ? nil : raw.width
        self.height = raw.height.isNaN ? nil : raw.height
    }

    init(_ proposal: ProposedViewSize) {
        self.width = proposal.width.map { Float($0) }
        self.height = proposal.height.map { Float($0) }
    }

    init(size: CGSize) {
        self.width = size.width.isNaN ? nil : Float(size.width)
        self.height = size.height.isNaN ? nil : Float(size.height)
    }

    func toCStruct() -> CWaterUI.WuiProposalSize {
        CWaterUI.WuiProposalSize(
            width: width ?? .nan,
            height: height ?? .nan
        )
    }

    func toProposedSize() -> ProposedViewSize {
        ProposedViewSize(
            width: width.map { CGFloat($0) },
            height: height.map { CGFloat($0) }
        )
    }
}

struct WuiPoint {
    var x: Float
    var y: Float

    init(_ point: CGPoint) {
        self.x = Float(point.x)
        self.y = Float(point.y)
    }

    init(_ raw: CWaterUI.WuiPoint) {
        self.x = raw.x
        self.y = raw.y
    }

    func toCStruct() -> CWaterUI.WuiPoint {
        CWaterUI.WuiPoint(x: x, y: y)
    }

    var cgPoint: CGPoint {
        CGPoint(x: CGFloat(x), y: CGFloat(y))
    }
}

struct WuiSize {
    var width: Float
    var height: Float

    init(width: Float, height: Float) {
        self.width = width
        self.height = height
    }

    init(_ size: CGSize) {
        self.width = Float(size.width)
        self.height = Float(size.height)
    }

    init(_ raw: CWaterUI.WuiSize) {
        self.width = raw.width
        self.height = raw.height
    }

    func toCStruct() -> CWaterUI.WuiSize {
        CWaterUI.WuiSize(width: width, height: height)
    }

    var cgSize: CGSize {
        CGSize(width: CGFloat(width), height: CGFloat(height))
    }
}

struct WuiRect {
    var origin: WuiPoint
    var size: WuiSize

    init(_ rect: CGRect) {
        self.origin = WuiPoint(rect.origin)
        self.size = WuiSize(rect.size)
    }

    init(_ raw: CWaterUI.WuiRect) {
        self.origin = WuiPoint(raw.origin)
        self.size = WuiSize(raw.size)
    }

    func toCStruct() -> CWaterUI.WuiRect {
        CWaterUI.WuiRect(origin: origin.toCStruct(), size: size.toCStruct())
    }

    var cgRect: CGRect {
        CGRect(origin: origin.cgPoint, size: size.cgSize)
    }
}

struct WuiChildMetadata {
    var proposal: WuiProposalSize
    var priority: UInt8
    var stretch: Bool

    init(proposal: WuiProposalSize = .init(), priority: UInt8 = 0, stretch: Bool = false) {
        self.proposal = proposal
        self.priority = priority
        self.stretch = stretch
    }

    init(_ raw: CWaterUI.WuiChildMetadata) {
        self.proposal = WuiProposalSize(raw.proposal)
        self.priority = raw.priority
        self.stretch = raw.stretch
    }

    func toCStruct() -> CWaterUI.WuiChildMetadata {
        CWaterUI.WuiChildMetadata(
            proposal: proposal.toCStruct(),
            priority: priority,
            stretch: stretch
        )
    }
}

// MARK: - Safe Area Types

/// Safe area insets in points, relative to the container bounds
struct WuiSafeAreaInsets {
    var top: Float
    var bottom: Float
    var leading: Float
    var trailing: Float

    static let zero = WuiSafeAreaInsets(top: 0, bottom: 0, leading: 0, trailing: 0)

    init(top: Float = 0, bottom: Float = 0, leading: Float = 0, trailing: Float = 0) {
        self.top = top
        self.bottom = bottom
        self.leading = leading
        self.trailing = trailing
    }

    init(_ raw: CWaterUI.WuiSafeAreaInsets) {
        self.top = raw.top
        self.bottom = raw.bottom
        self.leading = raw.leading
        self.trailing = raw.trailing
    }

    #if canImport(UIKit)
    init(from insets: UIEdgeInsets, layoutDirection: UIUserInterfaceLayoutDirection = .leftToRight) {
        self.top = Float(insets.top)
        self.bottom = Float(insets.bottom)
        // Convert left/right to leading/trailing based on layout direction
        if layoutDirection == .rightToLeft {
            self.leading = Float(insets.right)
            self.trailing = Float(insets.left)
        } else {
            self.leading = Float(insets.left)
            self.trailing = Float(insets.right)
        }
    }
    #endif

    #if canImport(AppKit)
    init(from insets: NSEdgeInsets) {
        self.top = Float(insets.top)
        self.bottom = Float(insets.bottom)
        self.leading = Float(insets.left)
        self.trailing = Float(insets.right)
    }
    #endif

    func toCStruct() -> CWaterUI.WuiSafeAreaInsets {
        CWaterUI.WuiSafeAreaInsets(
            top: top,
            bottom: bottom,
            leading: leading,
            trailing: trailing
        )
    }
}

/// Bitflags for safe area edges that can be selectively ignored
struct WuiSafeAreaEdges: OptionSet {
    let rawValue: UInt8

    static let top = WuiSafeAreaEdges(rawValue: 0b0001)
    static let bottom = WuiSafeAreaEdges(rawValue: 0b0010)
    static let leading = WuiSafeAreaEdges(rawValue: 0b0100)
    static let trailing = WuiSafeAreaEdges(rawValue: 0b1000)

    static let horizontal: WuiSafeAreaEdges = [.leading, .trailing]
    static let vertical: WuiSafeAreaEdges = [.top, .bottom]
    static let all: WuiSafeAreaEdges = [.top, .bottom, .leading, .trailing]

    init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    init(_ raw: CWaterUI.WuiSafeAreaEdges) {
        self.rawValue = raw.bits
    }

    func toCStruct() -> CWaterUI.WuiSafeAreaEdges {
        CWaterUI.WuiSafeAreaEdges(bits: rawValue)
    }
}

/// Context passed to layout operations containing safe area and other layout state
struct WuiLayoutContext {
    var safeArea: WuiSafeAreaInsets
    var ignoresSafeArea: WuiSafeAreaEdges

    static let empty = WuiLayoutContext(safeArea: .zero, ignoresSafeArea: [])

    init(safeArea: WuiSafeAreaInsets = .zero, ignoresSafeArea: WuiSafeAreaEdges = []) {
        self.safeArea = safeArea
        self.ignoresSafeArea = ignoresSafeArea
    }

    init(_ raw: CWaterUI.WuiLayoutContext) {
        self.safeArea = WuiSafeAreaInsets(raw.safe_area)
        self.ignoresSafeArea = WuiSafeAreaEdges(raw.ignores_safe_area)
    }

    #if canImport(UIKit)
    init(from insets: UIEdgeInsets, layoutDirection: UIUserInterfaceLayoutDirection = .leftToRight) {
        self.safeArea = WuiSafeAreaInsets(from: insets, layoutDirection: layoutDirection)
        self.ignoresSafeArea = []
    }
    #endif

    func toCStruct() -> CWaterUI.WuiLayoutContext {
        CWaterUI.WuiLayoutContext(
            safe_area: safeArea.toCStruct(),
            ignores_safe_area: ignoresSafeArea.toCStruct()
        )
    }
}

/// Result of placing a child view (rect + context for nested layouts)
struct WuiChildPlacement {
    var rect: WuiRect
    var context: WuiLayoutContext

    init(rect: WuiRect, context: WuiLayoutContext) {
        self.rect = rect
        self.context = context
    }

    init(_ raw: CWaterUI.WuiChildPlacement) {
        self.rect = WuiRect(raw.rect)
        self.context = WuiLayoutContext(raw.context)
    }

    var cgRect: CGRect {
        rect.cgRect
    }
}

// MARK: - Layout Engine

@MainActor
final class WuiLayout {
    private var inner: OpaquePointer

    init(inner: OpaquePointer) {
        self.inner = inner
    }

    @MainActor deinit {
        waterui_drop_layout(inner)
    }

    func propose(
        parent: WuiProposalSize,
        children: [WuiChildMetadata],
        context: WuiLayoutContext = .empty
    ) -> [WuiProposalSize] {
        let childArray = WuiArray(array: children.map { $0.toCStruct() })
        let parentRaw = parent.toCStruct()
        let contextRaw = context.toCStruct()

        let typedChildren = unsafeBitCast(
            childArray.inner.intoInner(),
            to: CWaterUI.WuiArray_WuiChildMetadata.self
        )
        let proposals = waterui_layout_propose(inner, parentRaw, typedChildren, contextRaw)
        let rawArray = unsafeBitCast(proposals, to: CWaterUI.WuiArray.self)
        let bridged = WuiArray<CWaterUI.WuiProposalSize>(c: rawArray)
        return bridged.toArray().map { WuiProposalSize($0) }
    }

    func size(
        parent: WuiProposalSize,
        children: [WuiChildMetadata],
        context: WuiLayoutContext = .empty
    ) -> CGSize {
        let childArray = WuiArray(array: children.map { $0.toCStruct() })
        let parentRaw = parent.toCStruct()
        let contextRaw = context.toCStruct()

        let typedChildren = unsafeBitCast(
            childArray.inner.intoInner(),
            to: CWaterUI.WuiArray_WuiChildMetadata.self
        )
        let size = waterui_layout_size(inner, parentRaw, typedChildren, contextRaw)
        return WuiSize(size).cgSize
    }

    /// Places children and returns just the rects (legacy compatibility)
    func place(
        bound: CGRect,
        proposal: WuiProposalSize,
        children: [WuiChildMetadata],
        context: WuiLayoutContext = .empty
    ) -> [CGRect] {
        placements(bound: bound, proposal: proposal, children: children, context: context)
            .map { $0.cgRect }
    }

    /// Places children and returns full placements with context for nested layouts
    func placements(
        bound: CGRect,
        proposal: WuiProposalSize,
        children: [WuiChildMetadata],
        context: WuiLayoutContext = .empty
    ) -> [WuiChildPlacement] {
        let childArray = WuiArray(array: children.map { $0.toCStruct() })
        let boundRaw = WuiRect(bound).toCStruct()
        let proposalRaw = proposal.toCStruct()
        let contextRaw = context.toCStruct()

        let typedChildren = unsafeBitCast(
            childArray.inner.intoInner(),
            to: CWaterUI.WuiArray_WuiChildMetadata.self
        )
        let placements = waterui_layout_place(inner, boundRaw, proposalRaw, typedChildren, contextRaw)
        let rawArray = unsafeBitCast(placements, to: CWaterUI.WuiArray.self)
        let bridged = WuiArray<CWaterUI.WuiChildPlacement>(c: rawArray)
        return bridged.toArray().map { WuiChildPlacement($0) }
    }
}

@MainActor
struct WuiLayoutContainer: WuiComponent, View {
    static let id: String = Self.decodeId(waterui_layout_container_id())

    private var layout: WuiLayout
    private var children: [WuiAnyView]
    private var descriptors: [PlatformViewDescriptor]

    init(anyview: OpaquePointer, env: WuiEnvironment) {
        let container = waterui_force_as_layout_container(anyview)
        self.layout = WuiLayout(inner: container.layout!)

        let anyViews = WuiAnyViews(container.contents)
        var children: [WuiAnyView] = []
        children.reserveCapacity(anyViews.count)
        for i in 0..<anyViews.count {
            children.append(anyViews.getView(at: i, env: env))
        }
        self.children = children

        self.descriptors = children.map { view in
            let id = view.typeId
            return PlatformViewDescriptor(typeId: id, isSpacer: id == WuiSpacer.id)
        }
    }

    var body: some View {
        RustLayout(layout: layout, descriptors: descriptors) {
            ForEach(children) { child in
                child
            }
        }
    }
}

@MainActor
struct WuiFixedContainer: WuiComponent, View {
    static let id: String = Self.decodeId(waterui_fixed_container_id())

    private var layout: WuiLayout
    private var children: [WuiAnyView]
    private var descriptors: [PlatformViewDescriptor]

    init(anyview: OpaquePointer, env: WuiEnvironment) {
        let container = waterui_force_as_fixed_container(anyview)
        self.layout = WuiLayout(inner: container.layout!)

        let pointerArray = WuiArray<OpaquePointer>(container.contents)
        let resolvedChildren = pointerArray
            .toArray()
            .map { WuiAnyView(anyview: $0, env: env) }

        self.children = resolvedChildren
        self.descriptors = resolvedChildren.map { view in
            let id = view.typeId
            return PlatformViewDescriptor(typeId: id, isSpacer: id == WuiSpacer.id)
        }
    }

    var body: some View {
        RustLayout(layout: layout, descriptors: descriptors) {
            ForEach(children) { child in
                child
            }
        }
    }
}

private struct RustLayout: @preconcurrency Layout {
    private var layout: WuiLayout
    private var descriptors: [PlatformViewDescriptor]
    private var bridge = NativeLayoutBridge()

    init(layout: WuiLayout, descriptors: [PlatformViewDescriptor]) {
        self.layout = layout
        self.descriptors = descriptors
    }

    // --- Cache remains the same ---
    struct Cache {
        var measurements: [NativeLayoutBridge.ChildMeasurement] = []
        var lastBounds: CGSize?
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache()
    }
    
    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        // Cache is generated on-demand in sizeThatFits
    }

    // --- MAJOR REFACTOR HERE ---
    @MainActor func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) -> CGSize {
        let rawParentProposal = WuiProposalSize(proposal)
        let parentProposals = resolveParentProposal(
            raw: rawParentProposal,
            fallback: proposal,
            cache: cache
        )
        let parentProposal = parentProposals.wui

        var contexts: [NativeLayoutBridge.ChildContext] = []
        contexts.reserveCapacity(subviews.count)
        for index in subviews.indices {
            let descriptor = descriptors[safe: index] ?? PlatformViewDescriptor(typeId: "", isSpacer: false)
            let priority = priorityValue(from: subviews[index])
            contexts.append(
                NativeLayoutBridge.ChildContext(
                    descriptor: descriptor,
                    priority: priority
                )
            )
        }

        let childProposals = bridge.requestChildProposals(
            layout: layout,
            parentProposal: parentProposal,
            contexts: contexts
        )

        var measurements: [NativeLayoutBridge.ChildMeasurement] = []
        measurements.reserveCapacity(subviews.count)

        for index in subviews.indices {
            let subview = subviews[index]
            let context = contexts[index]

            let childProposal = childProposals[safe: index] ?? WuiProposalSize()
            let swiftUIProposal = sanitizedProposal(from: childProposal)
            
            // 1) Measure with the proposal we got from Rust
            var measuredSize = subview.sizeThatFits(swiftUIProposal)
            
            // 2) Apply WaterUI category rules (Option 5 from layout report):
            //    - Text (content-sized): use proposal only for wrapping/height;
            //      report intrinsic content width so centering works.
            //    - Axis-expanding (TextField/Slider/Progress(linear)/Color with frame): 
            //      fill available width.
            //    - Everyone else: clamp to proposal width at most (safety).
            let typeId = descriptors[safe: index]?.typeId ?? ""
            
            if typeId == WuiText.id {
                // Height comes from wrapped measurement at proposed width
                let wrappedHeight = measuredSize.height
                // Intrinsic width independent of proposed width
                let intrinsicForWidth = subview.sizeThatFits(
                    ProposedViewSize(width: nil, height: swiftUIProposal.height)
                ).width
                measuredSize = CGSize(
                    width: min(intrinsicForWidth, swiftUIProposal.width ?? intrinsicForWidth),
                    height: wrappedHeight
                )
            } else if isAxisExpanding(typeId) {
                // Axis-expanding views fill the proposed width
                if let w = swiftUIProposal.width, w.isValidForLayout {
                    measuredSize = CGSize(width: w, height: measuredSize.height)
                }
            } else {
                // Defensive clamp (never exceed proposed width)
                measuredSize = CGSize(
                    width: constrainedDimension(measuredSize.width, limit: swiftUIProposal.width),
                    height: measuredSize.height
                )
            }

            let measurement = NativeLayoutBridge.ChildMeasurement(
                context: context,
                // IMPORTANT: send what we MEASURED (Android parity), not the proposal
                proposal: WuiProposalSize(size: measuredSize),
                measuredSize: measuredSize
            )
            measurements.append(measurement)
        }

        cache.measurements = measurements

        let finalSize = bridge.containerSize(
            layout: layout,
            parentProposal: parentProposal,
            measurements: measurements
        )

        return finalSize
    }

    // --- Minor change to use the cache correctly ---
    @MainActor func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        guard bounds.isValidForLayout else {
            print("Warning: RustLayout.placeSubviews received invalid bounds: \(bounds)")
            return
        }

        cache.lastBounds = bounds.size

        let rawParentProposal = WuiProposalSize(proposal)
        let parentProposal = resolveParentProposal(
            raw: rawParentProposal,
            fallback: proposal,
            cache: cache
        ).wui
        
        guard !cache.measurements.isEmpty else {
            return
        }

        let rects = bridge.frames(
            layout: layout,
            bounds: bounds,
            parentProposal: parentProposal,
            measurements: cache.measurements
        )

        for index in subviews.indices {
            guard let rect = rects[safe: index], rect.isValidForLayout else {
                print("Warning: RustLayout received an invalid rect for subview at index \(index): \(rects[safe: index] ?? .zero). Skipping placement.")
                continue
            }

            let sizeProposal = ProposedViewSize(width: rect.width, height: rect.height)
            subviews[index].place(
                at: CGPoint(x: rect.minX, y: rect.minY),
                proposal: sizeProposal
            )
        }
    }

    private func priorityValue(from subview: LayoutSubviews.Element) -> UInt8 {
        let raw = subview.priority
        guard raw.isFinite, raw > 0 else { return 0 }
        let clamped = min(max(raw, 0.0), 255.0)
        return UInt8(clamped.rounded())
    }

    private func sanitizedProposal(
        from childProposal: WuiProposalSize
    ) -> ProposedViewSize {
        ProposedViewSize(
            width: cleanDimension(raw: childProposal.width),
            height: cleanDimension(raw: childProposal.height)
        )
    }

    private func constrainedDimension(
        _ value: CGFloat,
        limit: CGFloat?
    ) -> CGFloat {
        guard let limit, limit.isFinite else {
            return value
        }
        return min(value, limit)
    }

    private func resolveParentProposal(
        raw parent: WuiProposalSize,
        fallback: ProposedViewSize,
        cache: Cache
    ) -> (swift: ProposedViewSize, wui: WuiProposalSize) {
        let width = resolveParentDimension(
            raw: parent.width,
            fallback: fallback.width,
            cached: cache.lastBounds?.width
        )
        let height = resolveParentDimension(
            raw: parent.height,
            fallback: fallback.height,
            cached: cache.lastBounds?.height
        )

        let swiftProposal = ProposedViewSize(width: width, height: height)
        let wuiProposal = WuiProposalSize(
            width: width.map { Float($0) },
            height: height.map { Float($0) }
        )

        return (swiftProposal, wuiProposal)
    }

    // Preserve semantics:
    // - NaN (None)      -> nil  (intrinsic)
    // - finite value    -> value (Exact)
    // - +Infinity       -> .greatestFiniteMagnitude (unbounded / "fill")
    private func cleanDimension(raw: Float?) -> CGFloat? {
        guard let raw else { return nil }
        if raw.isNaN { return nil }
        if raw.isInfinite { return .greatestFiniteMagnitude }
        return CGFloat(raw)
    }

    private func resolveParentDimension(
        raw: Float?,
        fallback: CGFloat?,
        cached: CGFloat?
    ) -> CGFloat? {
        if let dimension = cleanDimension(raw: raw) {
            return dimension
        }
        if let fallback, fallback.isFinite {
            return fallback
        }
        if let cached, cached.isFinite {
            return cached
        }
        return nil
    }
    
    // MARK: - Type Category Detection
    
    /// Axis-expanding views fill available width (in VStack) or height (in HStack).
    /// Per LAYOUT_SPEC.md: TextField, Slider, ProgressView (linear), Color (greedy).
    /// Divider uses Color internally with width(INFINITY), so Color handles it.
    @MainActor
    private func isAxisExpanding(_ typeId: String) -> Bool {
        // TextField, Slider, Progress are axis-expanding controls
        // Color is greedy (expands both dimensions) - Divider uses Color internally
        return typeId == WuiTextField.id
            || typeId == WuiSlider.id
            || typeId == WuiProgress.id
            || typeId == WuiColorView.id
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}


extension CGFloat {
    /// Checks if the value is a valid, finite number suitable for layout calculations.
    var isValidForLayout: Bool {
        return !self.isNaN && !self.isInfinite
    }
}

extension CGRect {
    /// Checks if the rect's origin and size are composed of valid, finite numbers.
    var isValidForLayout: Bool {
        return origin.x.isValidForLayout &&
               origin.y.isValidForLayout &&
               size.width.isValidForLayout &&
               size.height.isValidForLayout
    }
}
