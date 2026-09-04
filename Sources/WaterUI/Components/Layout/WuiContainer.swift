import CWaterUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

private struct VisibleWindow {
  let start: Int
  let end: Int
  let leadingOffset: CGFloat
}

@MainActor
private struct LazyStackConfig {
  enum Axis {
    case vertical(horizontalAlignment: WuiHorizontalAlignment)
    case horizontal(verticalAlignment: WuiVerticalAlignment)
  }

  let axis: Axis
  let spacing: CGFloat

  init?(layout: WuiLayout) {
    switch layout.lazyStackAxis() {
    case .vertical:
      self.axis = .vertical(horizontalAlignment: layout.lazyStackHorizontalAlignment())
    case .horizontal:
      self.axis = .horizontal(verticalAlignment: layout.lazyStackVerticalAlignment())
    default:
      return nil
    }
    self.spacing = CGFloat(layout.lazyStackSpacing())
  }
}

private func resolveVisibleWindow(
  count: Int,
  startOffset: CGFloat,
  endOffset: CGFloat,
  extentAt: (Int) -> CGFloat
) -> VisibleWindow {
  guard count > 0 else {
    return VisibleWindow(start: 0, end: 0, leadingOffset: 0)
  }

  let clampedStart = max(startOffset, 0)
  let clampedEnd = max(endOffset, clampedStart)
  var index = 0
  var offset: CGFloat = 0

  while index < count {
    let extent = extentAt(index)
    if offset + extent > clampedStart {
      break
    }
    offset += extent
    index += 1
  }

  let start = min(index, count)
  let leadingOffset = offset

  while index < count && offset < clampedEnd {
    offset += extentAt(index)
    index += 1
  }

  return VisibleWindow(start: start, end: min(index, count), leadingOffset: leadingOffset)
}

private final class WuiContainerLayoutInvalidator: @unchecked Sendable {
  weak var container: WuiContainer?

  init(_ container: WuiContainer) {
    self.container = container
  }

  func invalidate() {
    precondition(Thread.isMainThread, "Lazy container viewport updates must run on the UI executor")
    MainActor.assumeIsolated {
      #if canImport(UIKit)
        container?.setNeedsLayout()
      #elseif canImport(AppKit)
        container?.needsLayout = true
      #endif
    }
  }
}

@MainActor
final class WuiContainer: PlatformView, WuiComponent {
  static var rawId: CWaterUI.WuiTypeId { waterui_layout_container_id() }

  private(set) var stretchAxis: WuiStretchAxis

  private var wuiLayout: WuiLayout
  private var anyViews: WuiAnyViews
  private var contentsWatcher: WatcherGuard?
  private var childViews: [WuiAnyView] = []
  private var cachedSubViews: CachedSubViewArray?
  private let bridge = NativeLayoutBridge()
  private let env: WuiEnvironment
  private let usesLazyStack: Bool
  private lazy var layoutInvalidator = WuiContainerLayoutInvalidator(self)

  private var itemIds: [Int32] = []
  private var renderedChildren: [Int32: WuiAnyView] = [:]
  private var measuredMainAxis: [Int32: CGFloat] = [:]
  private var measuredCrossAxis: [Int32: CGFloat] = [:]
  private var lastCrossConstraint: CGFloat = -1
  /// When this container is parented under Auto Layout (e.g. inside a
  /// `UITableViewCell`), `intrinsicContentSize` must report the height
  /// produced by the *current* width so multi-line text wraps correctly.
  /// We track the most recently laid-out width here and reuse it from
  /// `intrinsicContentSize`; any time it changes during `layout`, we
  /// invalidate so Auto Layout re-queries us. Mirror of the same pattern
  /// in `WuiAnyView` (see `Core/AnyView.swift`).
  private var lastAutoLayoutWidth: CGFloat = 0

  #if canImport(UIKit)
    private var scrollObservation: NSKeyValueObservation?
  #elseif canImport(AppKit)
    private var boundsObserver: NSObjectProtocol?
  #endif

  convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
    let stretchAxis = WuiStretchAxis(waterui_view_stretch_axis(anyview))
    let container: CWaterUI.WuiContainer = waterui_force_as_layout_container(anyview)
    let layout = WuiLayout(inner: container.layout!)
    let anyViews = WuiAnyViews(container.contents)
    self.init(stretchAxis: stretchAxis, layout: layout, anyViews: anyViews, env: env)
  }

  init(stretchAxis: WuiStretchAxis, layout: WuiLayout, anyViews: WuiAnyViews, env: WuiEnvironment) {
    self.stretchAxis = stretchAxis
    self.wuiLayout = layout
    self.anyViews = anyViews
    self.env = env
    self.usesLazyStack = LazyStackConfig(layout: layout) != nil
    super.init(frame: .zero)

    wuiLayout.setOwner(self)
    installContentsWatch()
    reloadChildrenFromRust()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func installContentsWatch() {
    contentsWatcher = watchAnyViewsIds(anyViews) { [weak self] ids, metadata in
      guard let self else { return }
      withPlatformAnimation(metadata) {
        if self.usesLazyStack {
          self.updateVirtualIds(ids)
        } else {
          self.syncChildren(ids: ids)
        }
      }
    }
  }

  private func reloadChildrenFromRust() {
    let ids = anyViews.allIds()
    if usesLazyStack {
      updateVirtualIds(ids)
    } else {
      syncChildren(ids: ids)
    }
  }

  private func updateVirtualIds(_ ids: [Int32]) {
    var seenIds = Set<Int32>()
    for id in ids {
      precondition(seenIds.insert(id).inserted, "Duplicate child view id in WuiContainer: \(id)")
    }

    itemIds = ids
    measuredMainAxis = measuredMainAxis.filter { seenIds.contains($0.key) }
    measuredCrossAxis = measuredCrossAxis.filter { seenIds.contains($0.key) }
    for (id, child) in renderedChildren where !seenIds.contains(id) {
      child.removeFromSuperview()
    }
    renderedChildren = renderedChildren.filter { seenIds.contains($0.key) }
    cachedSubViews = nil
    invalidateVirtualLayout()
  }

  private func syncChildren(ids: [Int32]) {
    // Id-keyed reconcile: reuse the already-materialized view of every
    // unchanged id (preserving its in-flight animation, focus, and
    // accessibility node) and only call `getView` for the ids that joined
    // the collection. Mirrors the lazy path's `updateVirtualIds`, so a
    // membership change of a `ForEach`/`List` no longer rebuilds every child.
    var seenIds = Set<Int32>()
    var ordered: [WuiAnyView] = []
    ordered.reserveCapacity(ids.count)
    for (index, id) in ids.enumerated() {
      precondition(seenIds.insert(id).inserted, "Duplicate child view id in WuiContainer: \(id)")
      let child = renderedChildren[id] ?? anyViews.getView(at: index, env: env)
      renderedChildren[id] = child
      child.translatesAutoresizingMaskIntoConstraints = true
      ordered.append(child)
    }
    for (id, child) in renderedChildren where !seenIds.contains(id) {
      child.removeFromSuperview()
    }
    renderedChildren = renderedChildren.filter { seenIds.contains($0.key) }
    reconcileSubviews(ordered)
    childViews = ordered
    cachedSubViews = nil

    #if canImport(UIKit)
      setNeedsLayout()
    #elseif canImport(AppKit)
      needsLayout = true
    #endif
  }

  /// Makes the receiver's subviews exactly `ordered`, in that z-order, reusing
  /// the existing subview instances already attached for unchanged children.
  private func reconcileSubviews(_ ordered: [WuiAnyView]) {
    #if canImport(UIKit)
      let wanted = Set(ordered.lazy.map(ObjectIdentifier.init))
      for sub in subviews where !wanted.contains(ObjectIdentifier(sub)) {
        sub.removeFromSuperview()
      }
      for (index, child) in ordered.enumerated() {
        insertSubview(child, at: index)
      }
    #elseif canImport(AppKit)
      subviews = ordered
    #endif
  }

  // A layout container is not a control: a click none of its children want
  // belongs to whatever is behind it.
  //
  // The platform view answers a hit inside its own bounds with itself, which is
  // right for something that draws and wrong for something that only arranges.
  // A window-filling container — the overlay layer a window composes above its
  // content, for snackbars and dialogs — would otherwise swallow every click
  // that misses its contents, leaving the controls beneath it visible and dead.
  #if canImport(UIKit)
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
      let hit = super.hitTest(point, with: event)
      return hit === self ? nil : hit
    }
  #elseif canImport(AppKit)
    override func hitTest(_ point: NSPoint) -> NSView? {
      let hit = super.hitTest(point)
      return hit === self ? nil : hit
    }
  #endif

  func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
    if let lazyStack = LazyStackConfig(layout: wuiLayout) {
      return lazyStackSizeThatFits(proposal, config: lazyStack)
    }
    return measure(proposal).cgSize
  }

  func measure(_ proposal: WuiProposalSize) -> WuiViewDimensions {
    if let lazyStack = LazyStackConfig(layout: wuiLayout) {
      return WuiViewDimensions(size: lazyStackSizeThatFits(proposal, config: lazyStack))
    }
    return bridge.containerMeasure(
      layout: wuiLayout,
      parentProposal: proposal,
      children: subViewCache()
    )
  }

  #if canImport(UIKit)
    override func layoutSubviews() {
      super.layoutSubviews()
      installScrollObservationIfNeeded()
      performLayout()
      // When parented under Auto Layout (e.g. UITableViewCell) the host
      // gives us a width via constraints. Re-measure the intrinsic
      // height against that width so multi-line content can grow
      // vertically.
      if !translatesAutoresizingMaskIntoConstraints, bounds.width > 0,
        bounds.width != lastAutoLayoutWidth
      {
        lastAutoLayoutWidth = bounds.width
        invalidateIntrinsicContentSize()
      }
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
      sizeThatFits(WuiProposalSize(size: size))
    }

    override var intrinsicContentSize: CGSize {
      var intrinsic = sizeThatFits(WuiProposalSize())
      guard !translatesAutoresizingMaskIntoConstraints, bounds.width > 0 else {
        return intrinsic
      }
      let constrained = sizeThatFits(WuiProposalSize(width: Float(bounds.width), height: nil))
      intrinsic.height = constrained.height
      return intrinsic
    }

    override func didMoveToSuperview() {
      super.didMoveToSuperview()
      teardownScrollObservation()
      installScrollObservationIfNeeded()
    }
  #elseif canImport(AppKit)
    override func layout() {
      super.layout()
      installScrollObservationIfNeeded()
      performLayout()
      if !translatesAutoresizingMaskIntoConstraints, bounds.width > 0,
        bounds.width != lastAutoLayoutWidth
      {
        lastAutoLayoutWidth = bounds.width
        invalidateIntrinsicContentSize()
      }
    }

    override var fittingSize: NSSize {
      sizeThatFits(WuiProposalSize())
    }

    override var intrinsicContentSize: NSSize {
      var intrinsic = sizeThatFits(WuiProposalSize())
      guard !translatesAutoresizingMaskIntoConstraints, bounds.width > 0 else {
        return intrinsic
      }
      let constrained = sizeThatFits(WuiProposalSize(width: Float(bounds.width), height: nil))
      intrinsic.height = constrained.height
      return intrinsic
    }

    nonisolated override var isFlipped: Bool { true }

    override func viewDidMoveToSuperview() {
      super.viewDidMoveToSuperview()
      teardownScrollObservation()
      installScrollObservationIfNeeded()
    }
  #endif

  private func performLayout() {
    if let lazyStack = LazyStackConfig(layout: wuiLayout) {
      performLazyStackLayout(config: lazyStack)
      return
    }

    guard !childViews.isEmpty else { return }

    let boundsProposal = WuiProposalSize(
      width: Float(bounds.width), height: Float(bounds.height))

    _ = bridge.containerSize(
      layout: wuiLayout,
      parentProposal: boundsProposal,
      children: subViewCache()
    )

    let rects = bridge.placements(
      layout: wuiLayout,
      bounds: bounds,
      children: subViewCache()
    )

    precondition(
      rects.count == childViews.count,
      "WuiContainer layout returned \(rects.count) placements for \(childViews.count) children"
    )
    for (index, pair) in zip(childViews, rects).enumerated() {
      let (child, rect) = pair
      var frame = rect
      precondition(
        frame.isValidForLayout,
        "WuiContainer received an invalid layout rect for child \(index): \(frame)"
      )

      #if canImport(AppKit)
        if !isFlipped {
          frame.origin.y = bounds.height - frame.origin.y - frame.height
        }
      #endif

      child.frame = frame
    }
  }

  private func lazyStackSizeThatFits(_ proposal: WuiProposalSize, config: LazyStackConfig) -> CGSize
  {
    guard !itemIds.isEmpty else { return .zero }

    let crossConstraint =
      switch config.axis {
      case .vertical:
        proposal.width.map(CGFloat.init) ?? 0
      case .horizontal:
        proposal.height.map(CGFloat.init) ?? 0
      }

    ensureSampleMeasurement(crossConstraint: crossConstraint, config: config)
    let estimate = estimatedMainAxisExtent(crossConstraint: crossConstraint, config: config)
    let totalMainAxis = itemIds.enumerated().reduce(CGFloat.zero) { partial, pair in
      let (index, id) = pair
      let spacing = index + 1 < itemIds.count ? config.spacing : 0
      return partial + (measuredMainAxis[id] ?? estimate) + spacing
    }

    switch config.axis {
    case .vertical:
      let width =
        proposal.width.map(CGFloat.init)
        ?? measuredCrossAxis.values.max()
        ?? bounds.width
      return CGSize(width: width, height: totalMainAxis)
    case .horizontal:
      let height =
        proposal.height.map(CGFloat.init)
        ?? measuredCrossAxis.values.max()
        ?? bounds.height
      return CGSize(width: totalMainAxis, height: height)
    }
  }

  private func ensureSampleMeasurement(crossConstraint: CGFloat, config: LazyStackConfig) {
    guard measuredMainAxis.isEmpty, let firstId = itemIds.first else { return }
    let sample = renderedChildren[firstId] ?? anyViews.getView(at: 0, env: env)
    let size = measureLazyChild(sample, crossConstraint: crossConstraint, config: config)
    measuredMainAxis[firstId] = mainAxisExtent(of: size, config: config)
    measuredCrossAxis[firstId] = crossAxisExtent(of: size, config: config)
  }

  private func estimatedMainAxisExtent(crossConstraint: CGFloat, config: LazyStackConfig) -> CGFloat
  {
    ensureSampleMeasurement(crossConstraint: crossConstraint, config: config)
    guard !measuredMainAxis.isEmpty else { return 0 }
    return measuredMainAxis.values.reduce(0, +) / CGFloat(measuredMainAxis.count)
  }

  private func mainAxisExtent(of size: CGSize, config: LazyStackConfig) -> CGFloat {
    switch config.axis {
    case .vertical:
      size.height
    case .horizontal:
      size.width
    }
  }

  private func crossAxisExtent(of size: CGSize, config: LazyStackConfig) -> CGFloat {
    switch config.axis {
    case .vertical:
      size.width
    case .horizontal:
      size.height
    }
  }

  private func measureLazyChild(
    _ child: WuiAnyView,
    crossConstraint: CGFloat,
    config: LazyStackConfig
  ) -> CGSize {
    let stretchAxis = child.stretchAxis
    switch config.axis {
    case .vertical:
      precondition(
        stretchAxis != .vertical && stretchAxis != .both && stretchAxis != .mainAxis,
        "Lazy vertical stack does not support children stretching on the main axis"
      )
      let proposal = WuiProposalSize(
        width: crossConstraint > 0 ? Float(crossConstraint) : nil,
        height: nil
      )
      let intrinsic = child.sizeThatFits(proposal)
      let finalWidth: CGFloat
      if stretchAxis == .horizontal || stretchAxis == .both || stretchAxis == .crossAxis
        || intrinsic.width.isInfinite
      {
        finalWidth = crossConstraint > 0 ? crossConstraint : intrinsic.width
      } else if crossConstraint > 0 {
        finalWidth = min(intrinsic.width, crossConstraint)
      } else {
        finalWidth = intrinsic.width
      }
      return CGSize(width: finalWidth, height: intrinsic.height)
    case .horizontal:
      precondition(
        stretchAxis != .horizontal && stretchAxis != .both && stretchAxis != .mainAxis,
        "Lazy horizontal stack does not support children stretching on the main axis"
      )
      let proposal = WuiProposalSize(
        width: nil,
        height: crossConstraint > 0 ? Float(crossConstraint) : nil
      )
      let intrinsic = child.sizeThatFits(proposal)
      let finalHeight: CGFloat
      if stretchAxis == .vertical || stretchAxis == .both || stretchAxis == .crossAxis
        || intrinsic.height.isInfinite
      {
        finalHeight = crossConstraint > 0 ? crossConstraint : intrinsic.height
      } else if crossConstraint > 0 {
        finalHeight = min(intrinsic.height, crossConstraint)
      } else {
        finalHeight = intrinsic.height
      }
      return CGSize(width: intrinsic.width, height: finalHeight)
    }
  }

  private func performLazyStackLayout(config: LazyStackConfig) {
    guard !itemIds.isEmpty else { return }

    let crossConstraint =
      switch config.axis {
      case .vertical:
        bounds.width
      case .horizontal:
        bounds.height
      }

    if crossConstraint != lastCrossConstraint {
      lastCrossConstraint = crossConstraint
      measuredMainAxis.removeAll()
      measuredCrossAxis.removeAll()
      for child in renderedChildren.values {
        child.removeFromSuperview()
      }
      renderedChildren.removeAll()
    }

    let viewport = currentViewportBounds()
    let estimate = estimatedMainAxisExtent(crossConstraint: crossConstraint, config: config)
    let overscan = max(estimate, 1) * 2
    let viewportStart =
      switch config.axis {
      case .vertical:
        viewport.minY
      case .horizontal:
        viewport.minX
      }
    let viewportEnd =
      switch config.axis {
      case .vertical:
        viewport.maxY
      case .horizontal:
        viewport.maxX
      }

    let window = resolveVisibleWindow(
      count: itemIds.count,
      startOffset: max(viewportStart - overscan, 0),
      endOffset: viewportEnd + overscan
    ) { index in
      let id = itemIds[index]
      let extent = measuredMainAxis[id] ?? estimate
      return extent + (index + 1 < itemIds.count ? config.spacing : 0)
    }

    var activeIds = Set<Int32>()
    var cursor = window.leadingOffset
    var needsInvalidation = false

    for index in window.start ..< window.end {
      let id = itemIds[index]
      let child = renderedChildren[id] ?? anyViews.getView(at: index, env: env)
      if renderedChildren[id] == nil {
        child.translatesAutoresizingMaskIntoConstraints = true
        addSubview(child)
        renderedChildren[id] = child
      }
      activeIds.insert(id)

      let size = measureLazyChild(child, crossConstraint: crossConstraint, config: config)
      let mainAxis = mainAxisExtent(of: size, config: config)
      let crossAxis = crossAxisExtent(of: size, config: config)
      if measuredMainAxis[id] != mainAxis || measuredCrossAxis[id] != crossAxis {
        measuredMainAxis[id] = mainAxis
        measuredCrossAxis[id] = crossAxis
        needsInvalidation = true
      }

      switch config.axis {
      case .vertical(let horizontalAlignment):
        let originX: CGFloat
        switch horizontalAlignment {
        case WuiHorizontalAlignment_Leading:
          originX = 0
        case WuiHorizontalAlignment_Trailing:
          originX = bounds.width - size.width
        default:
          originX = (bounds.width - size.width) * 0.5
        }
        child.frame = CGRect(x: originX, y: cursor, width: size.width, height: size.height)
        cursor += size.height + (index + 1 < itemIds.count ? config.spacing : 0)
      case .horizontal(let verticalAlignment):
        let originY: CGFloat
        switch verticalAlignment {
        case WuiVerticalAlignment_Top:
          originY = 0
        case WuiVerticalAlignment_Bottom:
          originY = bounds.height - size.height
        default:
          originY = (bounds.height - size.height) * 0.5
        }
        child.frame = CGRect(x: cursor, y: originY, width: size.width, height: size.height)
        cursor += size.width + (index + 1 < itemIds.count ? config.spacing : 0)
      }
    }

    for (id, child) in renderedChildren where !activeIds.contains(id) {
      child.removeFromSuperview()
    }
    renderedChildren = renderedChildren.filter { activeIds.contains($0.key) }

    if needsInvalidation {
      invalidateVirtualLayout()
    }
  }

  private func invalidateVirtualLayout() {
    cachedSubViews = nil
    invalidateIntrinsicContentSize()
    #if canImport(UIKit)
      setNeedsLayout()
    #elseif canImport(AppKit)
      needsLayout = true
    #endif
    invalidateLayoutHierarchy()
  }

  private func subViewCache() -> CachedSubViewArray {
    if let cachedSubViews {
      return cachedSubViews
    }

    let cache = bridge.createCachedSubViewArray(children: childViews) { child, childProposal in
      child.measure(childProposal)
    }
    cachedSubViews = cache
    return cache
  }

  private func currentViewportBounds() -> CGRect {
    #if canImport(UIKit)
      guard let scrollView = nearestEnclosingScrollView() else {
        return bounds
      }
      return convert(scrollView.bounds, from: scrollView)
    #elseif canImport(AppKit)
      guard let scrollView = enclosingScrollView else {
        return bounds
      }
      return convert(scrollView.contentView.bounds, from: scrollView.contentView)
    #endif
  }

  #if canImport(UIKit)
    private func teardownScrollObservation() {
      scrollObservation?.invalidate()
      scrollObservation = nil
    }

    private func nearestEnclosingScrollView() -> UIScrollView? {
      var view = superview
      while let current = view {
        if let scrollView = current as? UIScrollView {
          return scrollView
        }
        view = current.superview
      }
      return nil
    }

    private func installScrollObservationIfNeeded() {
      guard usesLazyStack else { return }
      guard scrollObservation == nil, let scrollView = nearestEnclosingScrollView() else { return }
      let layoutInvalidator = layoutInvalidator
      scrollObservation = scrollView.observe(\.contentOffset, options: [.new]) {
        [layoutInvalidator] _, _ in
        layoutInvalidator.invalidate()
      }
    }
  #elseif canImport(AppKit)
    private func teardownScrollObservation() {
      if let boundsObserver {
        NotificationCenter.default.removeObserver(boundsObserver)
        self.boundsObserver = nil
      }
      enclosingScrollView?.contentView.postsBoundsChangedNotifications = false
    }

    private func installScrollObservationIfNeeded() {
      guard usesLazyStack else { return }
      guard boundsObserver == nil, let scrollView = enclosingScrollView else { return }
      scrollView.contentView.postsBoundsChangedNotifications = true
      boundsObserver = NotificationCenter.default.addObserver(
        forName: NSView.boundsDidChangeNotification,
        object: scrollView.contentView,
        queue: .main
      ) { [layoutInvalidator] _ in
        layoutInvalidator.invalidate()
      }
    }
  #endif
}
