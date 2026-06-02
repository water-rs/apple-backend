//
//  WuiBinding.swift
//
//
//  Created by Gemini on 10/6/25.
//

import CWaterUI
import Foundation

@_silgen_name("waterui_read_binding_styled_str")
private func wui_read_binding_styled_str(_ _: OpaquePointer?) -> CWaterUI.WuiStyledStr

@_silgen_name("waterui_watch_binding_styled_str")
private func wui_watch_binding_styled_str(
    _ _: OpaquePointer?,
    _ _: OpaquePointer?
) -> OpaquePointer?

@_silgen_name("waterui_drop_binding_styled_str")
private func wui_drop_binding_styled_str(_ _: OpaquePointer?)

@_silgen_name("waterui_set_binding_styled_str")
private func wui_set_binding_styled_str(_ _: OpaquePointer?, _ _: CWaterUI.WuiStyledStr)

@_silgen_name("waterui_set_binding_styled_str_utf8")
private func wui_set_binding_styled_str_utf8(_ _: OpaquePointer?, _ _: UnsafePointer<UInt8>?, _ _: UInt)

@MainActor
final class WuiBinding<T> {
    private var inner: OpaquePointer
    private var watcher: WatcherGuard!

    private let readFn: (OpaquePointer?) -> T
    private let watchFn: (OpaquePointer?, @escaping (T, WuiWatcherMetadata) -> Void) -> WatcherGuard
    private let setFn: (OpaquePointer?, T) -> Void
    private let dropFn: (OpaquePointer?) -> Void
    private var isSyncingFromRust = false

    var value: T {
        didSet {
            guard !isSyncingFromRust else { return }
            setFn(inner, value)
        }
    }

    init(
        inner: OpaquePointer,
        read: @escaping (OpaquePointer?) -> T,
        watch:
            @escaping (OpaquePointer?, @escaping (T, WuiWatcherMetadata) -> Void) -> WatcherGuard,
        set: @escaping (OpaquePointer?, T) -> Void,
        drop: @escaping (OpaquePointer?) -> Void
    ) {
        self.inner = inner
        self.readFn = read
        self.watchFn = watch
        self.setFn = set
        self.dropFn = drop
        self.isSyncingFromRust = true
        self.value = read(inner)
        self.isSyncingFromRust = false

        self.watcher = self.watch { [unowned self] value, metadata in
            self.withRustSync {
                self.value = value
            }
        }
    }

    func watch(_ f: @escaping (T, WuiWatcherMetadata) -> Void) -> WatcherGuard {
        watchFn(inner, f)
    }

    func set(_ value: T) {
        self.value = value
    }

    @MainActor deinit {
        dropFn(inner)
    }
}

@MainActor
private extension WuiBinding {
    func withRustSync(_ update: () -> Void) {
        let wasSyncing = isSyncingFromRust
        isSyncingFromRust = true
        update()
        isSyncingFromRust = wasSyncing
    }
}

extension WuiBinding where T == WuiStr {
    convenience init(_ inner: OpaquePointer) {
        self.init(
            inner: inner,
            read: { inner in WuiStr(waterui_read_binding_str(inner)) },
            watch: { inner, f in
                let g = waterui_watch_binding_str(inner, makeStrWatcher(f))
                return WatcherGuard(g!)
            },
            set: { inner, value in
                waterui_set_binding_str(inner, value.intoInner())
            },
            drop: waterui_drop_binding_str
        )
    }

    convenience init(secure inner: OpaquePointer) {
        self.init(
            inner: inner,
            read: { inner in WuiStr(waterui_read_binding_secure(inner)) },
            watch: { inner, f in
                let g = waterui_watch_binding_secure(inner, makeSecureWatcher(f))
                return WatcherGuard(g!)
            },
            set: { inner, value in
                waterui_set_binding_secure(inner, value.intoInner())
            },
            drop: waterui_drop_binding_secure
        )
    }
}

