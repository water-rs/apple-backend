#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

/// A view whose platform object already lays its content out against the
/// screen edges itself — a scroll view, a native list, or a UIKit container
/// controller (tabs, navigation stack, split view).
///
/// The window root consults this to decide whether the root content fills the
/// window or is inset to the safe area: platform chrome containers own their
/// bars and insets, so handing them anything less than the whole window
/// letterboxes their chrome away from the screen edges.
@MainActor
protocol WuiSafeAreaManaging {}

/// A view that only wraps or arranges one primary content view.
///
/// Questions about the window root — does it manage its own safe area, what is
/// its content scroll view — descend through these wrappers to the view that
/// actually answers them.
@MainActor
protocol WuiPrimaryContentProviding {
  var wuiPrimaryContent: PlatformView? { get }
}

/// Follows the primary-content chain from `view` down to the first view that
/// either answers for itself ([`WuiSafeAreaManaging`]) or wraps nothing
/// further.
@MainActor
func wuiResolvedPrimaryContent(of view: PlatformView) -> PlatformView {
  var current = view
  while !(current is WuiSafeAreaManaging),
    let next = (current as? WuiPrimaryContentProviding)?.wuiPrimaryContent
  {
    current = next
  }
  return current
}

// The bars that follow a scroll surface — large title, tab bar minimize,
// scroll-edge effects — are UIKit's; AppKit couples nothing to a scroll view.
#if canImport(UIKit)
  /// A view that arranges several children, any of which may be the scroll
  /// surface the surrounding bars follow.
  ///
  /// The primary-content chain stops at a stack's base layer because that layer
  /// decides how the window insets the stack; the bars instead follow whichever
  /// child scrolls, so a stack lists every child here, in stacking order.
  @MainActor
  protocol WuiScrollSurfaceProviding {
    var wuiScrollSurfaceCandidates: [PlatformView] { get }
  }

  /// The scroll surface that drives the bars around `view` — large-title
  /// collapse, the tab bar's minimize behavior, the bars' scroll-edge effects.
  ///
  /// A page composed as a stack of a backdrop and a scroll view scrolls the
  /// scroll view, so the search descends through wrappers by their primary
  /// content and through stacks by every child, and the first scroll surface
  /// found answers. A container that answers for itself, such as a nested
  /// navigation view with its own bar, ends the descent the way it does for
  /// the primary-content chain.
  @MainActor
  func wuiScrollSurface(of view: PlatformView) -> PlatformScrollView? {
    if view is WuiSafeAreaManaging {
      return view as? PlatformScrollView
    }
    let candidates: [PlatformView]
    if let stack = view as? WuiScrollSurfaceProviding {
      candidates = stack.wuiScrollSurfaceCandidates
    } else if let wrapper = view as? WuiPrimaryContentProviding {
      candidates = wrapper.wuiPrimaryContent.map { [$0] } ?? []
    } else {
      candidates = []
    }
    for candidate in candidates {
      if let surface = wuiScrollSurface(of: candidate) {
        return surface
      }
    }
    return nil
  }
#endif

/// Whether `view` lays its own content out against the safe area.
///
/// Platform containers and scroll surfaces ([`WuiSafeAreaManaging`]) own their
/// insets. A stack lays its children out inside its safe area and extends the
/// ones that handle it themselves to the edges they touch. A wrapper answers
/// for its primary content. Everything else — a leaf — is placed inside the
/// safe area by whoever holds it ([`wuiContentFrame(of:in:)`]).
///
/// This is the platform rule: a scroll view reaches the chrome it touches and
/// turns the bar over it into a content inset, while a text or a color beside
/// it stays inside the safe area.
@MainActor
func wuiHandlesSafeArea(_ view: PlatformView) -> Bool {
  if view is WuiSafeAreaManaging || view is WuiFixedContainer {
    return true
  }
  if let wrapper = view as? WuiPrimaryContentProviding, let content = wrapper.wuiPrimaryContent {
    return wuiHandlesSafeArea(content)
  }
  return false
}

