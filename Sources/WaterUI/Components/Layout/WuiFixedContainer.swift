// WuiFixedContainer.swift
// Fixed container layout component - children are a fixed array (no lazy loading)
//
// # Layout Behavior
// Container delegates layout calculations to the Rust layout engine.
// Size and placement are determined by the layout algorithm (VStack, HStack, etc.).
// Children are provided as a fixed array at construction time.
//
// // INTERNAL: Layout Contract for Backend Implementers
// // - stretchAxis: Depends on children and layout algorithm
// // - sizeThatFits: Delegates to Rust layout engine
// // - Priority: 0 (default)

import CWaterUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

/// A native container that uses the Rust layout engine for child positioning.
/// FixedContainer has a fixed array of children - no lazy loading support.
@MainActor
final class WuiFixedContainer: PlatformView, WuiComponent {
  static var rawId: CWaterUI.WuiTypeId { waterui_fixed_container_id() }

  /// `FixedContainer::stretch_axis` answers from its children's current axes
  /// (`layout.stretch_axis(&child_stretch_axes())`), so the property re-asks
  /// the layout each time rather than freezing the axis read at init.
  var stretchAxis: WuiStretchAxis {
    wuiLayout.stretchAxis(childAxes: childViews.map { $0.stretchAxis })
  }

  /// `stretchAxis` answered against caller-supplied child axes — the macOS
  /// page-column question re-asks the layout with scroll-transparent axes, so
  /// a scroll of hugging content does not make the page greedy.
  func stretchAxis(childAxes: [WuiStretchAxis]) -> WuiStretchAxis {
    wuiLayout.stretchAxis(childAxes: childAxes)
  }

  private var wuiLayout: WuiLayout
  private(set) var childViews: [WuiAnyView]
  private var cachedSubViews: CachedSubViewArray?
  private let bridge = NativeLayoutBridge()

  /// The proposal the parent layout selected when it placed this container —
  /// delivered through `setPlacementProposal`. `nil` means no Rust parent has
  /// placed us: the container is natively hosted and constructs its own
  /// bounded offer from the rect it fills.
  private var selectedProposal: WuiProposalSize?

  // MARK: - WuiComponent Init

  convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
    let container: CWaterUI.WuiFixedContainer = waterui_force_as_fixed_container(anyview)
    let layout = WuiLayout(inner: container.layout!)
    let pointerArray = WuiArray<OpaquePointer>(container.contents)
    let childViews = pointerArray.map {
      WuiAnyView(anyview: $0, env: env)
    }
    self.init(layout: layout, children: childViews)
  }

  // MARK: - Designated Init

  init(layout: WuiLayout, children: [WuiAnyView]) {
    self.wuiLayout = layout
    self.childViews = children
    super.init(frame: .zero)
    wuiLayout.setOwner(self)
    setChildren(children)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: - WuiComponent

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

  /// Content feeding the cached child entries invalidated — a descendant's
  /// `invalidateLayoutHierarchy` and the Rust layout watcher's
  /// `WuiLayoutInvalidationTarget` both funnel through here. Rebuild rather
  /// than only flushing measurement caches: child stretch axes and layout
  /// priorities are baked into the `WuiSubView` array and may themselves have
  /// changed.
  override func invalidateIntrinsicContentSize() {
    cachedSubViews = nil
    super.invalidateIntrinsicContentSize()
  }

  /// A new selected proposal invalidates placement even when the frame does
  /// not move — equal bounds under a different offer can produce a different
  /// child layout, which is exactly the case this contract exists for.
  func setPlacementProposal(_ proposal: WuiProposalSize) {
    guard selectedProposal != proposal else { return }
    selectedProposal = proposal
    #if canImport(UIKit)
      setNeedsLayout()
    #elseif canImport(AppKit)
      needsLayout = true
    #endif
  }

  func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
    measure(proposal).cgSize
  }

  func measure(_ proposal: WuiProposalSize) -> WuiViewDimensions {
    return bridge.containerMeasure(
      layout: wuiLayout,
      parentProposal: proposal,
      children: subViewCache()
    )
  }

  // MARK: - Layout

  #if canImport(UIKit)
    override func layoutSubviews() {
      super.layoutSubviews()
      performLayout()
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
      let proposal = WuiProposalSize(size: size)
      return sizeThatFits(proposal)
    }

    override var intrinsicContentSize: CGSize {
      sizeThatFits(WuiProposalSize())
    }
  #elseif canImport(AppKit)
    override func layout() {
      super.layout()
      performLayout()
    }

    override var fittingSize: NSSize {
      sizeThatFits(WuiProposalSize())
    }

    override var intrinsicContentSize: NSSize {
      sizeThatFits(WuiProposalSize())
    }

    nonisolated override var isFlipped: Bool { true }
  #endif

  /// Children are laid out inside the safe area; a child that handles the safe
  /// area itself (`wuiHandlesSafeArea`) and touches an edge of it is extended
  /// to the bounds on that edge, so a scroll surface beside a backdrop reaches
  /// the chrome and insets its own content, while the backdrop stays inside.
  private func performLayout() {
    guard !childViews.isEmpty else { return }

    let safeRect = wuiSafeAreaRect
    // Placed by a Rust parent: the proposal it selected. Natively hosted
    // (root content, controller-hosted views): the boundary offer for the
    // rect this container fills — the only place a proposal is built from
    // bounds.
    let proposal = selectedProposal ?? WuiProposalSize(size: safeRect.size)
    let placements = bridge.placements(
      layout: wuiLayout,
      bounds: safeRect,
      proposal: proposal,
      children: subViewCache()
    )

    precondition(
      placements.count == childViews.count,
      "WuiFixedContainer layout returned \(placements.count) placements for \(childViews.count) children"
    )
    for (index, pair) in zip(childViews, placements).enumerated() {
      let (child, placement) = pair
      var frame = placement.frame
      precondition(
        frame.isValidForLayout,
        "WuiFixedContainer received an invalid layout rect for child \(index): \(frame)"
      )

      if wuiHandlesSafeArea(child) {
        frame = Self.extended(frame, touching: safeRect, to: bounds)
      }

      #if canImport(AppKit)
        // Convert to AppKit coordinate system if not flipped
        if !isFlipped {
          frame.origin.y = bounds.height - frame.origin.y - frame.height
        }
      #endif

      // The negotiated proposal must land before the frame: a container child
      // that lays out on the frame change already holds its selected
      // proposal, and a proposal change alone still marks it for relayout.
      child.setPlacementProposal(placement.proposal)
      #if canImport(UIKit)
        child.frame = pixelAligned(frame)
      #elseif canImport(AppKit)
        // A non-safe-area child inside a full-bounds container is clip-wrapped
        // so its paint cannot enter the window's chrome region.
        wuiPlacedContent(child, at: pixelAligned(frame), in: self)
      #endif
    }
  }

  /// `frame` grown to `bounds` on every edge where it touches `safeRect`.
  private static func extended(_ frame: CGRect, touching safeRect: CGRect, to bounds: CGRect)
    -> CGRect
  {
    var result = frame
    if abs(frame.minX - safeRect.minX) < 0.5 {
      result.origin.x = bounds.minX
      result.size.width += frame.minX - bounds.minX
    }
    if abs(frame.maxX - safeRect.maxX) < 0.5 {
      result.size.width += bounds.maxX - frame.maxX
    }
    if abs(frame.minY - safeRect.minY) < 0.5 {
      result.origin.y = bounds.minY
      result.size.height += frame.minY - bounds.minY
    }
    if abs(frame.maxY - safeRect.maxY) < 0.5 {
      result.size.height += bounds.maxY - frame.maxY
    }
    return result
  }

  // MARK: - Child Management

  func setChildren(_ newChildren: [WuiAnyView]) {
    for child in childViews {
      #if canImport(AppKit)
        // A clip-wrapped child leaves with its wrapper.
        if let clip = child.superview as? WuiSafeAreaClipView {
          clip.removeFromSuperview()
          continue
        }
      #endif
      child.removeFromSuperview()
    }

    childViews = newChildren
    cachedSubViews = nil
    for child in newChildren {
      child.translatesAutoresizingMaskIntoConstraints = true
      addSubview(child)
    }

    #if canImport(UIKit)
      setNeedsLayout()
    #elseif canImport(AppKit)
      needsLayout = true
    #endif
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
}

/// A stack answers content questions — a bar's title text, a row's navigation
/// link — with its base layer: the window composes overlay layers (snackbars,
/// dialogs) above the content, and a layer stacked above the content is not
/// what the stack is about.
extension WuiFixedContainer: WuiPrimaryContentProviding {
  var wuiPrimaryContent: PlatformView? { childViews.first }
}

#if canImport(UIKit)
  /// The bars follow whichever child scrolls, not the base layer.
  extension WuiFixedContainer: WuiScrollSurfaceProviding {
    var wuiScrollSurfaceCandidates: [PlatformView] { childViews }
  }
#endif
