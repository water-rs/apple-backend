//
//  Watcher.swift
//
//
//  Created by Gemini on 10/6/25.
//

import CWaterUI

@MainActor
class WatcherGuard {
    var inner: OpaquePointer
    init(_ inner: OpaquePointer) {
        self.inner = inner
    }
    @MainActor deinit {
        waterui_drop_box_watcher_guard(inner)
    }
}

@MainActor
class WuiWatcherMetadata {
    var inner: OpaquePointer
    init(_ inner: OpaquePointer) {
        self.inner = inner
    }

    func getAnimation() -> WuiAnimation {
        waterui_get_animation(inner)
    }

    @MainActor deinit {
        waterui_drop_watcher_metadata(inner)
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

@MainActor
func callWrapper<T>(
    _ data: UnsafeMutableRawPointer?, _ value: T, _ metadata: OpaquePointer?
) {
    let wrapper = Unmanaged<Wrapper<T>>.fromOpaque(data!).takeUnretainedValue()
    wrapper.inner(value, WuiWatcherMetadata(metadata!))
}

func dropWrapper<T>(_ data: UnsafeMutableRawPointer?, _: T.Type) {
    _ = Unmanaged<Wrapper<T>>.fromOpaque(data!).takeRetainedValue()
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
func makeResolvedFontWatcher(_ f: @escaping (WuiResolvedFont, WuiWatcherMetadata) -> Void)
    -> OpaquePointer
{
    let data = wrap(f)
    let call: @convention(c) (UnsafeMutableRawPointer?, WuiResolvedFont, OpaquePointer?) -> Void = {
        data, value, metadata in
        callWrapper(data, value, metadata)
    }
    let drop: @convention(c) (UnsafeMutableRawPointer?) -> Void = {
        dropWrapper($0, WuiResolvedFont.self)
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
