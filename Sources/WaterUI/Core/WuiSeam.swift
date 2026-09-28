//
//  WuiSeam.swift
//
//  The Swift half of the Rust/Swift coexistence seam (`src/seam.rs` in the
//  `waterui-apple` crate). The wire structs below are byte-for-byte the
//  `repr(C)` declarations the Rust side exports — the same field order, the
//  same packing — so the two sides exchange them without a translation layer.
//
//  Direction: `waterui_swift_render` carries a view the Rust dispatcher does
//  not claim INTO the fallback; `waterui_apple_render` (declared here,
//  defined in Rust) carries one the fallback does not claim the other way.
//  Neither may re-enter the other on a miss — the seam cannot ping-pong.

import CWaterUI
import Foundation

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

// MARK: - Wire types

/// `WateruiProposalSize` on the wire: one `f32` per axis, `NaN` unspecified.
typealias WateruiProposalSize = CWaterUI.WateruiProposalSize

/// `WateruiSize` on the wire.
typealias WateruiSize = CWaterUI.WateruiSize

/// `WateruiPoint` on the wire.
typealias WateruiPoint = CWaterUI.WateruiPoint

/// `WateruiRect` on the wire.
typealias WateruiRect = CWaterUI.WateruiRect

/// `WateruiTypeId` on the wire — the FNV-1a-128 pair both sides share.
typealias WateruiTypeId = CWaterUI.WateruiTypeId

/// A guide on the wire: an alignment tag plus its offset. The horizontal and
/// vertical variants share one layout (`u8` tag, `f32` value), so the
/// horizontal name stands for both.
typealias WateruiGuide = CWaterUI.WateruiHorizontalGuide

/// An owned array on the wire: allocation, length, capacity and its free
/// function. The producer allocates however it chooses and must free exactly
/// that allocation when `free` runs. A null `data` array is empty.
typealias WateruiOwnedArray = CWaterUI.WateruiOwnedArray

/// `ViewDimensions` on the wire.
typealias WateruiViewDimensions = CWaterUI.WateruiViewDimensions

/// A leaf's layout face: a context pointer and one callback per question
/// the parent asks. The query callbacks are live reads — a leaf whose
/// stretch axis or emptiness changes answers the new value on the next
/// call. `drop` runs once, when the leaf's owner lets go; the view is
/// retained and released separately from `context`.
typealias WateruiSubView = CWaterUI.WateruiSubView

/// A leaf crossing the seam in either direction, passed by value: `view` is
/// +1 retained and owned by the receiver (`takeRetainedValue` / Rust's
/// `Retained::from_raw`), or nil for "not claimed" — in which case `subview`
/// callbacks are no-ops.
typealias WateruiLeaf = CWaterUI.WateruiLeaf

/// The leaf a direction answers when the view is unclaimed: a nil view with
/// no-op callbacks, so the receiver can drop it without a branch.
private func unclaimedLeaf() -> WateruiLeaf {
  WateruiLeaf(
    view: nil,
    subview: WateruiSubView(
      context: nil,
      measure: { _, _ in
        WateruiViewDimensions(
          size: WateruiSize(width: 0, height: 0),
          horizontal_guides: WateruiOwnedArray(data: nil, len: 0, cap: 0, free: nil),
          vertical_guides: WateruiOwnedArray(data: nil, len: 0, cap: 0, free: nil)
        )
      },
      place: { _, _ in },
      stretch_axis: { _ in 0 },
      priority: { _ in 0 },
      is_empty: { _ in true },
      drop: { _ in }
    ))
}

// MARK: - Rust-side entry points

/// Whether the erased view is a `Native<T>`/`Metadata<T>` wrapper — the
/// types whose `body()` panics instead of expanding. The Swift walk calls
/// this before `waterui_view_body`, mirroring the Rust dispatcher's order.
/// Borrows `view`.
@_silgen_name("waterui_apple_needs_fallback")
func wateruiAppleNeedsFallback(_ view: OpaquePointer) -> Bool

/// Renders `view` through the Rust dispatcher: claims a registered type or
/// expands composers until a leaf is reached. Consumes both pointers. A nil
/// `view` on the answered leaf means Rust does not claim it either.
@_silgen_name("waterui_apple_render")
func wateruiAppleRender(
  _ view: OpaquePointer, _ env: OpaquePointer
) -> WateruiLeaf

