//
//  Computed.swift
//
//
//  Created by Lexo Liu on 5/13/24.
//

import CWaterUI
import Foundation

@MainActor
final class WuiComputed<T> {
  private let inner: OpaquePointer

  private let readFn: (OpaquePointer?) -> T
  private let watchFn: (OpaquePointer?, @escaping (T, WuiWatcherMetadata) -> Void) -> WatcherGuard
  private let dropFn: (OpaquePointer?) -> Void

  var value: T { readFn(inner) }

  init(
    inner: OpaquePointer,
    read: @escaping (OpaquePointer?) -> T,
    watch:
      @escaping (OpaquePointer?, @escaping (T, WuiWatcherMetadata) -> Void) -> WatcherGuard,
    drop: @escaping (OpaquePointer?) -> Void
  ) {
    self.inner = inner
    self.readFn = read
    self.watchFn = watch
    self.dropFn = drop
  }

  func watch(_ f: @escaping (T, WuiWatcherMetadata) -> Void) -> WatcherGuard {
    watchFn(inner, f)
  }

  @MainActor deinit {
    dropFn(inner)
  }
}

@MainActor
final class WuiComputedObservation<T> {
  let computed: WuiComputed<T>
  private let subscription: WuiSignalSubscription<T>

  var value: T { subscription.value }

  init(
    _ computed: WuiComputed<T>,
    onChange: @escaping (T, WuiWatcherMetadata) -> Void
  ) {
    self.computed = computed
    self.subscription = WuiSignalSubscription(
      read: { computed.value },
      subscribe: { computed.watch($0) },
      onChange: onChange
    )
  }
}

extension WuiComputedObservation where T == WuiResolvedColor {
  convenience init(
    themeColor slot: WuiColorSlot,
    env: WuiEnvironment,
    onChange: @escaping (WuiResolvedColor, WuiWatcherMetadata) -> Void
  ) {
    guard let pointer = waterui_theme_color(env.inner, slot) else {
      fatalError("WaterUI theme is missing required color slot \(slot.rawValue)")
    }
    self.init(WuiComputed<WuiResolvedColor>(pointer), onChange: onChange)
  }
}

extension WuiComputedObservation where T == WuiResolvedFontValue {
  convenience init(
    themeFont slot: WuiFontSlot,
    env: WuiEnvironment,
    onChange: @escaping (WuiResolvedFontValue, WuiWatcherMetadata) -> Void
  ) {
    guard let pointer = waterui_theme_font(env.inner, slot) else {
      fatalError("WaterUI theme is missing required font slot \(slot.rawValue)")
    }
    self.init(WuiComputed<WuiResolvedFontValue>(pointer), onChange: onChange)
  }

  /// Observes the themed body font and applies it immediately and on every
  /// change. Text controls must keep their control font in sync with the
  /// theme: the control's cell measures and its editor types with that font,
  /// so a mismatch clips oversized attributed content and makes typing start
  /// in the platform default size.
  static func bodyFont(
    env: WuiEnvironment,
    apply: @escaping (WuiResolvedFontValue) -> Void
  ) -> WuiComputedObservation<WuiResolvedFontValue> {
    let observation = WuiComputedObservation(
      themeFont: WuiFontSlot_Body,
      env: env
    ) { font, _ in
      apply(font)
    }
    apply(observation.value)
    return observation
  }
}

extension WuiComputed where T == WuiStr {
  convenience init(_ inner: OpaquePointer) {
    self.init(
      inner: inner,
      read: { inner in WuiStr(waterui_read_computed_str(inner)) },
      watch: { inner, f in
        let g = waterui_watch_computed_str(inner, makeStrWatcher(f))
        return WatcherGuard(g!)
      },
      drop: waterui_drop_computed_str
    )
  }
}

extension WuiComputed where T == Int32 {
  convenience init(_ inner: OpaquePointer) {
    self.init(
      inner: inner,
      read: waterui_read_computed_i32,
      watch: { inner, f in
        let g = waterui_watch_computed_i32(inner, makeIntWatcher(f))
        return WatcherGuard(g!)
      },
      drop: waterui_drop_computed_i32
    )
  }
}

extension WuiComputed where T == CWaterUI.WuiVideoDelivery {
  convenience init(_ inner: OpaquePointer) {
    self.init(
      inner: inner,
      read: waterui_read_computed_video_delivery,
      watch: { inner, f in
        let guardPointer = waterui_watch_computed_video_delivery(
          inner,
          makeVideoDeliveryWatcher(f)
        )
        guard let guardPointer else {
          fatalError("Failed to watch video delivery")
        }
        return WatcherGuard(guardPointer)
      },
      drop: waterui_drop_computed_video_delivery
    )
  }
}

