//
//  Watcher.swift
//
//
//  Created by Gemini on 10/6/25.
//

import CWaterUI
import Foundation

@MainActor
final class WatcherGuard {
  private var onCancel: (@MainActor () -> Void)?

  init(_ inner: OpaquePointer) {
    self.onCancel = {
      waterui_drop_box_watcher_guard(inner)
    }
  }

  init(onCancel: @escaping @MainActor () -> Void) {
    self.onCancel = onCancel
  }

  func cancel() {
    let onCancel = onCancel
    self.onCancel = nil
    onCancel?()
  }

  @MainActor deinit {
    cancel()
  }
}

@MainActor
final class WuiWatcherMetadata {
  let inner: OpaquePointer?
  init(_ inner: OpaquePointer?) {
    self.inner = inner
  }

  func getAnimation() -> CWaterUI.WuiAnimation {
    guard let inner else {
      var animation = CWaterUI.WuiAnimation()
      animation.tag = WuiAnimation_None
      return animation
    }
    return waterui_get_animation(inner)
  }

  var animation: Animation? {
    let parsed = parseAnimation(getAnimation())
    if case .none = parsed {
      return nil
    }
    return parsed
  }

  @MainActor deinit {
    if let inner {
      waterui_drop_watcher_metadata(inner)
    }
  }
}

// MARK: - Watcher Implementations
//
// Pattern for implementing Watcher protocol for C-level watcher types:
//
// For value types (Int32, Bool, Double, etc.):
//   1. Create a Wrapper class to hold the Swift closure
//   2. Create C-style call function with matching parameter type
//   3. Create C-style drop function
//   4. Pass data, call, and drop to the C struct initializer
//
// For reference types (OpaquePointer-based):
//   1. Same as value types, but:
//   2. Use (UnsafeRawPointer?, OpaquePointer?, OpaquePointer?) for call signature
//   3. Convert OpaquePointer to Swift type in the call function

final class Wrapper<T> {
  let inner: (T, WuiWatcherMetadata) -> Void
  init(_ inner: @escaping (T, WuiWatcherMetadata) -> Void) { self.inner = inner }
}

private struct WuiWatcherInvocation<T>: @unchecked Sendable {
  let data: UnsafeMutableRawPointer
  let value: T
  let metadata: OpaquePointer?
}

func callWrapper<T>(
  _ data: UnsafeMutableRawPointer?, _ value: T, _ metadata: OpaquePointer?
) {
  precondition(Thread.isMainThread, "WaterUI signal watcher left its owning UI thread")
  guard let data else {
    fatalError("WaterUI watcher invoked with null callback data")
  }
  let invocation = WuiWatcherInvocation(data: data, value: value, metadata: metadata)
  MainActor.assumeIsolated {
    let wrapper = Unmanaged<Wrapper<T>>.fromOpaque(invocation.data).takeUnretainedValue()
    wrapper.inner(invocation.value, WuiWatcherMetadata(invocation.metadata))
  }
}

func dropWrapper<T>(_ data: UnsafeMutableRawPointer?, _: T.Type) {
  precondition(Thread.isMainThread, "WaterUI signal watcher was dropped off its owning UI thread")
  guard let data else {
    fatalError("WaterUI watcher dropped null callback data")
  }
  _ = Unmanaged<Wrapper<T>>.fromOpaque(data).takeRetainedValue()
}

func wrap<T>(_ f: @escaping (T, WuiWatcherMetadata) -> Void) -> UnsafeMutableRawPointer {
  let wrapper = Wrapper(f)
  return UnsafeMutableRawPointer(Unmanaged.passRetained(wrapper).toOpaque())
}

@MainActor
func makeIntWatcher(_ f: @escaping (Int32, WuiWatcherMetadata) -> Void) -> OpaquePointer {
  let data = wrap(f)
  let call: @convention(c) (UnsafeMutableRawPointer?, Int32, OpaquePointer?) -> Void = {
    data, value, metadata in
    callWrapper(data, value, metadata)
  }
  let drop: @convention(c) (UnsafeMutableRawPointer?) -> Void = {
    dropWrapper($0, Int32.self)
  }
  guard let watcher = waterui_new_watcher_i32(data, call, drop) else {
    fatalError("Failed to create i32 watcher")
  }
  return watcher
}