// MARK: - The shared resolve walk

/// The view-tree walk both `WuiAnyView.resolve` and `waterui_swift_render`
/// run: the component registry claims a view by id first; a `Native` /
/// `Metadata` wrapper whose id is unregistered crosses to the Rust
/// dispatcher (its `body()` panics, so it must not be expanded); anything
/// else expands through `body()` and the walk repeats. `anyview` is consumed
/// by whichever step ends the walk.
@MainActor
func wuiSeamResolve(anyview: OpaquePointer, env: WuiEnvironment) -> any WuiComponent {
  registerBuiltinComponentsIfNeeded()
  var current = anyview
  while true {
    let viewId = WuiViewId(waterui_view_id(current))
    if let factory = componentRegistry[viewId] {
      return factory(current, env)
    }
    if wateruiAppleNeedsFallback(current) {
      return WuiRustLeaf(anyview: current, env: env)
    }
    current = waterui_view_body(current, env.inner)
  }
}

// MARK: - WuiRustLeaf: a Rust-produced leaf as a WuiComponent

/// The view a leaf produced by `waterui_apple_render` occupies inside the
/// fallback's view hierarchy: it embeds the leaf's platform view and measures
/// through the leaf's `subview` face.
///
/// The component owns the leaf: `deinit` runs the wire `drop` on the subview
/// context and releases the retained platform view.
@MainActor
final class WuiRustLeaf: PlatformView, WuiComponent {
  static var rawId: CWaterUI.WuiTypeId {
    // A rust leaf answers the id of the view it wrapped — unused by the
    // registry, which never looks this type up; `resolve` constructs it
    // directly.
    fatalError("WuiRustLeaf is constructed by the seam, not the registry")
  }

  private let leaf: WateruiLeaf
  private let leafView: PlatformView
  private let leafEnv: WuiEnvironment

  required init(anyview: OpaquePointer, env: WuiEnvironment) {
    leafEnv = env
    guard let envClone = waterui_clone_env(env.inner)
    else {
      fatalError("a view crossed the seam and its environment could not be cloned")
    }
    leaf = wateruiAppleRender(anyview, envClone)
    guard let viewPtr = leaf.view else {
      fatalError("a view crossed the seam and Rust did not claim it")
    }
    // The leaf's view arrives +1; ARC takes ownership here.
    #if canImport(UIKit)
      leafView = Unmanaged<UIView>.fromOpaque(viewPtr).takeRetainedValue()
    #else
      leafView = Unmanaged<NSView>.fromOpaque(viewPtr).takeRetainedValue()
    #endif
    super.init(frame: .zero)
    addSubview(leafView)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  var stretchAxis: WuiStretchAxis {
    WuiStretchAxis(
      rawValue: UInt32(leaf.subview.stretch_axis(leaf.subview.context))
    ) ?? .none
  }

  /// The leaf's own `is_empty` answer, consulted by the `rendersNothing`
  /// extension — its generic subview walk cannot see inside a Rust leaf.
  var isEmptyLeaf: Bool {
    leaf.subview.is_empty(leaf.subview.context)
  }

  func layoutPriority() -> Int32 {
    leaf.subview.priority(leaf.subview.context)
  }

  /// The proposal a container selected on this leaf reaches the Rust leaf's
  /// `place` callback.
  func setPlacementProposal(_ proposal: WuiProposalSize) {
    leaf.subview.place(
      leaf.subview.context,
      WateruiProposalSize(width: proposal.width ?? .nan, height: proposal.height ?? .nan)
    )
  }

  func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
    measure(proposal).size.cgSize
  }

  func measure(_ proposal: WuiProposalSize) -> WuiViewDimensions {
    let dimensions = leaf.subview.measure(
      leaf.subview.context,
      WateruiProposalSize(width: proposal.width ?? .nan, height: proposal.height ?? .nan)
    )
    return unpackDimensions(dimensions)
  }

