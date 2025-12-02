import CWaterUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Proposal and Layout Types

public struct WuiProposalSize {
    public var width: Float?
    public var height: Float?

    public init(width: Float? = nil, height: Float? = nil) {
        self.width = width
        self.height = height
    }

    init(_ raw: CWaterUI.WuiProposalSize) {
        self.width = raw.width.isNaN ? nil : raw.width
        self.height = raw.height.isNaN ? nil : raw.height
    }

    public init(size: CGSize) {
        self.width = size.width.isNaN ? nil : Float(size.width)
        self.height = size.height.isNaN ? nil : Float(size.height)
    }

    func toCStruct() -> CWaterUI.WuiProposalSize {
        CWaterUI.WuiProposalSize(
            width: width ?? .nan,
            height: height ?? .nan
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

    /// Returns the stretch axis of this layout.
    /// VStack returns .horizontal, HStack returns .vertical, etc.
    var stretchAxis: WuiStretchAxis {
        WuiStretchAxis(waterui_layout_stretch_axis(inner))
    }

    /// Calculate the size this layout wants given a proposal.
    /// The layout will call the measure closure multiple times with different proposals.
    func sizeThatFits(
        proposal: WuiProposalSize,
        children: [SubViewProxy]
    ) -> CGSize {
        let subviews = children.map { $0.toWuiSubView() }
        let array = WuiArray(array: subviews)
        let typedArray = unsafeBitCast(
            array.inner.intoInner(),
            to: CWaterUI.WuiArray_WuiSubView.self
        )
        let size = waterui_layout_size_that_fits(inner, proposal.toCStruct(), typedArray)
        return WuiSize(size).cgSize
    }

    /// Place children within the given bounds.
    /// Returns a rect for each child specifying its position and size.
    func place(
        bounds: CGRect,
        children: [SubViewProxy]
    ) -> [CGRect] {
        let subviews = children.map { $0.toWuiSubView() }
        let array = WuiArray(array: subviews)
        let typedArray = unsafeBitCast(
            array.inner.intoInner(),
            to: CWaterUI.WuiArray_WuiSubView.self
        )
        let boundsRaw = WuiRect(bounds).toCStruct()
        let rects = waterui_layout_place(inner, boundsRaw, typedArray)
        let rawArray = unsafeBitCast(rects, to: CWaterUI.WuiArray.self)
        let bridged = WuiArray<CWaterUI.WuiRect>(c: rawArray)
        return bridged.toArray().map { WuiRect($0).cgRect }
    }
}

// MARK: - SubView Proxy

/// A proxy for child views that provides measurement via callback.
/// This mirrors Rust's SubView trait.
@MainActor
final class SubViewProxy {
    /// Closure that measures the child given a proposal
    let measure: (WuiProposalSize) -> CGSize
    /// Which axis this view stretches to fill available space
    let stretchAxis: WuiStretchAxis
    /// Layout priority (higher = measured first)
    let priority: Int32

    init(
        stretchAxis: WuiStretchAxis = .none,
        priority: Int32 = 0,
        measure: @escaping (WuiProposalSize) -> CGSize
    ) {
        self.measure = measure
        self.stretchAxis = stretchAxis
        self.priority = priority
    }

    func toWuiSubView() -> CWaterUI.WuiSubView {
        // Create a retained reference to self for the callback
        let context = Unmanaged.passRetained(self).toOpaque()

        let vtable = CWaterUI.WuiSubViewVTable(
            measure: { contextPtr, proposal in
                guard let contextPtr = contextPtr else {
                    return CWaterUI.WuiSize(width: 0, height: 0)
                }
                let proxy = Unmanaged<SubViewProxy>.fromOpaque(contextPtr).takeUnretainedValue()
                let swiftProposal = WuiProposalSize(proposal)
                let size = proxy.measure(swiftProposal)
                return CWaterUI.WuiSize(width: Float(size.width), height: Float(size.height))
            },
            drop: { contextPtr in
                guard let contextPtr = contextPtr else { return }
                Unmanaged<SubViewProxy>.fromOpaque(contextPtr).release()
            }
        )

        return CWaterUI.WuiSubView(
            context: context,
            vtable: vtable,
            stretch_axis: stretchAxis.ffiValue,
            priority: priority
        )
    }
}

// MARK: - CGFloat Extensions

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
