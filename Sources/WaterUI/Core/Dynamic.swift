//
//  Dynamic.swift
//
//
//  Created by Lexo Liu on 8/13/24.
//

import CWaterUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Creates a watcher for dynamic AnyView updates.
/// This is used by WuiDynamic to handle dynamic view changes.
@MainActor
func makeAnyViewWatcher(
    env: WuiEnvironment,
    _ f: @escaping (WuiAnyView) -> Void
) -> OpaquePointer {
    @MainActor
    final class AnyViewWrapper {
        var inner: (WuiAnyView) -> Void
        var env: WuiEnvironment
        init(inner: @escaping (WuiAnyView) -> Void, env: WuiEnvironment) {
            self.inner = inner
            self.env = env
        }
    }

    let data = UnsafeMutableRawPointer(Unmanaged.passRetained(AnyViewWrapper(inner: f, env: env)).toOpaque())

    let call: @convention(c) (UnsafeMutableRawPointer?, OpaquePointer?, OpaquePointer?) -> Void = { data, value, _ in
        let wrapper = Unmanaged<AnyViewWrapper>.fromOpaque(data!).takeUnretainedValue()
        (wrapper.inner)(WuiAnyView(anyview: value!, env: wrapper.env))
    }

    let drop: @convention(c) (UnsafeMutableRawPointer?) -> Void = { data in
        _ = Unmanaged<AnyViewWrapper>.fromOpaque(data!).takeRetainedValue()
    }

    guard let watcher = waterui_new_watcher_any_view(data, call, drop) else {
        fatalError("Failed to create any-view watcher")
    }
    return watcher
}