  /// Drains the wire dimension packet into Swift values, freeing its arrays.
  private func unpackDimensions(_ raw: WateruiViewDimensions) -> WuiViewDimensions {
    var horizontalGuides: [WuiHorizontalGuide] = []
    var verticalGuides: [WuiVerticalGuide] = []
    if let data = raw.horizontal_guides.data, raw.horizontal_guides.len > 0 {
      let guides = UnsafeMutableBufferPointer(
        start: data.assumingMemoryBound(to: WateruiGuide.self),
        count: Int(raw.horizontal_guides.len)
      )
      horizontalGuides = guides.map {
        WuiHorizontalGuide(
          CWaterUI.WuiHorizontalGuide(
            alignment: horizontalAlignment($0.alignment), value: $0.value))
      }
    }
    if let data = raw.vertical_guides.data, raw.vertical_guides.len > 0 {
      let guides = UnsafeMutableBufferPointer(
        start: data.assumingMemoryBound(to: WateruiGuide.self),
        count: Int(raw.vertical_guides.len)
      )
      verticalGuides = guides.map {
        WuiVerticalGuide(
          CWaterUI.WuiVerticalGuide(
            alignment: verticalAlignment($0.alignment), value: $0.value))
      }
    }
    raw.horizontal_guides.free?(
      raw.horizontal_guides.data,
      raw.horizontal_guides.len,
      raw.horizontal_guides.cap)
    raw.vertical_guides.free?(
      raw.vertical_guides.data,
      raw.vertical_guides.len,
      raw.vertical_guides.cap)
    return WuiViewDimensions(
      size: CGSize(width: CGFloat(raw.size.width), height: CGFloat(raw.size.height)),
      horizontalGuides: horizontalGuides,
      verticalGuides: verticalGuides
    )
  }

  private func horizontalAlignment(_ tag: UInt8) -> CWaterUI.WuiHorizontalAlignment {
    switch tag {
    case 0: return WuiHorizontalAlignment_Leading
    case 1: return WuiHorizontalAlignment_Center
    case 2: return WuiHorizontalAlignment_Trailing
    default: return WuiHorizontalAlignment_Leading
    }
  }

  private func verticalAlignment(_ tag: UInt8) -> CWaterUI.WuiVerticalAlignment {
    switch tag {
    case 0: return WuiVerticalAlignment_Top
    case 1: return WuiVerticalAlignment_Center
    case 2: return WuiVerticalAlignment_Bottom
    case 3: return WuiVerticalAlignment_FirstBaseline
    case 4: return WuiVerticalAlignment_LastBaseline
    default: return WuiVerticalAlignment_Top
    }
  }

  #if canImport(AppKit)
    nonisolated override var isFlipped: Bool { true }
  #endif

  #if canImport(UIKit)
    override func layoutSubviews() {
      super.layoutSubviews()
      leafView.frame = bounds
    }
  #else
    override func layout() {
      super.layout()
      leafView.frame = bounds
    }
  #endif

  deinit {
    // The view is ARC-owned since `takeRetainedValue`; the leaf contract
    // releases the subview context once, here.
    MainActor.assumeIsolated {
      leaf.subview.drop(leaf.subview.context)
    }
  }
}

// MARK: - Leaf construction

/// What a Swift leaf's `measure`/`drop` see: the resolved component, retained
/// for the leaf's life.
@MainActor
private final class SwiftLeafContext {
  let component: any WuiComponent
  init(_ component: any WuiComponent) {
    self.component = component
  }
}

/// The wire `measure` for a Swift leaf: reads the component out of `context`
/// and converts both directions of the layout packet.
/// Carries a wire value out of `assumeIsolated`: the packet is built on the
/// main actor and consumed immediately by the calling C function — it never
/// actually crosses a concurrency boundary.
private struct WirePacket<T>: @unchecked Sendable {
  let value: T
}

private let swiftMeasure:
  @convention(c) (UnsafeMutableRawPointer?, WateruiProposalSize) -> WateruiViewDimensions = {
    context, proposal in
    let contextBits = UInt(bitPattern: context)
    let (width, height) = (proposal.width, proposal.height)
    return MainActor.assumeIsolated {
      guard let context = UnsafeMutableRawPointer(bitPattern: contextBits) else {
        fatalError("seam measure called with a null context")
      }
      let leaf = Unmanaged<SwiftLeafContext>.fromOpaque(context).takeUnretainedValue()
      let measured = leaf.component.measure(
        WuiProposalSize(
          width: width.isNaN ? nil : width,
          height: height.isNaN ? nil : height
        )
      )
      return WirePacket(value: packDimensions(measured))
    }
    .value
  }