extension PlatformView {
  /// The part of the bounds inside the safe area.
  ///
  /// On iOS a `WuiIgnoreSafeArea` — this view or an enclosing one — erases its
  /// edges from the insets its subtree sees, up to the next view that owns
  /// its insets (a scroll surface or chrome container starts afresh). UIKit computes every view's
  /// `safeAreaInsets` from geometry alone, so the erasure is applied here
  /// rather than expected from the platform.
  @MainActor
  var wuiSafeAreaRect: CGRect {
    #if canImport(UIKit)
      var insets = safeAreaInsets
      var ancestor: PlatformView? = self
      while let view = ancestor {
        if let ignoring = view as? WuiIgnoreSafeArea {
          insets = ignoring.erasingIgnoredEdges(from: insets)
        } else if view is WuiSafeAreaManaging {
          break
        }
        ancestor = view.superview
      }
      let rect = bounds.inset(by: insets)
      // `inset(by:)` does not null out a negative result — a view smaller than
      // its insets (e.g. an offscreen snapshot window tinier than the device
      // safe area) would otherwise hand the layout engine a negative rect and
      // trip `clamp(0.0, <negative>)` inside Rust. `rect.width`/`rect.height`
      // cannot see it — they call `CGRectGetWidth`/`CGRectGetHeight`, which
      // return magnitudes — so the check reads the raw `size` fields.
      return rect.isNull || rect.size.width < 0 || rect.size.height < 0
        ? CGRect(origin: bounds.origin, size: .zero) : rect
    #elseif canImport(AppKit)
      safeAreaRect
    #endif
  }
}

/// The frame a wrapper gives its single content view: the whole of its bounds
/// when the content handles the safe area itself, the safe-area part otherwise.
@MainActor
func wuiContentFrame(of content: PlatformView, in host: PlatformView) -> CGRect {
  wuiHandlesSafeArea(content) ? host.bounds : host.wuiSafeAreaRect
}

// MARK: - macOS page column and chrome clip

