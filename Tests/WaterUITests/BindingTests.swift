import Testing

@testable import WaterUI

@MainActor
struct BindingTests {
  private func makeBinding(
    _ store: FakeSignalStore<Int>
  ) -> WuiBinding<Int> {
    WuiBinding<Int>(
      inner: makeFakeInner(),
      read: store.read,
      watch: store.watch,
      set: store.set,
      drop: store.drop
    )
  }

  @Test func valueReadsThroughTheSignal() {
    let store = FakeSignalStore(41)
    let binding = makeBinding(store)
    #expect(binding.value == 41)
    #expect(store.readCount == 1)
  }

  @Test func setRoutesToTheStoreAndPublishes() {
    let store = FakeSignalStore(0)
    let binding = makeBinding(store)
    binding.set(7)
    #expect(store.setCalls == [7])
    #expect(binding.value == 7)
    binding.value = 8
    #expect(store.setCalls == [7, 8])
  }

  @Test func everyRegisteredWatcherIsNotified() {
    let store = FakeSignalStore(0)
    let binding = makeBinding(store)
    var first: [Int] = []
    var second: [Int] = []
    let firstGuard = binding.watch { value, _ in first.append(value) }
    let secondGuard = binding.watch { value, _ in second.append(value) }
    store.publish(9)
    #expect(first == [9])
    #expect(second == [9])
    _ = firstGuard
    _ = secondGuard
  }

  @Test func cancelledWatcherStopsReceiving() {
    let store = FakeSignalStore(0)
    let binding = makeBinding(store)
    var received: [Int] = []
    let watcher = binding.watch { value, _ in received.append(value) }
    store.publish(1)
    watcher.cancel()
    store.publish(2)
    #expect(received == [1])
  }

  @Test func disposeValueReleasesRetiredValues() {
    let store = FakeSignalStore(0)
    var disposed: [Int] = []
    let binding = WuiBinding<Int>(
      inner: makeFakeInner(),
      read: store.read,
      watch: store.watch,
      set: store.set,
      drop: store.drop,
      disposeValue: { disposed.append($0) }
    )
    store.publish(1)
    store.publish(2)
    #expect(disposed == [0, 1])
    _ = binding
  }

  @Test func deinitDropsInnerAndCancelsTheSignalWatch() async {
    let store = FakeSignalStore(0)
    var disposed: [Int] = []
    do {
      let binding = WuiBinding<Int>(
        inner: makeFakeInner(),
        read: store.read,
        watch: store.watch,
        set: store.set,
        drop: store.drop,
        disposeValue: { disposed.append($0) }
      )
      _ = binding
    }
    await drainMainActor()
    #expect(store.dropCount == 1)
    #expect(store.watcherCancelCount == 1)
    #expect(disposed == [0])
  }

  @Test func innerPointerIsThreadedThroughUnchanged() {
    let store = FakeSignalStore(0)
    let inner = makeFakeInner(0x2A)
    var seen: OpaquePointer?
    let binding = WuiBinding<Int>(
      inner: inner,
      read: { pointer in
        seen = pointer
        return store.read(pointer)
      },
      watch: store.watch,
      set: store.set,
      drop: store.drop
    )
    _ = binding.value
    #expect(seen == inner)
  }
}
