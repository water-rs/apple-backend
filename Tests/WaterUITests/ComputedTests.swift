import Testing

@testable import WaterUI

@MainActor
struct ComputedTests {
  private func makeComputed(
    _ store: FakeSignalStore<Int>
  ) -> WuiComputed<Int> {
    WuiComputed<Int>(
      inner: makeFakeInner(),
      read: store.read,
      watch: store.watch,
      drop: store.drop
    )
  }

  @Test func valueReadsThrough() {
    let store = FakeSignalStore(5)
    let computed = makeComputed(store)
    #expect(computed.value == 5)
    #expect(store.readCount == 1)
  }

  @Test func watchDeliversUpdates() {
    let store = FakeSignalStore(0)
    let computed = makeComputed(store)
    var received: [Int] = []
    let guard_ = computed.watch { value, _ in received.append(value) }
    store.publish(3)
    store.publish(4)
    #expect(received == [3, 4])
    _ = guard_
  }

  @Test func deinitDropsInner() async {
    let store = FakeSignalStore(0)
    do {
      let computed = makeComputed(store)
      _ = computed
    }
    await drainMainActor()
    #expect(store.dropCount == 1)
  }

  @Test func observationMirrorsValueAndFiresOnChange() {
    let store = FakeSignalStore(10)
    let computed = makeComputed(store)
    var received: [Int] = []
    let observation = WuiComputedObservation(computed) { value, _ in
      received.append(value)
    }
    #expect(observation.value == 10)
    store.publish(11)
    #expect(observation.value == 11)
    #expect(received == [11])
    store.publish(12)
    #expect(received == [11, 12])
  }
}
