#if canImport(UIKit)
  import UIKit

  extension UIView {
    /// The view controller nearest above this view in the responder chain.
    @MainActor
    var wuiAncestorViewController: UIViewController? {
      var responder: UIResponder? = next
      while let current = responder {
        if let controller = current as? UIViewController {
          return controller
        }
        responder = current.next
      }
      return nil
    }

    /// Embeds `controller` in the window's view-controller hierarchy — and its
    /// view in this view — or removes the relationship when this view has left
    /// the window.
    ///
    /// WaterUI's layout engine owns view frames, but UIKit still requires the
    /// controller relationship: without a parent, a container controller
    /// (`UITabBarController`, `UINavigationController`, `UISplitViewController`)
    /// never receives safe-area or trait propagation, its bars are not
    /// coordinated with the content scroll view (large titles stay collapsed,
    /// bottom bars land under sibling bars), and appearance callbacks fire from
    /// window attachment alone. The order is UIKit's embedding contract:
    /// `addChild`, then attach the view, then `didMove(toParent:)` — a view
    /// attached before its controller has a parent runs its first bar layout
    /// unparented, and that collapsed state is never recomputed. Call this from
    /// `didMoveToWindow` and lay the view out in `layoutSubviews` as usual.
    @MainActor
    func wuiSyncControllerHierarchy(of controller: UIViewController) {
      guard window != nil else {
        if controller.parent != nil {
          controller.willMove(toParent: nil)
          controller.removeFromParent()
        }
        return
      }
      guard let ancestor = wuiAncestorViewController, controller.parent !== ancestor else {
        return
      }
      ancestor.addChild(controller)
      if controller.view.superview !== self {
        controller.view.translatesAutoresizingMaskIntoConstraints = true
        controller.view.frame = bounds
        addSubview(controller.view)
      }
      controller.didMove(toParent: ancestor)
      setNeedsLayout()
    }
  }
#endif
