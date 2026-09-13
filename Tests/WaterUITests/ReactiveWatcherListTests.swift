import Testing

@testable import WaterUI

struct ReactiveWatcherListTests {
  @Test func notifyCallsEveryWatcherWithTheCurrentValue() {
    var calls: [(OpaquePointer, Int)] = []
    var releases: [OpaquePointer] = []
    let list = ReactiveWatcherList<Int>(
      value: 5,
      call: { calls.append(($0, $1)) },
      release: { releases.append($0) }
    )
    let first = makeFakeInner(0x11)
    let second = makeFakeInner(0x22)
    list.addWatcher(first)
    list.addWatcher(second)
    list.notifyWatchers()
    #expect(calls.map { $0.0 } == [first, second])
    #expect(calls.map { $0.1 } == [5, 5])
    list.value = 9
    list.notifyWatchers()
    #expect(calls.map { $0.1 } == [5, 5, 9, 9])
    #expect(releases.isEmpty)
  }

  @Test func removeWatcherReleasesExactlyOnce() {
    var releases: [OpaquePointer] = []
    let list = ReactiveWatcherList<Int>(
      value: 0,
      call: { _, _ in },
      release: { releases.append($0) }
    )
    let first = makeFakeInner(0x11)
    let second = makeFakeInner(0x22)
    list.addWatcher(first)
    list.addWatcher(second)
    list.removeWatcher(first)
    #expect(releases == [first])
    list.cleanup()
    #expect(releases == [first, second])
  }

  @Test func removedWatcherIsNotNotified() {
    var calls: [(OpaquePointer, Int)] = []
    let list = ReactiveWatcherList<Int>(
      value: 0,
      call: { calls.append(($0, $1)) },
      release: { _ in }
    )
    let first = makeFakeInner(0x11)
    let second = makeFakeInner(0x22)
    list.addWatcher(first)
    list.addWatcher(second)
    list.removeWatcher(first)
    list.notifyWatchers()
    #expect(calls.map { $0.0 } == [second])
  }
}
