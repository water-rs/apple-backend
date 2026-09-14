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
  /// Process start in nanoseconds, in the domain `nowNanos()` reads. Taken
  /// from the kernel's own record so the measurement covers dyld, static
  /// initializers, and everything else that runs before WaterUI code is
  /// reached.
  private static let processStartNanos: UInt64 = {
    #if canImport(AppKit)
      var usage = rusage_info_v4()
      let status = withUnsafeMutablePointer(to: &usage) { pointer in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
          proc_pid_rusage(getpid(), RUSAGE_INFO_V4, rebound)
        }
      }
      guard status == 0 else { return nowNanos() }
      var timebase = mach_timebase_info_data_t()
      mach_timebase_info(&timebase)
      return usage.ri_proc_start_abstime * UInt64(timebase.numer) / UInt64(timebase.denom)
    #else
      // libproc is not in the iOS SDK's public module map; sysctl's
      // KERN_PROC_PID reports the same kernel start record as a wall-clock
      // timeval.
      var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
      var kp = kinfo_proc()
      var size = MemoryLayout<kinfo_proc>.stride
      guard sysctl(&mib, 4, &kp, &size, nil, 0) == 0 else { return nowNanos() }
      return UInt64(kp.kp_proc.p_starttime.tv_sec) * 1_000_000_000
        + UInt64(kp.kp_proc.p_starttime.tv_usec) * 1_000
    #endif
  }()

  private static func nowNanos() -> UInt64 {
    #if canImport(AppKit)
      var timebase = mach_timebase_info_data_t()
      mach_timebase_info(&timebase)
      return mach_absolute_time() * UInt64(timebase.numer) / UInt64(timebase.denom)
    #else
      return clock_gettime_nsec_np(CLOCK_REALTIME)
    #endif
  }

  private static var reported = false

  private static func elapsedMillis() -> UInt64 {
    (nowNanos() - processStartNanos) / 1_000_000
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
      let millis = elapsedMillis()
      Logger(subsystem: "dev.waterui", category: "Startup")
        .notice("waterui_first_paint_ms=\(millis, privacy: .public)")
    }
  }
}
