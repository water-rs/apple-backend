import CWaterUI
import Metal
import QuartzCore

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

@MainActor
enum WuiDynamicRangeMode {
  case standard
  case high
}

private func dynamicRangeAssociationKey() -> UnsafeRawPointer {
  let selector = NSSelectorFromString("dev.waterui.dynamicRangeMode")
  return unsafeBitCast(selector, to: UnsafeRawPointer.self)
}

@MainActor
func applyDynamicRange(_ mode: WuiDynamicRangeMode, to layer: CALayer?) {
  guard let layer else { return }

  // Keep explicit nested overrides stable: if a sublayer already carries its own mode,
  // preserve that local mode and propagate from there.
  let localMode =
    (objc_getAssociatedObject(layer, dynamicRangeAssociationKey()) as? WuiDynamicRangeMode)
    ?? mode
  objc_setAssociatedObject(
    layer, dynamicRangeAssociationKey(), localMode, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

  #if canImport(UIKit)
    layer.preferredDynamicRange = (localMode == .high) ? .high : .standard
  #elseif canImport(AppKit)
    layer.preferredDynamicRange = (localMode == .high) ? .high : .standard
  #endif

  if let sublayers = layer.sublayers {
    for sublayer in sublayers {
      applyDynamicRange(localMode, to: sublayer)
    }
  }
}

@MainActor
func applyDynamicRange(_ mode: WuiDynamicRangeMode, to view: PlatformView) {
  objc_setAssociatedObject(
    view, dynamicRangeAssociationKey(), mode, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
  #if canImport(AppKit)
    view.wantsLayer = true
    guard let layer = view.layer else {
      fatalError("AppKit failed to create the requested backing layer")
    }
  #elseif canImport(UIKit)
    let layer = view.layer
  #endif
  objc_setAssociatedObject(
    layer, dynamicRangeAssociationKey(), mode, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
  #if canImport(UIKit)
    layer.preferredDynamicRange = (mode == .high) ? .high : .standard
  #elseif canImport(AppKit)
    layer.preferredDynamicRange = (mode == .high) ? .high : .standard
  #endif
  for sublayer in layer.sublayers ?? [] {
    applyDynamicRange(mode, to: sublayer)
  }
}

@MainActor
private func resolveDynamicRangeOverride(startingAt view: PlatformView?) -> WuiDynamicRangeMode? {
  var current = view
  while let node = current {
    if let tagged = objc_getAssociatedObject(node, dynamicRangeAssociationKey())
      as? WuiDynamicRangeMode
    {
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

@MainActor
func configureMetalLayerDynamicRange(
  _ layer: CAMetalLayer,
  presentationMode: WuiDynamicRangeMode,
  rendererMode: WuiDynamicRangeMode
) {
  precondition(
    presentationMode == .standard || rendererMode == .high,
    "An HDR presentation requires an HDR-capable renderer target"
  )
  objc_setAssociatedObject(
    layer,
    dynamicRangeAssociationKey(),
    presentationMode,
    .OBJC_ASSOCIATION_RETAIN_NONATOMIC
  )
  layer.preferredDynamicRange = presentationMode == .high ? .high : .standard
  switch rendererMode {
  case .high:
    layer.pixelFormat = .rgba16Float
    layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
  case .standard:
    layer.pixelFormat = .bgra8Unorm_srgb
    layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
  }
  layer.wantsExtendedDynamicRangeContent = presentationMode == .high
}

/// Component for Metadata<StandardDynamicRange>.
@MainActor
final class WuiStandardDynamicRange: PlatformView, WuiComponent {
  static var rawId: CWaterUI.WuiTypeId { waterui_metadata_standard_dynamic_range_id() }

  private let contentView: any WuiComponent

  var stretchAxis: WuiStretchAxis {
    contentView.stretchAxis
  }

  required init(anyview: OpaquePointer, env: WuiEnvironment) {
    let metadata = waterui_force_as_metadata_standard_dynamic_range(anyview)

    // Resolve the content
    self.contentView = WuiAnyView.resolve(anyview: metadata.content, env: env)

    super.init(frame: .zero)

    contentView.translatesAutoresizingMaskIntoConstraints = true
    addSubview(contentView)

    applyDynamicRange(.standard, to: self)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func layoutPriority() -> Int32 {
    contentView.layoutPriority()
  }

  func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
    contentView.sizeThatFits(proposal)
  }

  #if canImport(UIKit)
    override func layoutSubviews() {
      super.layoutSubviews()
      contentView.frame = bounds
      applyDynamicRange(.standard, to: self)
    }
  #elseif canImport(AppKit)
    nonisolated override var isFlipped: Bool { true }

    override func layout() {
      super.layout()
      contentView.frame = bounds
      applyDynamicRange(.standard, to: self)
    }
  #endif
}

/// Component for Metadata<HighDynamicRange>.
@MainActor
final class WuiHighDynamicRange: PlatformView, WuiComponent {
  static var rawId: CWaterUI.WuiTypeId { waterui_metadata_high_dynamic_range_id() }

  private let contentView: any WuiComponent

  var stretchAxis: WuiStretchAxis {
    contentView.stretchAxis
  }

  required init(anyview: OpaquePointer, env: WuiEnvironment) {
    let metadata = waterui_force_as_metadata_high_dynamic_range(anyview)

    // Resolve the content
    self.contentView = WuiAnyView.resolve(anyview: metadata.content, env: env)

    super.init(frame: .zero)

    contentView.translatesAutoresizingMaskIntoConstraints = true
    addSubview(contentView)

    applyDynamicRange(.high, to: self)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func layoutPriority() -> Int32 {
    contentView.layoutPriority()
  }

  func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
    contentView.sizeThatFits(proposal)
  }

  #if canImport(UIKit)
    override func layoutSubviews() {
      super.layoutSubviews()
      contentView.frame = bounds
      applyDynamicRange(.high, to: self)
    }
  #elseif canImport(AppKit)
    nonisolated override var isFlipped: Bool { true }

    override func layout() {
      super.layout()
      contentView.frame = bounds
      applyDynamicRange(.high, to: self)
    }
  #endif
}
