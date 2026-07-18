//
//  WuiBinding.swift
//
//
//  Created by Gemini on 10/6/25.
//

import CWaterUI
import Foundation

@MainActor
private final class WuiBindingObserverRegistry<T> {
  private final class Observer {
    let callback: (T, WuiWatcherMetadata) -> Void

    init(callback: @escaping (T, WuiWatcherMetadata) -> Void) {
      self.callback = callback
    }
  }

  private var observers: [Observer] = []

  func add(_ callback: @escaping (T, WuiWatcherMetadata) -> Void) -> WatcherGuard {
    let observer = Observer(callback: callback)
    observers.append(observer)
    return WatcherGuard { [weak self] in
      self?.observers.removeAll { $0 === observer }
    }
  }

  func send(_ value: T, metadata: WuiWatcherMetadata) {
    for observer in observers {
      observer.callback(value, metadata)
    }
  }
}

@MainActor
final class WuiBinding<T> {
  private let inner: OpaquePointer
  private let setFn: (OpaquePointer?, T) -> Void
  private let dropFn: (OpaquePointer?) -> Void
  private let observerRegistry: WuiBindingObserverRegistry<T>
  private let subscription: WuiSignalSubscription<T>

  var value: T {
    get { subscription.value }
    set { set(newValue) }
  }

  init(
    inner: OpaquePointer,
    read: @escaping (OpaquePointer?) -> T,
    watch:
      @escaping (OpaquePointer?, @escaping (T, WuiWatcherMetadata) -> Void) -> WatcherGuard,
    set: @escaping (OpaquePointer?, T) -> Void,
    drop: @escaping (OpaquePointer?) -> Void,
    disposeValue: @escaping (T) -> Void = { _ in }
  ) {
    self.inner = inner
    self.setFn = set
    self.dropFn = drop
    let observerRegistry = WuiBindingObserverRegistry<T>()
    self.observerRegistry = observerRegistry
    self.subscription = WuiSignalSubscription(
      read: { read(inner) },
      subscribe: { watch(inner, $0) },
      disposeValue: disposeValue,
      onChange: { value, metadata in
        observerRegistry.send(value, metadata: metadata)
      }
    )
  }

  func watch(_ f: @escaping (T, WuiWatcherMetadata) -> Void) -> WatcherGuard {
    observerRegistry.add(f)
  }

  func set(_ value: T) {
    setFn(inner, value)
  }

  @MainActor deinit {
    subscription.cancel()
    dropFn(inner)
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
      read: { inner in WuiStyledStr(waterui_read_binding_styled_str(inner)) },
      watch: { inner, f in
        let g = waterui_watch_binding_styled_str(inner, makeStyledStrWatcher(f))
        return WatcherGuard(g!)
      },
      set: { inner, value in
        var owned = value
        waterui_set_binding_styled_str(inner, owned.intoInner())
      },
      drop: waterui_drop_binding_styled_str
    )
  }

  func setPlain(_ value: String) {
    let bytes = Array(value.utf8)
    bytes.withUnsafeBufferPointer { buffer in
      waterui_set_binding_styled_str_utf8(inner, buffer.baseAddress, UInt(buffer.count))
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

extension WuiBinding where T == CWaterUI.WuiRect {
  convenience init(_ inner: OpaquePointer) {
    self.init(
      inner: inner,
      read: waterui_read_binding_rect,
      watch: { inner, f in
        guard let watcher = waterui_watch_binding_rect(inner, makeRectWatcher(f)) else {
          fatalError("Failed to watch rect binding")
        }
        return WatcherGuard(watcher)
      },
      set: waterui_set_binding_rect,
      drop: waterui_drop_binding_rect
    )
  }
}

extension WuiBinding where T == CWaterUI.WuiSubtitleSelection {
  convenience init(_ inner: OpaquePointer) {
    self.init(
      inner: inner,
      read: waterui_read_binding_subtitle_selection,
      watch: { inner, f in
        guard
          let watcher = waterui_watch_binding_subtitle_selection(
            inner,
            makeSubtitleSelectionWatcher(f)
          )
        else {
          fatalError("Failed to watch subtitle-selection binding")
        }
        return WatcherGuard(watcher)
      },
      set: waterui_set_binding_subtitle_selection,
      drop: waterui_drop_binding_subtitle_selection
    )
  }
}

extension WuiBinding where T == CWaterUI.WuiAudioTrackSelection {
  convenience init(_ inner: OpaquePointer) {
    self.init(
      inner: inner,
      read: waterui_read_binding_audio_track_selection,
      watch: { inner, f in
        guard
          let watcher = waterui_watch_binding_audio_track_selection(
            inner,
            makeAudioTrackSelectionWatcher(f)
          )
        else {
          fatalError("Failed to watch audio-track-selection binding")
        }
        return WatcherGuard(watcher)
      },
      set: waterui_set_binding_audio_track_selection,
      drop: waterui_drop_binding_audio_track_selection
    )
  }
}

extension WuiBinding where T == CWaterUI.WuiVideoTrackSelection {
  convenience init(_ inner: OpaquePointer) {
    self.init(
      inner: inner,
      read: waterui_read_binding_video_track_selection,
      watch: { inner, f in
        guard
          let watcher = waterui_watch_binding_video_track_selection(
            inner,
            makeVideoTrackSelectionWatcher(f)
          )
        else {
          fatalError("Failed to watch video-track-selection binding")
        }
        return WatcherGuard(watcher)
      },
      set: waterui_set_binding_video_track_selection,
      drop: waterui_drop_binding_video_track_selection
    )
  }
}

extension WuiBinding where T == CWaterUI.WuiWindowState {
  convenience init(_ inner: OpaquePointer) {
    self.init(
      inner: inner,
      read: waterui_read_binding_window_state,
      watch: { inner, f in
        guard
          let guardPointer = waterui_watch_binding_window_state(
            inner,
            makeWindowStateWatcher(f)
          )
        else {
          fatalError("Failed to watch the window-state binding")
        }
        return WatcherGuard(guardPointer)
      },
      set: waterui_set_binding_window_state,
      drop: waterui_drop_binding_window_state
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
      drop: waterui_drop_binding_color,
      disposeValue: waterui_drop_color
    )
  }
}
