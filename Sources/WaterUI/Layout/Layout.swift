import CWaterUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

enum LazyStackAxis: Int32 {
  case unsupported = 0
  case vertical = 1
  case horizontal = 2
}

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

public struct WuiHorizontalGuide {
  var alignment: CWaterUI.WuiHorizontalAlignment
  var value: Float

  init(_ raw: CWaterUI.WuiHorizontalGuide) {
    self.alignment = raw.alignment
    self.value = raw.value
  }

  func toCStruct() -> CWaterUI.WuiHorizontalGuide {
    CWaterUI.WuiHorizontalGuide(alignment: alignment, value: value)
  }
}

public struct WuiVerticalGuide {
  var alignment: CWaterUI.WuiVerticalAlignment
  var value: Float

  init(alignment: CWaterUI.WuiVerticalAlignment, value: Float) {
    self.alignment = alignment
    self.value = value
  }

  init(_ raw: CWaterUI.WuiVerticalGuide) {
    self.alignment = raw.alignment
    self.value = raw.value
  }

  func toCStruct() -> CWaterUI.WuiVerticalGuide {
    CWaterUI.WuiVerticalGuide(alignment: alignment, value: value)
  }
}

public struct WuiViewDimensions {
  var size: WuiSize
  var horizontalGuides: [WuiHorizontalGuide]
  var verticalGuides: [WuiVerticalGuide]

  init(
    size: CGSize,
    horizontalGuides: [WuiHorizontalGuide] = [],
    verticalGuides: [WuiVerticalGuide] = []
  ) {
    self.size = WuiSize(size)
    self.horizontalGuides = horizontalGuides
    self.verticalGuides = verticalGuides
  }

  init(_ raw: CWaterUI.WuiViewDimensions) {
    self.size = WuiSize(raw.size)
    self.horizontalGuides = WuiArray<CWaterUI.WuiHorizontalGuide>(raw.horizontal_guides)
      .map(WuiHorizontalGuide.init)
    self.verticalGuides = WuiArray<CWaterUI.WuiVerticalGuide>(raw.vertical_guides)
      .map(WuiVerticalGuide.init)
  }

  var cgSize: CGSize {
    size.cgSize
  }

  func toCStruct() -> CWaterUI.WuiViewDimensions {
    let horizontalArray = WuiArray(array: horizontalGuides.map { $0.toCStruct() })
    let verticalArray = WuiArray(array: verticalGuides.map { $0.toCStruct() })
    return CWaterUI.WuiViewDimensions(
      size: size.toCStruct(),
      horizontal_guides: unsafeBitCast(
        horizontalArray.intoInner(),
        to: CWaterUI.WuiArray_WuiHorizontalGuide.self
      ),
      vertical_guides: unsafeBitCast(
        verticalArray.intoInner(),
        to: CWaterUI.WuiArray_WuiVerticalGuide.self
      )
    )
  }
}

// MARK: - Layout Engine

@MainActor
private final class WuiLayoutInvalidationTarget {
  weak var owner: PlatformView?

  func invalidate() {
    guard let owner else { return }
    owner.invalidateIntrinsicContentSize()
    #if canImport(UIKit)
      owner.setNeedsLayout()
    #elseif canImport(AppKit)
      owner.needsLayout = true
    #endif
    owner.invalidateCapturedRendering()
  }
}

@MainActor
final class WuiLayout {
  private var inner: OpaquePointer
  private let invalidationWatcher: OpaquePointer
  private let invalidationTarget: WuiLayoutInvalidationTarget

  init(inner: OpaquePointer) {
    self.inner = inner
    let invalidationTarget = WuiLayoutInvalidationTarget()
    self.invalidationTarget = invalidationTarget
    let callback = WuiRedrawCallbackBox { [weak invalidationTarget] in
      invalidationTarget?.invalidate()
    }
    self.invalidationWatcher = waterui_layout_watch_invalidation(
      inner,
      Unmanaged.passRetained(callback).toOpaque(),
      wuiRedrawWakeCallback,
      wuiRedrawDropCallback
    )!
  }

  @MainActor deinit {
    waterui_layout_watcher_drop(invalidationWatcher)
    waterui_drop_layout(inner)
  }

  func setOwner(_ owner: PlatformView) {
    invalidationTarget.owner = owner
  }

  func measure(
    proposal: WuiProposalSize,
    children: CachedSubViewArray
  ) -> WuiViewDimensions {
    let dimensions = waterui_layout_measure(inner, proposal.toCStruct(), children.ffiArray)
    return WuiViewDimensions(dimensions)
  }

  /// Place children within the given bounds.
  /// Returns a rect for each child specifying its position and size.
  func place(
    bounds: CGRect,
    children: CachedSubViewArray
  ) -> [CGRect] {
    let boundsRaw = WuiRect(bounds).toCStruct()
    let rects = waterui_layout_place(inner, boundsRaw, children.ffiArray)
    let rawArray = unsafeBitCast(rects, to: CWaterUI.WuiArray.self)
    let bridged = WuiArray<CWaterUI.WuiRect>(c: rawArray)
    return bridged.map { WuiRect($0).cgRect }
  }

