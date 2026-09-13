import Testing

@testable import WaterUI

@MainActor
struct SignalSubscriptionTests {
  @Test func initialValueComesFromReadWhenSubscribeIsSilent() {
    var reads = 0
    let subscription = WuiSignalSubscription<Int>(
      read: {
        reads += 1
        return 7
      },
      subscribe: { _ in WatcherGuard {} },
      onChange: { _, _ in }
    )
    #expect(subscription.value == 7)
    #expect(reads == 1)
  }

  @Test func synchronousDeliveryDuringSubscribeStoresWithoutNotifying() {
    // A signal that fires inside the subscribe call delivers the current value
    // before `finishSubscription` marks the subscription active: the value is
    // stored, `onChange` is not fired, and the initial read is skipped.
    var reads = 0
    var notifications: [Int] = []
    let subscription = WuiSignalSubscription<Int>(
      read: {
        reads += 1
        return 0
      },
      subscribe: { callback in
        callback(99, WuiWatcherMetadata(nil))
        return WatcherGuard {}
      },
      onChange: { value, _ in notifications.append(value) }
    )
    #expect(subscription.value == 99)
    #expect(reads == 0)
    #expect(notifications.isEmpty)
  }

  @Test func updatesFireOnChangeAndUpdateValue() {
    var callback: ((Int, WuiWatcherMetadata) -> Void)?
    var notifications: [Int] = []
    let subscription = WuiSignalSubscription<Int>(
      read: { 1 },
      subscribe: { cb in
        callback = cb
        return WatcherGuard {}
      },
      onChange: { value, _ in notifications.append(value) }
    )
    callback?(2, WuiWatcherMetadata(nil))
    callback?(3, WuiWatcherMetadata(nil))
    #expect(subscription.value == 3)
    #expect(notifications == [2, 3])
  }

  @Test func disposeValueRunsOnReplaceAndOnDeinit() async {
    var callback: ((Int, WuiWatcherMetadata) -> Void)?
    var disposed: [Int] = []
    do {
      let subscription = WuiSignalSubscription<Int>(
        read: { 1 },
        subscribe: { cb in
          callback = cb
          return WatcherGuard {}
        },
        disposeValue: { disposed.append($0) },
        onChange: { _, _ in }
      )
      callback?(2, WuiWatcherMetadata(nil))
      callback?(3, WuiWatcherMetadata(nil))
      #expect(disposed == [1, 2])
      _ = subscription
    }
    // The stored callback retains the subscription's state; release it so the
    // final value's disposal is observable.
    callback = nil
    await drainMainActor()
    #expect(disposed == [1, 2, 3])
  }

  @Test func cancelDropsTheWatcher() {
    var cancels = 0
    let subscription = WuiSignalSubscription<Int>(
      read: { 0 },
      subscribe: { _ in WatcherGuard { cancels += 1 } },
      onChange: { _, _ in }
    )
    subscription.cancel()
    subscription.cancel()
    #expect(cancels == 1)
  }
}