@MainActor
func makeBoolWatcher(_ f: @escaping (Bool, WuiWatcherMetadata) -> Void) -> OpaquePointer {
  let data = wrap(f)
  let call: @convention(c) (UnsafeMutableRawPointer?, Bool, OpaquePointer?) -> Void = {
    data, value, metadata in
    callWrapper(data, value, metadata)
  }
  let drop: @convention(c) (UnsafeMutableRawPointer?) -> Void = {
    dropWrapper($0, Bool.self)
  }
  guard let watcher = waterui_new_watcher_bool(data, call, drop) else {
    fatalError("Failed to create bool watcher")
  }
  return watcher
}

@MainActor
func makeDoubleWatcher(_ f: @escaping (Double, WuiWatcherMetadata) -> Void) -> OpaquePointer {
  let data = wrap(f)
  let call: @convention(c) (UnsafeMutableRawPointer?, Double, OpaquePointer?) -> Void = {
    data, value, metadata in
    callWrapper(data, value, metadata)
  }
  let drop: @convention(c) (UnsafeMutableRawPointer?) -> Void = {
    dropWrapper($0, Double.self)
  }
  guard let watcher = waterui_new_watcher_f64(data, call, drop) else {
    fatalError("Failed to create f64 watcher")
  }
  return watcher
}

@MainActor
func makeFloatWatcher(_ f: @escaping (Float, WuiWatcherMetadata) -> Void) -> OpaquePointer {
  let data = wrap(f)
  let call: @convention(c) (UnsafeMutableRawPointer?, Float, OpaquePointer?) -> Void = {
    data, value, metadata in
    callWrapper(data, value, metadata)
  }
  let drop: @convention(c) (UnsafeMutableRawPointer?) -> Void = {
    dropWrapper($0, Float.self)
  }
  guard let watcher = waterui_new_watcher_f32(data, call, drop) else {
    fatalError("Failed to create f32 watcher")
  }
  return watcher
}

@MainActor
func makeStrWatcher(_ f: @escaping (WuiStr, WuiWatcherMetadata) -> Void) -> OpaquePointer {
  let data = wrap(f)
  let call: @convention(c) (UnsafeMutableRawPointer?, CWaterUI.WuiStr, OpaquePointer?) -> Void = {
    data, value, metadata in
    let str = WuiStr(value)
    callWrapper(data, str, metadata)
  }
  let drop: @convention(c) (UnsafeMutableRawPointer?) -> Void = {
    dropWrapper($0, WuiStr.self)
  }
  guard let watcher = waterui_new_watcher_str(data, call, drop) else {
    fatalError("Failed to create string watcher")
  }
  return watcher
}

@MainActor
func makeSizeWatcher(_ f: @escaping (CWaterUI.WuiSize, WuiWatcherMetadata) -> Void) -> OpaquePointer
{
  let data = wrap(f)
  let call: @convention(c) (UnsafeMutableRawPointer?, CWaterUI.WuiSize, OpaquePointer?) -> Void = {
    data, value, metadata in
    callWrapper(data, value, metadata)
  }
  let drop: @convention(c) (UnsafeMutableRawPointer?) -> Void = {
    dropWrapper($0, CWaterUI.WuiSize.self)
  }
  guard let watcher = waterui_new_watcher_size(data, call, drop) else {
    fatalError("Failed to create size watcher")
  }
  return watcher
}

@MainActor
func makeRectWatcher(_ f: @escaping (CWaterUI.WuiRect, WuiWatcherMetadata) -> Void) -> OpaquePointer
{
  let data = wrap(f)
  let call: @convention(c) (UnsafeMutableRawPointer?, CWaterUI.WuiRect, OpaquePointer?) -> Void = {
    data, value, metadata in
    callWrapper(data, value, metadata)
  }
  let drop: @convention(c) (UnsafeMutableRawPointer?) -> Void = {
    dropWrapper($0, CWaterUI.WuiRect.self)
  }
  guard let watcher = waterui_new_watcher_rect(data, call, drop) else {
    fatalError("Failed to create rect watcher")
  }
  return watcher
}