  func lazyStackAxis() -> LazyStackAxis {
    switch waterui_layout_lazy_stack_axis(inner) {
    case WuiLazyStackAxis_Unsupported: return .unsupported
    case WuiLazyStackAxis_Vertical: return .vertical
    case WuiLazyStackAxis_Horizontal: return .horizontal
    default: fatalError("Unknown WaterUI lazy stack axis")
    }
  }

  func lazyStackSpacing() -> Float {
    waterui_layout_lazy_stack_spacing(inner)
  }

  func lazyStackHorizontalAlignment() -> CWaterUI.WuiHorizontalAlignment {
    waterui_layout_lazy_stack_horizontal_alignment(inner)
  }

  func lazyStackVerticalAlignment() -> CWaterUI.WuiVerticalAlignment {
    waterui_layout_lazy_stack_vertical_alignment(inner)
  }
}

// MARK: - SubView Proxy

@MainActor
final class CachedSubViewArray {
  private static let vtable = CWaterUI.WuiArrayVTable(
    drop: { _ in },
    slice: { data in
      guard let data else {
        return WuiArraySlice(head: nil, len: 0)
      }

      let cache = Unmanaged<CachedSubViewArray>.fromOpaque(data).takeUnretainedValue()
      return WuiArraySlice(head: cache.baseAddress, len: UInt(cache.subviews.count))
    }
  )

  private let proxies: [SubViewProxy]
  private let subviews: ContiguousArray<CWaterUI.WuiSubView>
  private let baseAddress: UnsafeMutableRawPointer?

  init(_ proxies: [SubViewProxy]) {
    self.proxies = proxies
    let subviews = ContiguousArray(proxies.map { $0.toBorrowedWuiSubView() })
    self.baseAddress = subviews.withUnsafeBufferPointer { buffer in
      UnsafeMutableRawPointer(mutating: buffer.baseAddress)
    }
    self.subviews = subviews
  }

  var ffiArray: CWaterUI.WuiArray_WuiSubView {
    let raw = CWaterUI.WuiArray(
      data: Unmanaged.passUnretained(self).toOpaque(),
      vtable: Self.vtable
    )
    return unsafeBitCast(raw, to: CWaterUI.WuiArray_WuiSubView.self)
  }

  func resetMeasurements() {
    for proxy in proxies {
      proxy.resetMeasurementCache()
    }
  }
}

/// A proxy for child views that provides measurement via callback.
/// This mirrors Rust's SubView trait.
@MainActor
final class SubViewProxy {
  private struct ProposalCacheKey: Hashable {
    private static let none = UInt32.max

    let width: UInt32
    let height: UInt32

    init(_ proposal: WuiProposalSize) {
      self.width = proposal.width.map { $0.bitPattern } ?? Self.none
      self.height = proposal.height.map { $0.bitPattern } ?? Self.none
    }
  }

  /// Closure that measures the child given a proposal.
  private let measure: (WuiProposalSize) -> WuiViewDimensions
  /// Which axis this view stretches to fill available space
  let stretchAxis: WuiStretchAxis
  /// Layout priority (higher = measured first)
  let priority: Int32
  private var measurementCache: [ProposalCacheKey: WuiViewDimensions] = [:]
  private var activeMeasurements = Set<ProposalCacheKey>()

  init(
    stretchAxis: WuiStretchAxis = .none,
    priority: Int32 = 0,
    measure: @escaping (WuiProposalSize) -> WuiViewDimensions
  ) {
    self.measure = measure
    self.stretchAxis = stretchAxis
    self.priority = priority
  }

  func toBorrowedWuiSubView() -> CWaterUI.WuiSubView {
    let vtable = CWaterUI.WuiSubViewVTable(
      measure: { contextPtr, proposal in
        guard let contextPtr = contextPtr else {
          return WuiViewDimensions(size: .zero).toCStruct()
        }
        let proxy = Unmanaged<SubViewProxy>.fromOpaque(contextPtr).takeUnretainedValue()
        let swiftProposal = WuiProposalSize(proposal)
        return proxy.measureCached(swiftProposal).toCStruct()
      },
      drop: { _ in }
    )

    return CWaterUI.WuiSubView(
      context: Unmanaged.passUnretained(self).toOpaque(),
      vtable: vtable,
      stretch_axis: stretchAxis.ffiValue,
      priority: priority
    )
  }

  func resetMeasurementCache() {
    measurementCache.removeAll(keepingCapacity: true)
    activeMeasurements.removeAll(keepingCapacity: true)
  }

  private func measureCached(_ proposal: WuiProposalSize) -> WuiViewDimensions {
    let key = ProposalCacheKey(proposal)
    if let cached = measurementCache[key] {
      return cached
    }
    guard activeMeasurements.insert(key).inserted else {
      fatalError("WaterUI: recursive layout measurement for proposal \(proposal)")
    }
    let dimensions = measure(proposal)
    activeMeasurements.remove(key)
    measurementCache[key] = dimensions
    return dimensions
  }
}

// MARK: - CGFloat Extensions

extension CGFloat {
  /// Checks if the value is a valid, finite number suitable for layout calculations.
  var isValidForLayout: Bool {
    !isNaN && !isInfinite
  }
}

extension CGRect {
  /// Checks if the rect's origin and size are composed of valid, finite numbers.
  var isValidForLayout: Bool {
    origin.x.isValidForLayout && origin.y.isValidForLayout && size.width.isValidForLayout
      && size.height.isValidForLayout
  }
}
