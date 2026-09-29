@_exported import CWaterUI
import QuartzCore

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

/// The dynamic-range support layer the remaining Swift components still
/// call. `WuiDynamicRange` itself moved to Rust; these helpers are the
/// shared propagation/resolve logic its callers keep using.
///
/// Mode tags are stored as `NSNumber` (1 = high, 0 = standard) under the
/// `dev.waterui.dynamicRangeMode` selector key so tags written here and
/// tags written by the Rust `dynamic_range` leaf resolve identically on
/// both sides.
@MainActor
enum WuiDynamicRangeMode {
  case standard
  case high
}

private func dynamicRangeAssociationKey() -> UnsafeRawPointer {
  let selector = NSSelectorFromString("dev.waterui.dynamicRangeMode")
  return unsafeBitCast(selector, to: UnsafeRawPointer.self)
}

private func setDynamicRangeTag(_ mode: WuiDynamicRangeMode, on object: AnyObject) {
  objc_setAssociatedObject(
    object,
    dynamicRangeAssociationKey(),
    NSNumber(value: mode == .high),
    .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
}

private func dynamicRangeTag(of object: AnyObject) -> WuiDynamicRangeMode? {
  guard let number = objc_getAssociatedObject(object, dynamicRangeAssociationKey()) as? NSNumber
  else { return nil }
  return number.boolValue ? .high : .standard
}

@MainActor
func applyDynamicRange(_ mode: WuiDynamicRangeMode, to layer: CALayer?) {
  guard let layer else { return }

  // Keep explicit nested overrides stable: if a sublayer already carries its own mode,
  // preserve that local mode and propagate from there.
  let localMode = dynamicRangeTag(of: layer) ?? mode
  setDynamicRangeTag(localMode, on: layer)

  layer.preferredDynamicRange = (localMode == .high) ? .high : .standard

  if let sublayers = layer.sublayers {
    for sublayer in sublayers {
      applyDynamicRange(localMode, to: sublayer)
    }
  }
}

@MainActor
func applyDynamicRange(_ mode: WuiDynamicRangeMode, to view: PlatformView) {
  setDynamicRangeTag(mode, on: view)
  #if canImport(AppKit)
    view.wantsLayer = true
    guard let layer = view.layer else {
      fatalError("AppKit failed to create the requested backing layer")
    }
  #elseif canImport(UIKit)
    let layer = view.layer
  #endif
  setDynamicRangeTag(mode, on: layer)
  layer.preferredDynamicRange = (mode == .high) ? .high : .standard
  for sublayer in layer.sublayers ?? [] {
    applyDynamicRange(mode, to: sublayer)
  }
}

@MainActor
private func resolveDynamicRangeOverride(startingAt view: PlatformView?) -> WuiDynamicRangeMode? {
  var current = view
  while let node = current {
    if let tagged = dynamicRangeTag(of: node) {
      return tagged
    }
    current = node.superview
  }
  return nil
}

@MainActor
private func resolveDisplayDynamicRange(for view: PlatformView) -> WuiDynamicRangeMode? {
  #if canImport(UIKit)
    guard let screen = view.window?.windowScene?.screen else { return nil }
    return resolveDynamicRange(for: screen)
  #elseif canImport(AppKit)
    guard let screen = view.window?.screen else { return nil }
    return resolveDynamicRange(for: screen)
  #endif
}

#if canImport(UIKit)
  @MainActor
  func resolveDynamicRange(for screen: UIScreen) -> WuiDynamicRangeMode {
    screen.potentialEDRHeadroom > 1 ? .high : .standard
  }
#elseif canImport(AppKit)
  @MainActor
  func resolveDynamicRange(for screen: NSScreen) -> WuiDynamicRangeMode {
    screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1 ? .high : .standard
  }
#endif

@MainActor
private func resolveDynamicRange(
  for view: PlatformView,
  overrideStartingAt overrideOrigin: PlatformView?
) -> WuiDynamicRangeMode? {
  resolveDynamicRangeOverride(startingAt: overrideOrigin)
    ?? resolveDisplayDynamicRange(for: view)
}

@MainActor
func resolveDynamicRange(for view: PlatformView) -> WuiDynamicRangeMode? {
  resolveDynamicRange(for: view, overrideStartingAt: view)
}

@MainActor
func requireInheritedDynamicRange(for view: PlatformView) -> WuiDynamicRangeMode {
  guard let mode = resolveDynamicRange(for: view, overrideStartingAt: view.superview) else {
    fatalError("Dynamic range resolution requires a view attached to a display")
  }
  return mode
}

@MainActor
func applyResolvedDynamicRange(to layer: CALayer?, for view: PlatformView) {
  guard let mode = resolveDynamicRange(for: view) else { return }
  applyDynamicRange(mode, to: layer)
}
