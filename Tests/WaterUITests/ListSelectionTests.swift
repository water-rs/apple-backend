import CWaterUI
import Testing

@testable import WaterUI

// The suite drives `WuiListSelectionController` — the state machine between
// native selection gestures and the FFI bindings — with in-memory fake
// bindings. The table halves (`UITableView`/`NSTableView` wiring) are thin:
// they translate the platform's selected rows to erased ids and back, and
// those paths are covered by the harness's own flow tests.
@MainActor
struct ListSelectionTests {
  private func makeSingleBinding(_ store: FakeSignalStore<Int32>) -> WuiBinding<Int32> {
    WuiBinding<Int32>(
      inner: makeFakeInner(),
      read: store.read,
      watch: store.watch,
      set: store.set,
      drop: store.drop
    )
  }

  private func makeMultipleBinding(_ store: FakeSignalStore<[WuiId]>) -> WuiBinding<[WuiId]> {
    WuiBinding<[WuiId]>(
      inner: makeFakeInner(),
      read: store.read,
      watch: store.watch,
      set: store.set,
      drop: store.drop
    )
  }

  @Test func singleModeWriteStoresTheErasedId() {
    let store = FakeSignalStore<Int32>(0)
    let controller = WuiListSelectionController(
      mode: .single, single: makeSingleBinding(store))
    controller.write([42])
    #expect(store.setCalls == [42])
    #expect(controller.selectedIds == [42])
  }

  @Test func singleModeEmptyWriteStoresZero() {
    let store = FakeSignalStore<Int32>(5)
    let controller = WuiListSelectionController(
      mode: .single, single: makeSingleBinding(store))
    controller.write([])
    #expect(store.setCalls == [0])
    #expect(controller.selectedIds == [])
  }

  @Test func singleModeBindingNotifiesAsIdSet() {
    let store = FakeSignalStore<Int32>(0)
    var applied: [Set<Int32>] = []
    let controller = WuiListSelectionController(
      mode: .single, single: makeSingleBinding(store))
    controller.onChange = { applied.append($0) }
    store.publish(9)
    #expect(applied == [[9]])
    store.publish(0)
    #expect(applied == [[9], []])
  }

  @Test func multipleModeWritesTheWholeIdSet() {
    let store = FakeSignalStore<[WuiId]>([])
    let controller = WuiListSelectionController(
      mode: .multiple, multiple: makeMultipleBinding(store))
    controller.write([7, 3])
    #expect(store.setCalls.map { $0.map(\.inner) } == [[3, 7]])
    #expect(controller.selectedIds == [3, 7])
  }

  @Test func multipleModeToggleAccumulatesAndRemoves() {
    let store = FakeSignalStore<[WuiId]>([])
    let controller = WuiListSelectionController(
      mode: .multiple, multiple: makeMultipleBinding(store))
    controller.write([1])
    controller.write(controller.selectedIds.union([2]))
    #expect(controller.selectedIds == [1, 2])
    controller.write(controller.selectedIds.subtracting([1]))
    #expect(controller.selectedIds == [2])
    #expect(store.setCalls.map { Set($0.map(\.inner)) } == [[1], [1, 2], [2]])
  }

  @Test func multipleModeBindingNotifiesAsIdSet() {
    let store = FakeSignalStore<[WuiId]>([])
    var applied: [Set<Int32>] = []
    let controller = WuiListSelectionController(
      mode: .multiple, multiple: makeMultipleBinding(store))
    controller.onChange = { applied.append($0) }
    store.publish([WuiId(inner: 8), WuiId(inner: 4)])
    #expect(applied == [[4, 8]])
  }

  @Test func noneModeSelectsNothingAndWritesNothing() {
    var applied: [Set<Int32>] = []
    let controller = WuiListSelectionController(mode: .none)
    controller.onChange = { applied.append($0) }
    controller.write([1, 2])
    #expect(controller.selectedIds == [])
    #expect(applied.isEmpty)
  }

  @Test func writeDuringApplyIsSwallowedAsEcho() {
    let store = FakeSignalStore<Int32>(0)
    let controller = WuiListSelectionController(
      mode: .single, single: makeSingleBinding(store))
    controller.applyToTable([7]) { ids in
      // The platform's selection callback re-reports the applied ids; that
      // write is the echo and must not reach the binding.
      controller.write(ids)
    }
    #expect(store.setCalls.isEmpty)
  }

  @Test func applyPassesTheIdsThrough() {
    let store = FakeSignalStore<Int32>(0)
    let controller = WuiListSelectionController(
      mode: .single, single: makeSingleBinding(store))
    var received: [Set<Int32>] = []
    controller.applyToTable([3, 4]) { received.append($0) }
    #expect(received == [[3, 4]])
  }

  @Test func initialIdsReflectTheBindingValue() {
    let singleStore = FakeSignalStore<Int32>(3)
    let single = WuiListSelectionController(
      mode: .single, single: makeSingleBinding(singleStore))
    #expect(single.selectedIds == [3])

    let multiStore = FakeSignalStore<[WuiId]>([WuiId(inner: 1), WuiId(inner: 2)])
    let multi = WuiListSelectionController(
      mode: .multiple, multiple: makeMultipleBinding(multiStore))
    #expect(multi.selectedIds == [1, 2])
  }

  @Test func deinitDropsEachActiveBindingOnce() async {
    let singleStore = FakeSignalStore<Int32>(0)
    do {
      let controller = WuiListSelectionController(
        mode: .single, single: makeSingleBinding(singleStore))
      _ = controller
    }
    await drainMainActor()
    #expect(singleStore.dropCount == 1)

    let multiStore = FakeSignalStore<[WuiId]>([])
    do {
      let controller = WuiListSelectionController(
        mode: .multiple, multiple: makeMultipleBinding(multiStore))
      _ = controller
    }
    await drainMainActor()
    #expect(multiStore.dropCount == 1)
  }
}