#if canImport(AppKit)
  /// A view that clips its content to the window's safe area.
  ///
  /// macOS scroll surfaces reach `y0` beneath the titlebar and unified
  /// toolbar, where the `NSScrollPocket` and the toolbar's own material cover
  /// what passes beneath. Everything beside them must stay inside the safe
  /// area — a rule AppKit never enforces, because layer-backed content (an
  /// offset circle, a shadow) paints wherever its layer lands. Hosting the
  /// content in a view masked to the window's safe rect keeps its paint below
  /// the chrome edge: the boundary SwiftUI's hosting enforces on every
  /// non-scroll surface.
  @MainActor
  final class WuiSafeAreaClipView: NSView {
    init() {
      super.init(frame: .zero)
      wantsLayer = true
      layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    nonisolated override var isFlipped: Bool { true }

    /// A clip view is not content: a hit none of its children claim belongs
    /// to whatever is behind it.
    override func hitTest(_ point: NSPoint) -> NSView? {
      let hit = super.hitTest(point)
      return hit === self ? nil : hit
    }
  }

  /// The window's safe-area rect in `host`'s coordinate space — the clip
  /// boundary for content that must not paint under the titlebar and unified
  /// toolbar. `nil` when the window has no chrome region, so nothing needs
  /// clipping.
  @MainActor
  func wuiWindowSafeAreaRect(in host: PlatformView) -> CGRect? {
    guard let contentView = host.window?.contentView else { return nil }
    let rect = contentView.safeAreaRect
    guard rect != contentView.bounds else { return nil }
    return host.convert(rect, from: contentView)
  }

  /// The stretch axis a view claims for the page-column question.
  ///
  /// A scroll view's own axis is `.both` — it fills whatever it is given —
  /// which says nothing about whether its page wants the window's width, so a
  /// scroll answers with its content's axis instead: a `scroll` of hugging
  /// content keeps an intrinsic width while a `scroll` of filling content
  /// stays greedy. A layout container re-asks its layout with those effective
  /// child axes, so a stack holding a scroll answers from what the scroll
  /// wraps rather than the scroll's blanket `.both`. Wrappers forward through
  /// to their content; everything else answers with its own axis.
  @MainActor
  private func wuiEffectiveStretchAxis(_ view: PlatformView) -> WuiStretchAxis {
    var current = view
    while true {
      if let scroll = current as? WuiScroll {
        current = scroll.contentHostView
      } else if let anyView = current as? WuiAnyView,
        let inner = anyView.wuiPrimaryContent
      {
        current = inner
      } else if let component = current as? any WuiComponent,
        isMetadataComponent(component),
        let inner = (component as? WuiPrimaryContentProviding)?.wuiPrimaryContent
      {
        current = inner
      } else {
        break
      }
    }
    if let container = current as? WuiFixedContainer {
      return container.stretchAxis(
        childAxes: container.childViews.map(wuiEffectiveStretchAxis))
    }
    return (current as? any WuiComponent)?.stretchAxis ?? .both
  }

  /// Whether the content a page host places wants the window's full width —
  /// `.none` and `.vertical` keep an intrinsic width, the rest fill.
  @MainActor
  private func wuiPageFillsHorizontally(_ view: PlatformView) -> Bool {
    switch wuiEffectiveStretchAxis(view) {
    case .none, .vertical:
      return false
    case .horizontal, .both, .mainAxis, .crossAxis:
      return true
    }
  }

  /// The frame a macOS page host gives its content — SwiftUI's
  /// `PlatformContainer`: the content's ideal width centred in the window,
  /// filling only when the content stretches horizontally.
  ///
  /// `vertical` carries the host's already-resolved vertical placement —
  /// `wuiContentFrame` where the safe-area rule applies, a bar-relative rect
  /// under an in-content bar — so this function decides only the horizontal
  /// answer. A non-greedy page is centred at its ideal width, bounded by the
  /// window: the column's width is `min(ideal, window width)`, so a page
  /// whose ideal meets or exceeds the window fills it rather than
  /// overflowing symmetrically; a greedy page fills.
  ///
  /// The column only forms when the host spans the window's full content
  /// width; a host inside a split column fills its own column instead.
  @MainActor
  func wuiPageColumnFrame(
    of content: PlatformView, in host: PlatformView, vertical: CGRect
  ) -> CGRect {
    guard let contentView = host.window?.contentView,
      abs(host.bounds.width - contentView.bounds.width) < 0.5,
      !wuiPageFillsHorizontally(content),
      let ideal = (content as? any WuiComponent)?.sizeThatFits(WuiProposalSize()).width,
      ideal.isFinite, ideal > 0
    else { return vertical }
    let width = min(ideal, host.bounds.width)
    return CGRect(
      x: host.bounds.midX - width / 2,
      y: vertical.minY,
      width: width,
      height: vertical.height
    )
  }

  /// `wuiPageColumnFrame` with the safe-area rule as the vertical answer —
  /// the frame a macOS page host gives its page content.
  @MainActor
  func wuiPageColumnFrame(of content: PlatformView, in host: PlatformView) -> CGRect {
    wuiPageColumnFrame(
      of: content, in: host, vertical: wuiContentFrame(of: content, in: host))
  }

  /// The `WuiSafeAreaClipView` hosting `content` inside `host`, preserving the
  /// content's position among the host's subviews.
  @MainActor
  private func wuiClipWrapper(for content: PlatformView, in host: PlatformView)
    -> WuiSafeAreaClipView
  {
    if let clip = content.superview as? WuiSafeAreaClipView { return clip }
    let clip = WuiSafeAreaClipView()
    var order = host.subviews
    if let index = order.firstIndex(of: content) {
      order[index] = clip
    } else {
      order.append(clip)
    }
    clip.addSubview(content)
    host.subviews = order
    return clip
  }

  /// Whether an ancestor `WuiSafeAreaClipView` already masks this subtree —
  /// content inside one needs no clip of its own, the mask covers it.
  @MainActor
  private func wuiInsideSafeAreaClip(_ view: PlatformView) -> Bool {
    sequence(first: view.superview, next: { $0?.superview }).contains {
      $0 is WuiSafeAreaClipView
    }
  }

  /// Places `content` at `frame` inside `host`, enforcing the chrome rule: a
  /// view that manages the safe area is placed directly so its scroll
  /// surfaces reach the titlebar and toolbar, while anything else is hosted
  /// in a `WuiSafeAreaClipView` so layer-backed paint cannot enter the
  /// window's chrome region. Content inside a scroll view is never wrapped —
  /// it scrolls beneath the pocket, which is the scroll surface's own affair
  /// — nor is content already masked by an ancestor clip.
  @MainActor
  func wuiPlacedContent(_ content: PlatformView, at frame: CGRect, in host: PlatformView) {
    guard !wuiHandlesSafeArea(content),
      host.enclosingScrollView == nil,
      !wuiInsideSafeAreaClip(host),
      let safeRect = wuiWindowSafeAreaRect(in: host)
    else {
      if let clip = content.superview as? WuiSafeAreaClipView {
        // The content is placed directly again; its wrapper leaves the tree.
        var order = host.subviews
        if let index = order.firstIndex(of: clip) { order[index] = content }
        host.addSubview(content)
        host.subviews = order
      }
      content.frame = frame
      return
    }
    let clip = wuiClipWrapper(for: content, in: host)
    clip.frame = safeRect
    content.frame = frame.offsetBy(dx: -safeRect.minX, dy: -safeRect.minY)
  }
#endif
