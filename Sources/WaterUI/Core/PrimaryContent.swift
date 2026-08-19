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