/// The wire `drop` for a Swift leaf: releases the retained context once.
private let swiftDrop: @convention(c) (UnsafeMutableRawPointer?) -> Void = { context in
  guard let context else { return }
  Unmanaged<SwiftLeafContext>.fromOpaque(context).release()
}

/// The wire `place` for a Swift leaf: delivers the placement proposal a
/// container selected — `WuiComponent.setPlacementProposal`.
private let swiftPlace: @convention(c) (UnsafeMutableRawPointer?, WateruiProposalSize) -> Void = {
  context, proposal in
  let contextBits = UInt(bitPattern: context)
  let (width, height) = (proposal.width, proposal.height)
  MainActor.assumeIsolated {
    guard let context = UnsafeMutableRawPointer(bitPattern: contextBits) else { return }
    let leaf = Unmanaged<SwiftLeafContext>.fromOpaque(context).takeUnretainedValue()
    leaf.component.setPlacementProposal(
      WuiProposalSize(
        width: width.isNaN ? nil : width,
        height: height.isNaN ? nil : height
      ))
  }
}

/// The wire `stretch_axis` for a Swift leaf: the live component answer.
private let swiftStretchAxis: @convention(c) (UnsafeMutableRawPointer?) -> UInt8 = { context in
  let contextBits = UInt(bitPattern: context)
  return MainActor.assumeIsolated {
    guard let context = UnsafeMutableRawPointer(bitPattern: contextBits) else { return 0 }
    let leaf = Unmanaged<SwiftLeafContext>.fromOpaque(context).takeUnretainedValue()
    return stretchAxisTag(leaf.component.stretchAxis)
  }
}

/// The wire `priority` for a Swift leaf: the live component answer.
private let swiftPriority: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { context in
  let contextBits = UInt(bitPattern: context)
  return MainActor.assumeIsolated {
    guard let context = UnsafeMutableRawPointer(bitPattern: contextBits) else { return 0 }
    let leaf = Unmanaged<SwiftLeafContext>.fromOpaque(context).takeUnretainedValue()
    return leaf.component.layoutPriority()
  }
}

/// The wire `is_empty` for a Swift leaf: the live component answer.
private let swiftIsEmpty: @convention(c) (UnsafeMutableRawPointer?) -> Bool = { context in
  let contextBits = UInt(bitPattern: context)
  return MainActor.assumeIsolated {
    guard let context = UnsafeMutableRawPointer(bitPattern: contextBits) else { return true }
    let leaf = Unmanaged<SwiftLeafContext>.fromOpaque(context).takeUnretainedValue()
    return leaf.component.rendersNothing
  }
}

/// Packages the leaf `component` produces for the seam: the view goes +1 to
/// the receiver (`takeRetainedValue`), the layout context is retained
/// separately, per the leaf contract.
@MainActor
private func packLeaf(_ component: any WuiComponent) -> WateruiLeaf {
  WateruiLeaf(
    view: Unmanaged.passRetained(component as AnyObject).toOpaque(),
    subview: WateruiSubView(
      context: Unmanaged.passRetained(SwiftLeafContext(component)).toOpaque(),
      measure: swiftMeasure,
      place: swiftPlace,
      stretch_axis: swiftStretchAxis,
      priority: swiftPriority,
      is_empty: swiftIsEmpty,
      drop: swiftDrop
    ))
}

/// The wire `stretch_axis` tag for a `WuiStretchAxis`.
private func stretchAxisTag(_ axis: WuiStretchAxis) -> UInt8 {
  UInt8(axis.rawValue)
}

/// Allocates an owned guide array on the wire.
private func packGuides<T>(_ guides: [T], pack: (T) -> WateruiGuide) -> WateruiOwnedArray {
  guard !guides.isEmpty else {
    return WateruiOwnedArray(data: nil, len: 0, cap: 0, free: nil)
  }
  let count = guides.count
  let buffer = UnsafeMutablePointer<WateruiGuide>.allocate(capacity: count)
  for (index, guide) in guides.enumerated() {
    buffer[index] = pack(guide)
  }
  return WateruiOwnedArray(
    data: UnsafeMutableRawPointer(buffer),
    len: UInt(count),
    cap: UInt(count),
    free: { data, len, _ in
      guard let data else { return }
      let typed = data.assumingMemoryBound(to: WateruiGuide.self)
      typed.deinitialize(count: Int(len))
      typed.deallocate()
    }
  )
}