extension WuiComputed where T == Bool {
  convenience init(_ inner: OpaquePointer) {
    self.init(
      inner: inner,
      read: waterui_read_computed_bool,
      watch: { inner, f in
        let g = waterui_watch_computed_bool(inner, makeBoolWatcher(f))
        return WatcherGuard(g!)
      },
      drop: waterui_drop_computed_bool
    )
  }
}

extension WuiComputed where T == Double {
  convenience init(_ inner: OpaquePointer) {
    self.init(
      inner: inner,
      read: waterui_read_computed_f64,
      watch: { inner, f in
        let g = waterui_watch_computed_f64(inner, makeDoubleWatcher(f))
        return WatcherGuard(g!)
      },
      drop: waterui_drop_computed_f64
    )
  }
}

extension WuiComputed where T == Float {
  convenience init(_ inner: OpaquePointer) {
    self.init(
      inner: inner,
      read: waterui_read_computed_f32,
      watch: { inner, f in
        let g = waterui_watch_computed_f32(inner, makeFloatWatcher(f))
        return WatcherGuard(g!)
      },
      drop: waterui_drop_computed_f32
    )
  }
}

extension WuiComputed where T == CWaterUI.WuiSize {
  convenience init(_ inner: OpaquePointer) {
    self.init(
      inner: inner,
      read: waterui_read_computed_size,
      watch: { inner, f in
        guard let guardPointer = waterui_watch_computed_size(inner, makeSizeWatcher(f)) else {
          fatalError("Failed to watch the size signal")
        }
        return WatcherGuard(guardPointer)
      },
      drop: waterui_drop_computed_size
    )
  }
}

extension WuiComputed where T == CWaterUI.WuiColorScheme {
  convenience init(_ inner: OpaquePointer) {
    self.init(
      inner: inner,
      read: waterui_read_computed_color_scheme,
      watch: { inner, f in
        guard
          let guardPointer = waterui_watch_computed_color_scheme(
            inner,
            makeColorSchemeWatcher(f)
          )
        else {
          fatalError("Failed to watch the color-scheme signal")
        }
        return WatcherGuard(guardPointer)
      },
      drop: waterui_drop_computed_color_scheme
    )
  }
}

extension WuiComputed where T == WuiResolvedFontValue {
  convenience init(_ inner: OpaquePointer) {
    self.init(
      inner: inner,
      read: { inner in
        WuiResolvedFontValue(consuming: waterui_read_computed_resolved_font(inner))
      },
      watch: { inner, f in
        let g = waterui_watch_computed_resolved_font(inner, makeResolvedFontWatcher(f))
        return WatcherGuard(g!)
      },
      drop: waterui_drop_computed_resolved_font
    )
  }
}

extension WuiComputed where T == WuiResolvedColor {
  convenience init(_ inner: OpaquePointer) {
    self.init(
      inner: inner,
      read: { inner in
        return waterui_read_computed_resolved_color(inner)
      },
      watch: { inner, f in
        let g = waterui_watch_computed_resolved_color(inner, makeResolvedColorWatcher(f))
        return WatcherGuard(g!)
      },
      drop: waterui_drop_computed_resolved_color
    )
  }
}

extension WuiComputed where T == WuiStyledStr {
  convenience init(_ inner: OpaquePointer) {
    self.init(
      inner: inner,
      read: { inner in
        return WuiStyledStr(waterui_read_computed_styled_str(inner))
      },
      watch: { inner, f in
        let g = waterui_watch_computed_styled_str(inner, makeStyledStrWatcher(f))
        return WatcherGuard(g!)
      },
      drop: waterui_drop_computed_styled_str
    )
  }
}

extension WuiComputed where T == WuiCursorStyle {
  convenience init(_ inner: OpaquePointer) {
    self.init(
      inner: inner,
      read: { inner in
        return waterui_read_computed_cursor_style(inner)
      },
      watch: { inner, f in
        let g = waterui_watch_computed_cursor_style(inner, makeCursorStyleWatcher(f))
        return WatcherGuard(g!)
      },
      drop: waterui_drop_computed_cursor_style
    )
  }
}

extension WuiComputed where T == WuiHorizontalAlignment {
  convenience init(_ inner: OpaquePointer) {
    self.init(
      inner: inner,
      read: { inner in
        return waterui_read_computed_horizontal_alignment(inner)
      },
      watch: { inner, f in
        let g = waterui_watch_computed_horizontal_alignment(
          inner, makeHorizontalAlignmentWatcher(f))
        return WatcherGuard(g!)
      },
      drop: waterui_drop_computed_horizontal_alignment
    )
  }
}
