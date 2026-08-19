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

  private(set) var stretchAxis: WuiStretchAxis

  private var wuiLayout: WuiLayout
  private var childViews: [WuiAnyView]
  private var cachedSubViews: CachedSubViewArray?
  private let bridge = NativeLayoutBridge()

  // MARK: - WuiComponent Init

  convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
    let stretchAxis = WuiStretchAxis(waterui_view_stretch_axis(anyview))
    let container: CWaterUI.WuiFixedContainer = waterui_force_as_fixed_container(anyview)
    let layout = WuiLayout(inner: container.layout!)
    let pointerArray = WuiArray<OpaquePointer>(container.contents)
    let childViews = pointerArray.map {
      WuiAnyView(anyview: $0, env: env)
    }
    self.init(stretchAxis: stretchAxis, layout: layout, children: childViews)
  }

  // MARK: - Designated Init

  init(stretchAxis: WuiStretchAxis, layout: WuiLayout, children: [WuiAnyView]) {
    self.stretchAxis = stretchAxis
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

  private func performLayout() {
    guard !childViews.isEmpty else { return }

    let rects = bridge.placements(
      layout: wuiLayout,
      bounds: bounds,
      children: subViewCache()
    )

    precondition(
      rects.count == childViews.count,
      "WuiFixedContainer layout returned \(rects.count) placements for \(childViews.count) children"
    )
    for (index, pair) in zip(childViews, rects).enumerated() {
      let (child, rect) = pair
      var frame = rect
      precondition(
        frame.isValidForLayout,
        "WuiFixedContainer received an invalid layout rect for child \(index): \(frame)"
      )

      #if canImport(AppKit)
        // Convert to AppKit coordinate system if not flipped
        if !isFlipped {
          frame.origin.y = bounds.height - frame.origin.y - frame.height
        }
      #endif

      child.frame = frame
    }
  }

  // MARK: - Child Management

  func setChildren(_ newChildren: [WuiAnyView]) {
    for child in childViews {
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

/// A stack answers window-root questions with its base layer: the window
/// composes overlay layers (snackbars, dialogs) above the content, and a layer
/// stacked above the content never changes how the window insets it.
extension WuiFixedContainer: WuiPrimaryContentProviding {
  var wuiPrimaryContent: PlatformView? { childViews.first }
}
