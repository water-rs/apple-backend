import CWaterUI
import Foundation
import Testing

@testable import WaterUI

// The unit suite exercises the Swift machinery around the FFI surface only.
// `waterui_*` symbols are provided by the Rust library at app link time, so the
// test bundle is built with `-undefined dynamic_lookup` and every test drives
// the closure-based designated initializers — never a real FFI call.

/// A non-null pointer token standing in for an FFI-owned `inner` pointer. The
/// closure-based initializers under test never dereference it; tests assert it
/// arrives unchanged to prove the pointer is threaded through.
func makeFakeInner(_ bitPattern: UInt = 0x1) -> OpaquePointer {
  guard let pointer = OpaquePointer(bitPattern: bitPattern) else {
    fatalError("OpaquePointer(bitPattern: \(bitPattern)) unexpectedly returned nil")
  }
  return pointer
}

/// Runs enqueued main-actor work — including isolated `deinit`s — so tests can
/// assert on release semantics after dropping the last reference.
func drainMainActor() async {
  await withCheckedContinuation { continuation in
    RunLoop.main.perform {
      continuation.resume()
    }
  }
}

/// Pure-Swift stand-in for the Rust signal behind `WuiBinding`/`WuiComputed`:
/// the same read/watch/set/drop surface, driven by `publish` instead of FFI.
@MainActor
final class FakeSignalStore<T> {
  private(set) var current: T
  private(set) var readCount = 0
  private(set) var setCalls: [T] = []
  private(set) var dropCount = 0
  private(set) var watcherCancelCount = 0
  private var watcherIDs: [Int: (T, WuiWatcherMetadata) -> Void] = [:]
  private var nextWatcherID = 0

  init(_ value: T) {
    current = value
  }

  func read(_: OpaquePointer?) -> T {
    readCount += 1
    return current
  }

  func watch(
    _: OpaquePointer?,
    _ callback: @escaping (T, WuiWatcherMetadata) -> Void
  ) -> WatcherGuard {
    let id = nextWatcherID
    nextWatcherID += 1
    watcherIDs[id] = callback
    return WatcherGuard { [weak self] in
      guard let self else { return }
      watcherCancelCount += 1
      watcherIDs[id] = nil
    }
  }

  func set(_: OpaquePointer?, _ value: T) {
    setCalls.append(value)
    publish(value)
  }

  func drop(_: OpaquePointer?) {
    dropCount += 1
  }

  func publish(_ value: T) {
    current = value
    for callback in watcherIDs.values {
      callback(value, WuiWatcherMetadata(nil))
    }
  }
}
