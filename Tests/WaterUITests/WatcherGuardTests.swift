import Testing

@testable import WaterUI

@MainActor
struct WatcherGuardTests {
  @Test func cancelRunsHandlerExactlyOnce() {
    var cancels = 0
    let guard_ = WatcherGuard { cancels += 1 }
    guard_.cancel()
    guard_.cancel()
    #expect(cancels == 1)
  }

  @Test func deinitCancels() async {
    var cancels = 0
    do {
      _ = WatcherGuard { cancels += 1 }
    }
    await drainMainActor()
    #expect(cancels == 1)
  }
}
