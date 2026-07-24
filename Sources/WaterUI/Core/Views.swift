import CWaterUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

/// Manages a collection of WaterUI views from Rust.
@MainActor
final class WuiAnyViews {
  private let inner: OpaquePointer

  init(_ inner: OpaquePointer) {
    self.inner = inner
  }

  var ptr: OpaquePointer { inner }

  @MainActor deinit {
    waterui_drop_anyviews(inner)
  }

  var count: Int {
    Int(waterui_anyviews_len(inner))
  }

  /// Returns IDs in `[start, end)` range.
  func getIds(start: Int, end: Int) -> [Int32] {
    precondition(start >= 0 && start <= end && end <= count, "Invalid WuiAnyViews id range")
    let ids = waterui_anyviews_get_ids_in_range(inner, UInt(start), UInt(end))
    return WuiArray<CWaterUI.WuiId>(ids).map(\.inner)
  }

  func allIds() -> [Int32] {
    getIds(start: 0, end: count)
  }

  func takeRawView(at index: Int) -> OpaquePointer {
    precondition((0..<count).contains(index), "WuiAnyViews index is out of bounds")
    return waterui_anyviews_get_view(inner, UInt(index))!
  }

  /// Returns a WuiAnyView which is already a UIView/NSView.
  func getView(at index: Int, env: WuiEnvironment) -> WuiAnyView {
    WuiAnyView(anyview: takeRawView(at: index), env: env)
  }
}

/// Watches a sub-range `[start, end)` of `WuiAnyViews` IDs.
@MainActor
func watchAnyViewsRangeIds(
  _ anyViews: WuiAnyViews,
  start: Int,
  end: Int,
  _ f: @escaping ([Int32], WuiWatcherMetadata) -> Void
) -> WatcherGuard {
  let data = wrap { (ids: CWaterUI.WuiArray_WuiId, metadata: WuiWatcherMetadata) in
    f(WuiArray<CWaterUI.WuiId>(ids).map(\.inner), metadata)
  }

  let call:
    @convention(c) (UnsafeMutableRawPointer?, CWaterUI.WuiArray_WuiId, OpaquePointer?) -> Void =
      { data, value, metadata in
        callWrapper(data, value, metadata)
      }

  let drop: @convention(c) (UnsafeMutableRawPointer?) -> Void = {
    dropWrapper($0, CWaterUI.WuiArray_WuiId.self)
  }

  precondition(
    start >= 0 && start <= end && (end == .max || end <= anyViews.count),
    "Invalid WuiAnyViews watch range"
  )
  let guardPtr = waterui_anyviews_watch_range(
    anyViews.ptr,
    UInt(start),
    UInt(end),
    data,
    call,
    drop
  )!
  return WatcherGuard(guardPtr)
}

@MainActor
func watchAnyViewsIds(
  _ anyViews: WuiAnyViews,
  _ f: @escaping ([Int32], WuiWatcherMetadata) -> Void
) -> WatcherGuard {
  watchAnyViewsRangeIds(anyViews, start: 0, end: .max, f)
}