extension WuiBinding where T == WuiStyledStr {
    convenience init(_ inner: OpaquePointer) {
        self.init(
            inner: inner,
            read: { inner in WuiStyledStr(wui_read_binding_styled_str(inner)) },
            watch: { inner, f in
                let g = wui_watch_binding_styled_str(inner, makeStyledStrWatcher(f))
                return WatcherGuard(g!)
            },
            set: { inner, value in
                var owned = value
                wui_set_binding_styled_str(inner, owned.intoInner())
            },
            drop: wui_drop_binding_styled_str
        )
    }

    func setPlain(_ value: String) {
        let bytes = Array(value.utf8)
        bytes.withUnsafeBufferPointer { buffer in
            wui_set_binding_styled_str_utf8(inner, buffer.baseAddress, UInt(buffer.count))
        }
    }
}

extension WuiBinding where T == Int32 {
    convenience init(_ inner: OpaquePointer) {
        self.init(
            inner: inner,
            read: waterui_read_binding_i32,
            watch: { inner, f in
                let g = waterui_watch_binding_i32(inner, makeIntWatcher(f))
                return WatcherGuard(g!)
            },
            set: waterui_set_binding_i32,
            drop: waterui_drop_binding_i32
        )
    }
}

extension WuiBinding where T == Bool {
    convenience init(_ inner: OpaquePointer) {
        self.init(
            inner: inner,
            read: waterui_read_binding_bool,
            watch: { inner, f in
                let g = waterui_watch_binding_bool(inner, makeBoolWatcher(f))
                return WatcherGuard(g!)
            },
            set: waterui_set_binding_bool,
            drop: waterui_drop_binding_bool
        )
    }
}

extension WuiBinding where T == Double {
    convenience init(_ inner: OpaquePointer) {
        self.init(
            inner: inner,
            read: waterui_read_binding_f64,
            watch: { inner, f in
                let g = waterui_watch_binding_f64(inner, makeDoubleWatcher(f))
                return WatcherGuard(g!)
            },
            set: waterui_set_binding_f64,
            drop: waterui_drop_binding_f64
        )
    }
}

extension WuiBinding where T == Float {
    convenience init(_ inner: OpaquePointer) {
        self.init(
            inner: inner,
            read: waterui_read_binding_f32,
            watch: { inner, f in
                let g = waterui_watch_binding_f32(inner, makeFloatWatcher(f))
                return WatcherGuard(g!)
            },
            set: waterui_set_binding_f32,
            drop: waterui_drop_binding_f32
        )
    }
}

extension WuiBinding where T == WuiId {
    convenience init(_ inner: OpaquePointer) {
        self.init(
            inner: inner,
            read: waterui_read_binding_id,
            watch: { inner, f in
                let g = waterui_watch_binding_id(inner, makeIdWatcher(f))
                return WatcherGuard(g!)
            },
            set: waterui_set_binding_id,
            drop: waterui_drop_binding_id
        )
    }
}

extension WuiBinding where T == CWaterUI.WuiDateTime {
    convenience init(_ inner: OpaquePointer) {
        self.init(
            inner: inner,
            read: waterui_read_binding_date_time,
            watch: { inner, f in
                let g = waterui_watch_binding_date_time(inner, makeDateTimeWatcher(f))
                return WatcherGuard(g!)
            },
            set: waterui_set_binding_date_time,
            drop: waterui_drop_binding_date_time
        )
    }
}

// WuiColor is an opaque pointer type
extension WuiBinding where T == OpaquePointer {
    /// Creates a binding for Color (opaque WuiColor pointer)
    static func color(_ inner: OpaquePointer) -> WuiBinding<OpaquePointer> {
        WuiBinding<OpaquePointer>(
            inner: inner,
            read: { inner in
                // waterui_read_binding_color returns OpaquePointer for opaque WuiColor
                waterui_read_binding_color(inner)!
            },
            watch: { inner, f in
                let g = waterui_watch_binding_color(inner, makeColorWatcher(f))
                return WatcherGuard(g!)
            },
            set: { inner, value in
                // waterui_set_binding_color accepts OpaquePointer for opaque WuiColor
                waterui_set_binding_color(inner, value)
            },
            drop: waterui_drop_binding_color
        )
    }
}
