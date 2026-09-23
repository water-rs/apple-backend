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

public struct WuiProposalSize: Equatable {
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

/// A placed child: its frame in the parent's coordinate space paired with the
/// proposal the layout selected to measure and recursively lay it out.
///
/// The proposal is contract data returned by `waterui_layout_place_subviews`
/// alongside the frame — a layout probes a child under several proposals
/// before choosing one, so it is never reconstructed from the frame, the
/// parent's bounds, or whichever probe ran last.
struct WuiSubviewPlacement {
  var frame: CGRect
  var proposal: WuiProposalSize

  init(_ raw: CWaterUI.WuiSubviewPlacement) {
    self.frame = WuiRect(raw.frame).cgRect
    self.proposal = WuiProposalSize(raw.proposal)
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

  /// Place children within the given bounds under the selected proposal.
  ///
  /// `proposal` is the same value the container was measured with — it selects
  /// which of a layout's possible distributions the placement realizes. The
  /// returned [`WuiSubviewPlacement`] values pair each child's frame with the
  /// proposal negotiated for it, which is what the child's own layout pass
  /// must receive verbatim.
  func placeSubviews(
    bounds: CGRect,
    proposal: WuiProposalSize,
    children: CachedSubViewArray
  ) -> [WuiSubviewPlacement] {
    let boundsRaw = WuiRect(bounds).toCStruct()
    let placements = waterui_layout_place_subviews(
      inner,
      boundsRaw,
      proposal.toCStruct(),
      children.ffiArray
    )
    return WuiArray<CWaterUI.WuiSubviewPlacement>(placements).map(WuiSubviewPlacement.init)
  }

  /// The layout's live stretch answer computed from the children's current
  /// stretch axes — the query `NativeView::stretch_axis` runs Rust-side,
  /// forwarded here so containers re-resolve it as their children change.
  func stretchAxis(childAxes: [WuiStretchAxis]) -> WuiStretchAxis {
    let axes = WuiArray<CWaterUI.WuiStretchAxis>(array: childAxes.map { $0.ffiValue })
    let result = waterui_layout_stretch_axis(inner, axes.intoWuiStretchAxisArray())
    return WuiStretchAxis(result)
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
  /// Whether the child renders nothing — a semantic answer, not a measured
  /// size. `true` excludes the child from stack membership (§4.4).
  let isEmpty: Bool
  private var measurementCache: [ProposalCacheKey: WuiViewDimensions] = [:]
  private var activeMeasurements = Set<ProposalCacheKey>()

  init(
    stretchAxis: WuiStretchAxis = .none,
    priority: Int32 = 0,
    isEmpty: Bool = false,
    measure: @escaping (WuiProposalSize) -> WuiViewDimensions
  ) {
    self.measure = measure
    self.stretchAxis = stretchAxis
    self.priority = priority
    self.isEmpty = isEmpty
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
      priority: priority,
      is_empty: isEmpty
    )
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
      && size.height.isValidForLayout && size.width >= 0 && size.height >= 0
  }
}

extension PlatformView {
  /// `frame`, in this view's coordinate space, on the backing pixel grid: the
  /// origin at its nearest pixel, as SwiftUI places a view, and the size at
  /// the pixel count the layout engine measured.
  ///
  /// The layout engine hands back fractional points: a centred leaf lands on a
  /// half pixel whenever its measured width is an odd number of pixels. Left
  /// unaligned, AppKit and UIKit draw the leaf's text from the pixel below the
  /// fractional origin, one pixel off the position SwiftUI rounds the same
  /// frame to — and one pixel is the whole difference between a blurred
  /// parity diff and a clean one.
  ///
  /// The size is aligned on its own, never through the far edge: a measured
  /// size is already a whole number of pixels (text rounds its line box up to
  /// the grid), and rounding both edges of a half-pixel origin takes a pixel
  /// off it half the time — under which a label that measured exactly its
  /// text wraps its last word onto a hidden second line. A size that is off
  /// the grid by more than floating-point noise rounds up, so a leaf is never
  /// placed narrower than it measured.
  func pixelAligned(_ frame: CGRect) -> CGRect {
    #if canImport(AppKit)
      let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    #else
      let scale = traitCollection.displayScale
    #endif
    func pixels(_ points: CGFloat) -> CGFloat { points * scale }
    func gridSize(_ points: CGFloat) -> CGFloat {
      let raw = pixels(points)
      let nearest = raw.rounded()
      // 1e-3 px absorbs the noise of `points * scale` on a value that was
      // produced by dividing a whole pixel count by the same scale.
      return (abs(raw - nearest) < 1e-3 ? nearest : raw.rounded(.up)) / scale
    }
    return CGRect(
      x: pixels(frame.minX).rounded() / scale,
      y: pixels(frame.minY).rounded() / scale,
      width: gridSize(frame.width),
      height: gridSize(frame.height))
  }
}