@MainActor
func makeWindowStateWatcher(
  _ f: @escaping (CWaterUI.WuiWindowState, WuiWatcherMetadata) -> Void
) -> OpaquePointer {
  let data = wrap(f)
  let call:
    @convention(c) (UnsafeMutableRawPointer?, CWaterUI.WuiWindowState, OpaquePointer?) -> Void = {
      data, value, metadata in
      callWrapper(data, value, metadata)
    }
  let drop: @convention(c) (UnsafeMutableRawPointer?) -> Void = {
    dropWrapper($0, CWaterUI.WuiWindowState.self)
  }
  guard let watcher = waterui_new_watcher_window_state(data, call, drop) else {
    fatalError("Failed to create Window-state watcher")
  }
  return watcher
}

@MainActor
func makeSubtitleSelectionWatcher(
  _ f: @escaping (CWaterUI.WuiSubtitleSelection, WuiWatcherMetadata) -> Void
) -> OpaquePointer {
  let data = wrap(f)
  let call:
    @convention(c) (
      UnsafeMutableRawPointer?,
      CWaterUI.WuiSubtitleSelection,
      OpaquePointer?
    ) -> Void = { data, value, metadata in
      callWrapper(data, value, metadata)
    }
  let drop: @convention(c) (UnsafeMutableRawPointer?) -> Void = {
    dropWrapper($0, CWaterUI.WuiSubtitleSelection.self)
  }
  guard
    let watcher = waterui_new_watcher_subtitle_selection(
      data,
      call,
      drop
    )
  else {
    fatalError("Failed to create subtitle-selection watcher")
  }
  return watcher
}

@MainActor
func makeAudioTrackSelectionWatcher(
  _ f: @escaping (CWaterUI.WuiAudioTrackSelection, WuiWatcherMetadata) -> Void
) -> OpaquePointer {
  let data = wrap(f)
  let call:
    @convention(c) (
      UnsafeMutableRawPointer?,
      CWaterUI.WuiAudioTrackSelection,
      OpaquePointer?
    ) -> Void = { data, value, metadata in
      callWrapper(data, value, metadata)
    }
  let drop: @convention(c) (UnsafeMutableRawPointer?) -> Void = {
    dropWrapper($0, CWaterUI.WuiAudioTrackSelection.self)
  }
  guard
    let watcher = waterui_new_watcher_audio_track_selection(
      data,
      call,
      drop
    )
  else {
    fatalError("Failed to create audio-track-selection watcher")
  }
  return watcher
}

@MainActor
func makeVideoTrackSelectionWatcher(
  _ f: @escaping (CWaterUI.WuiVideoTrackSelection, WuiWatcherMetadata) -> Void
) -> OpaquePointer {
  let data = wrap(f)
  let call:
    @convention(c) (
      UnsafeMutableRawPointer?,
      CWaterUI.WuiVideoTrackSelection,
      OpaquePointer?
    ) -> Void = { data, value, metadata in
      callWrapper(data, value, metadata)
    }
  let drop: @convention(c) (UnsafeMutableRawPointer?) -> Void = {
    dropWrapper($0, CWaterUI.WuiVideoTrackSelection.self)
  }
  guard
    let watcher = waterui_new_watcher_video_track_selection(
      data,
      call,
      drop
    )
  else {
    fatalError("Failed to create video-track-selection watcher")
  }
  return watcher
}

@MainActor
func makeVideoDeliveryWatcher(
  _ f: @escaping (CWaterUI.WuiVideoDelivery, WuiWatcherMetadata) -> Void
) -> OpaquePointer {
  let data = wrap(f)
  let call:
    @convention(c) (
      UnsafeMutableRawPointer?,
      CWaterUI.WuiVideoDelivery,
      OpaquePointer?
    ) -> Void = { data, value, metadata in
      callWrapper(data, value, metadata)
    }
  let drop: @convention(c) (UnsafeMutableRawPointer?) -> Void = {
    dropWrapper($0, CWaterUI.WuiVideoDelivery.self)
  }
  guard let watcher = waterui_new_watcher_video_delivery(data, call, drop) else {
    fatalError("Failed to create video-delivery watcher")
  }
  return watcher
}