/// The wire answer to a measure call: size plus both guide arrays.
private func packDimensions(_ dimensions: WuiViewDimensions) -> WateruiViewDimensions {
  WateruiViewDimensions(
    size: WateruiSize(width: dimensions.size.width, height: dimensions.size.height),
    horizontal_guides: packGuides(dimensions.horizontalGuides) {
      WateruiGuide(alignment: horizontalAlignmentTag($0.alignment), value: $0.value)
    },
    vertical_guides: packGuides(dimensions.verticalGuides) {
      WateruiGuide(alignment: verticalAlignmentTag($0.alignment), value: $0.value)
    }
  )
}

private func horizontalAlignmentTag(_ alignment: CWaterUI.WuiHorizontalAlignment) -> UInt8 {
  switch alignment {
  case WuiHorizontalAlignment_Leading: return 0
  case WuiHorizontalAlignment_Center: return 1
  case WuiHorizontalAlignment_Trailing: return 2
  default: fatalError("unknown horizontal alignment \(alignment)")
  }
}

private func verticalAlignmentTag(_ alignment: CWaterUI.WuiVerticalAlignment) -> UInt8 {
  switch alignment {
  case WuiVerticalAlignment_Top: return 0
  case WuiVerticalAlignment_Center: return 1
  case WuiVerticalAlignment_Bottom: return 2
  case WuiVerticalAlignment_FirstBaseline: return 3
  case WuiVerticalAlignment_LastBaseline: return 4
  default: fatalError("unknown vertical alignment \(alignment)")
  }
}

// MARK: - The seam: Rust → Swift direction's landing sites

/// The fallback's render entry: `view` and `env` are `Box<AnyView>` /
/// `Box<Environment>` allocations owned by this call; the leaf it answers is
/// owned by the caller, its `view` +1.
@_cdecl("waterui_swift_render")
@MainActor
func wateruiSwiftRender(
  _ view: OpaquePointer?, _ env: OpaquePointer?
) -> WateruiLeaf {
  guard let view, let env else { return unclaimedLeaf() }
  return packLeaf(wuiSeamResolve(anyview: view, env: WuiEnvironment(env)))
}

/// The fallback's environment-prep entry: the GPU runtime — whose creation
/// is asynchronous — plus the services the fallback's components read. `env`
/// is borrowed for the call; `callback` runs on the main thread once
/// everything is installed.
@_cdecl("waterui_swift_prepare_env")
func wateruiSwiftPrepareEnv(
  _ env: OpaquePointer?,
  context: UnsafeMutableRawPointer?,
  callback: @convention(c) (UnsafeMutableRawPointer?) -> Void
) {
  guard let env else {
    fatalError("waterui_swift_prepare_env called with a null environment")
  }
  let envBits = UInt(bitPattern: env)
  let contextBits = UInt(bitPattern: context)
  let callbackBits = unsafeBitCast(callback, to: UInt.self)
  Task { @MainActor in
    guard let env = OpaquePointer(bitPattern: envBits) else {
      fatalError("waterui_swift_prepare_env lost its environment pointer")
    }
    let context = UnsafeMutableRawPointer(bitPattern: contextBits)
    let callback = unsafeBitCast(
      callbackBits,
      to: (@convention(c) (UnsafeMutableRawPointer?) -> Void).self)
    // The environment the fallback's services retain is a clone: the
    // caller's box is borrowed for this call only.
    guard let cloned = waterui_clone_env(env) else {
      fatalError("waterui_clone_env answered null")
    }
    let environment = WuiEnvironment(cloned)
    #if !WATERUI_NO_GPU
      let gpuRuntime = await createWuiGpuRuntime()
      waterui_env_install_gpu_runtime(env, gpuRuntime)
    #endif
    let nativeServices = WuiNativeServices()
    nativeServices.environment = environment
    #if WATERUI_WEBVIEW
      installWebViewController(env: env)
    #endif
    installWindowManager(env: env, services: nativeServices)
    installViewRenderer(env: env, services: nativeServices)
    callback(context)
  }
}

