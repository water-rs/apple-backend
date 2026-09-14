// WuiLaunchTiming.swift
// Measures process start to the first window's first painted frame, once per
// process.
//
// CI records every example's launch time from the `waterui_first_paint_ms=N`
// marker this emits on `os_log` (subsystem `dev.waterui`). os_log is the one
// channel `water run` streams back on both platforms: macOS apps launched
// through `open -W` have no reachable stdout, and simulator apps' stdout is
// not captured either.

import Foundation
import OSLog
import QuartzCore

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

@MainActor
enum WuiLaunchTiming {
  /// Process start in `mach_absolute_time` units, taken from the kernel's own
  /// record so the measurement covers dyld, static initializers, and everything
  /// else that runs before WaterUI code is reached.
  private static let processStartAbstime: UInt64 = {
    var usage = rusage_info_v4()
    let status = withUnsafeMutablePointer(to: &usage) { pointer in
      pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
        proc_pid_rusage(getpid(), RUSAGE_INFO_V4, rebound)
      }
    }
    return status == 0 ? usage.ri_proc_start_abstime : mach_absolute_time()
  }()

  private static var reported = false

  private static func elapsedMillis(since start: UInt64) -> UInt64 {
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    let elapsed = mach_absolute_time() - start
    return elapsed * UInt64(timebase.numer) / UInt64(timebase.denom) / 1_000_000
  }

  /// Marks the launch interval once the first root content view's first frame
  /// is on screen: after its first-paint participants report ready and a
  /// display pass has been committed. Only the first call has an effect.
  static func markFirstPaint(on view: WuiAnyView) {
    guard !reported else { return }
    reported = true
    Task { @MainActor in
      await view.ready()
      #if canImport(AppKit)
        view.window?.displayIfNeeded()
      #elseif canImport(UIKit)
        view.window?.layoutIfNeeded()
      #endif
      CATransaction.flush()
      let millis = elapsedMillis(since: processStartAbstime)
      Logger(subsystem: "dev.waterui", category: "Startup")
        .notice("waterui_first_paint_ms=\(millis, privacy: .public)")
    }
  }
}