@MainActor
func makeSecureWatcher(_ f: @escaping (WuiStr, WuiWatcherMetadata) -> Void) -> OpaquePointer {
  let data = wrap(f)
  let call: @convention(c) (UnsafeMutableRawPointer?, CWaterUI.WuiStr, OpaquePointer?) -> Void = {
    data, value, metadata in
    let str = WuiStr(value)
    callWrapper(data, str, metadata)
  }
  let drop: @convention(c) (UnsafeMutableRawPointer?) -> Void = {
    dropWrapper($0, WuiStr.self)
  }
  guard let watcher = waterui_new_watcher_secure(data, call, drop) else {
    fatalError("Failed to create secure watcher")
  }
  return watcher
}

@MainActor
func makeStyledStrWatcher(_ f: @escaping (WuiStyledStr, WuiWatcherMetadata) -> Void)
  -> OpaquePointer
{
  let data = wrap(f)
  let call:
    @convention(c) (UnsafeMutableRawPointer?, CWaterUI.WuiStyledStr, OpaquePointer?) -> Void =
      { data, value, metadata in
        let str = WuiStyledStr(value)
        callWrapper(data, str, metadata)
      }
  let drop: @convention(c) (UnsafeMutableRawPointer?) -> Void = {
    dropWrapper($0, WuiStyledStr.self)
  }
  guard let watcher = waterui_new_watcher_styled_str(data, call, drop) else {
    fatalError("Failed to create styled string watcher")
  }
  return watcher
}

@MainActor
func makeResolvedFontWatcher(_ f: @escaping (WuiResolvedFontValue, WuiWatcherMetadata) -> Void)
  -> OpaquePointer
{
  let data = wrap(f)
  let call:
    @convention(c) (UnsafeMutableRawPointer?, CWaterUI.WuiResolvedFont, OpaquePointer?) -> Void = {
      data, value, metadata in
      callWrapper(data, WuiResolvedFontValue(consuming: value), metadata)
    }
  let drop: @convention(c) (UnsafeMutableRawPointer?) -> Void = {
    dropWrapper($0, WuiResolvedFontValue.self)
  }
  guard let watcher = waterui_new_watcher_resolved_font(data, call, drop) else {
    fatalError("Failed to create resolved font watcher")
  }
  return watcher
}

@MainActor
func makeResolvedColorWatcher(_ f: @escaping (WuiResolvedColor, WuiWatcherMetadata) -> Void)
  -> OpaquePointer
{
  let data = wrap(f)
  let call: @convention(c) (UnsafeMutableRawPointer?, WuiResolvedColor, OpaquePointer?) -> Void =
    {
      data, value, metadata in
      callWrapper(data, value, metadata)
    }
  let drop: @convention(c) (UnsafeMutableRawPointer?) -> Void = {
    dropWrapper($0, WuiResolvedColor.self)
  }
  guard let watcher = waterui_new_watcher_resolved_color(data, call, drop) else {
    fatalError("Failed to create resolved color watcher")
  }
  return watcher
}

@MainActor
func makeColorSchemeWatcher(_ f: @escaping (WuiColorScheme, WuiWatcherMetadata) -> Void)
  -> OpaquePointer
{
  let data = wrap(f)
  let call: @convention(c) (UnsafeMutableRawPointer?, WuiColorScheme, OpaquePointer?) -> Void =
    {
      data, value, metadata in
      callWrapper(data, value, metadata)
    }
  let drop: @convention(c) (UnsafeMutableRawPointer?) -> Void = {
    dropWrapper($0, WuiColorScheme.self)
  }
  guard let watcher = waterui_new_watcher_color_scheme(data, call, drop) else {
    fatalError("Failed to create color scheme watcher")
  }
  return watcher
}

