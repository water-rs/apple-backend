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
      return rect.isNull ? CGRect(origin: bounds.origin, size: .zero) : rect
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
