//
//  Watcher.swift
//
//
//  Created by Gemini on 10/6/25.
//

@_exported import CWaterUI
import Foundation

@MainActor
final class WatcherGuard {
  private var onCancel: (@MainActor () -> Void)?

  init(onCancel: @escaping @MainActor () -> Void) {
    self.onCancel = onCancel
  }

  convenience init(_ inner: OpaquePointer) {
    self.init(onCancel: {
      waterui_drop_box_watcher_guard(inner)
    })
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
func makeWorkingColorWatcher(_ f: @escaping (WuiWorkingColor, WuiWatcherMetadata) -> Void)
  -> OpaquePointer
{
  let data = wrap(f)
  let call: @convention(c) (UnsafeMutableRawPointer?, WuiWorkingColor, OpaquePointer?) -> Void =
    {
      data, value, metadata in
      callWrapper(data, value, metadata)
    }
  let drop: @convention(c) (UnsafeMutableRawPointer?) -> Void = {
    dropWrapper($0, WuiWorkingColor.self)
  }
  guard let watcher = waterui_new_watcher_working_color(data, call, drop) else {
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