@MainActor
func makeHorizontalAlignmentWatcher(
  _ f: @escaping (WuiHorizontalAlignment, WuiWatcherMetadata) -> Void
)
  -> OpaquePointer
{
  let data = wrap(f)
  let call:
    @convention(c) (
      UnsafeMutableRawPointer?,
      WuiHorizontalAlignment,
      OpaquePointer?
    ) -> Void = {
      data, value, metadata in
      callWrapper(data, value, metadata)
    }
  let drop: @convention(c) (UnsafeMutableRawPointer?) -> Void = {
    dropWrapper($0, WuiHorizontalAlignment.self)
  }
  guard let watcher = waterui_new_watcher_horizontal_alignment(data, call, drop) else {
    fatalError("Failed to create horizontal alignment watcher")
  }
  return watcher
}

@MainActor
func makeCursorStyleWatcher(_ f: @escaping (WuiCursorStyle, WuiWatcherMetadata) -> Void)
  -> OpaquePointer
{
  let data = wrap(f)
  let call: @convention(c) (UnsafeMutableRawPointer?, WuiCursorStyle, OpaquePointer?) -> Void =
    {
      data, value, metadata in
      callWrapper(data, value, metadata)
    }
  let drop: @convention(c) (UnsafeMutableRawPointer?) -> Void = {
    dropWrapper($0, WuiCursorStyle.self)
  }
  guard let watcher = waterui_new_watcher_cursor_style(data, call, drop) else {
    fatalError("Failed to create cursor style watcher")
  }
  return watcher
}

@MainActor
func makeIdWatcher(_ f: @escaping (WuiId, WuiWatcherMetadata) -> Void) -> OpaquePointer {
  let data = wrap(f)
  let call: @convention(c) (UnsafeMutableRawPointer?, WuiId, OpaquePointer?) -> Void = {
    data, value, metadata in
    callWrapper(data, value, metadata)
  }
  let drop: @convention(c) (UnsafeMutableRawPointer?) -> Void = {
    dropWrapper($0, WuiId.self)
  }
  guard let watcher = waterui_new_watcher_id(data, call, drop) else {
    fatalError("Failed to create id watcher")
  }
  return watcher
}

@MainActor
func makeDateTimeWatcher(_ f: @escaping (CWaterUI.WuiDateTime, WuiWatcherMetadata) -> Void)
  -> OpaquePointer
{
  let data = wrap(f)
  let call:
    @convention(c) (UnsafeMutableRawPointer?, CWaterUI.WuiDateTime, OpaquePointer?) -> Void = {
      data, value, metadata in
      callWrapper(data, value, metadata)
    }
  let drop: @convention(c) (UnsafeMutableRawPointer?) -> Void = {
    dropWrapper($0, CWaterUI.WuiDateTime.self)
  }
  guard let watcher = waterui_new_watcher_date_time(data, call, drop) else {
    fatalError("Failed to create date-time watcher")
  }
  return watcher
}

@MainActor
func makeColorWatcher(_ f: @escaping (OpaquePointer, WuiWatcherMetadata) -> Void) -> OpaquePointer {
  let data = wrap(f)
  // The callback receives an opaque pointer to WuiColor
  let call: @convention(c) (UnsafeMutableRawPointer?, OpaquePointer?, OpaquePointer?) -> Void = {
    data, value, metadata in
    guard let value else {
      fatalError("Color signal watcher received a null Color value")
    }
    callWrapper(data, value, metadata)
  }
  let drop: @convention(c) (UnsafeMutableRawPointer?) -> Void = {
    dropWrapper($0, OpaquePointer.self)
  }
  guard let watcher = waterui_new_watcher_color(data, call, drop) else {
    fatalError("Failed to create color watcher")
  }
  return watcher
}

@MainActor
func makeRegionWatcher(_ f: @escaping (WuiRegion, WuiWatcherMetadata) -> Void) -> OpaquePointer {
  let data = wrap(f)
  let call: @convention(c) (UnsafeMutableRawPointer?, WuiRegion, OpaquePointer?) -> Void = {
    data, value, metadata in
    callWrapper(data, value, metadata)
  }
  let drop: @convention(c) (UnsafeMutableRawPointer?) -> Void = {
    dropWrapper($0, WuiRegion.self)
  }
  guard let watcher = waterui_new_watcher_region(data, call, drop) else {
    fatalError("Failed to create region watcher")
  }
  return watcher
}