/// Runs `callback` on the main thread once `view` — a fallback-produced
/// platform view — reports its first frame ready. The view is borrowed.
@_cdecl("waterui_swift_when_ready")
func wateruiSwiftWhenReady(
  _ view: UnsafeMutableRawPointer?,
  context: UnsafeMutableRawPointer?,
  callback: @convention(c) (UnsafeMutableRawPointer?) -> Void
) {
  guard let view else {
    callback(context)
    return
  }
  let viewBits = UInt(bitPattern: view)
  let contextBits = UInt(bitPattern: context)
  let callbackBits = unsafeBitCast(callback, to: UInt.self)
  Task { @MainActor in
    guard let view = UnsafeMutableRawPointer(bitPattern: viewBits) else {
      fatalError("waterui_swift_when_ready lost its view pointer")
    }
    let context = UnsafeMutableRawPointer(bitPattern: contextBits)
    let callback = unsafeBitCast(
      callbackBits,
      to: (@convention(c) (UnsafeMutableRawPointer?) -> Void).self)
    #if canImport(UIKit)
      let platformView = Unmanaged<UIView>.fromOpaque(view).takeUnretainedValue()
    #else
      let platformView = Unmanaged<NSView>.fromOpaque(view).takeUnretainedValue()
    #endif
    if let host = platformView as? WuiAnyView {
      await host.ready()
    }
    callback(context)
  }
}

#if canImport(AppKit)
  /// Attaches the window's toolbar: `content` renders as the fallback's
  /// toolbar host on `window`. Both `content` and `env` are consumed.
  @_cdecl("waterui_swift_install_toolbar")
  @MainActor
  func wateruiSwiftInstallToolbar(
    _ content: OpaquePointer?, _ env: OpaquePointer?, _ window: UnsafeMutableRawPointer?
  ) {
    guard let content, let env, let window else {
      fatalError("waterui_swift_install_toolbar called with a null argument")
    }
    let nsWindow = Unmanaged<NSWindow>.fromOpaque(window).takeUnretainedValue()
    WuiWindowToolbar.attached(to: nsWindow)
      .setWindowContent(WuiAnyView(anyview: content, env: WuiEnvironment(env)))
  }
#endif

/// The frame a leaf's platform view takes inside a host of `bounds`, after
/// safe-area rules: `bounds` when the leaf manages its own safe area,
/// otherwise the leaf's safe-area-inset rect. `view` is borrowed.
@_cdecl("waterui_swift_content_frame")
@MainActor
func wateruiSwiftContentFrame(
  _ view: UnsafeMutableRawPointer?, bounds: WateruiRect
) -> WateruiRect {
  guard let view else { return bounds }
  #if canImport(UIKit)
    let platformView = Unmanaged<UIView>.fromOpaque(view).takeUnretainedValue()
  #else
    let platformView = Unmanaged<NSView>.fromOpaque(view).takeUnretainedValue()
  #endif
  let hostBounds = CGRect(
    x: CGFloat(bounds.origin.x), y: CGFloat(bounds.origin.y),
    width: CGFloat(bounds.size.width), height: CGFloat(bounds.size.height)
  )
  let frame = wuiHandlesSafeArea(platformView) ? hostBounds : platformView.wuiSafeAreaRect
  return WateruiRect(
    origin: WateruiPoint(x: Float(frame.origin.x), y: Float(frame.origin.y)),
    size: WateruiSize(width: Float(frame.size.width), height: Float(frame.size.height))
  )
}

#if DEBUG
  /// The identity of every view type the fallback claims, for the seam's
  /// debug-time disjointness check.
  @_cdecl("waterui_swift_claims")
  @MainActor
  func wateruiSwiftClaims() -> WateruiOwnedArray {
    registerBuiltinComponentsIfNeeded()
    let ids = Array(componentRegistry.keys)
    guard !ids.isEmpty else {
      return WateruiOwnedArray(data: nil, len: 0, cap: 0, free: nil)
    }
    let buffer = UnsafeMutablePointer<WateruiTypeId>.allocate(capacity: ids.count)
    for (index, id) in ids.enumerated() {
      buffer[index] = WateruiTypeId(low: id.low, high: id.high)
    }
    return WateruiOwnedArray(
      data: UnsafeMutableRawPointer(buffer),
      len: UInt(ids.count),
      cap: UInt(ids.count),
      free: { data, len, _ in
        guard let data else { return }
        let typed = data.assumingMemoryBound(to: WateruiTypeId.self)
        typed.deinitialize(count: Int(len))
        typed.deallocate()
      }
    )
  }
#endif
