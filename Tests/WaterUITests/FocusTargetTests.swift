import Foundation
import Testing

#if canImport(AppKit)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
#endif

@testable import WaterUI

/// `Metadata<Focused>` hands a `Binding<bool>` to exactly one platform anchor in
/// the wrapped subtree. These tests pin the pieces that don't need real FFI:
/// observer fan-out on `WuiFocusTargetBase`, anchor counting through
/// `wuiFocusTargets`, and `WuiFocusedBindingController`'s window-gated two-way
/// sync.
///
/// The 0- and 2+-anchor failures are `fatalError`s and cannot be asserted
/// in-process; `wuiFocusTargets` exposes the count so those paths are covered
/// up to the trap.
@MainActor
struct FocusTargetTests {
  /// A focus target that records requests and emits focus changes itself.
  private final class FakeFocusTarget: WuiFocusTargetBase, WuiFocusTarget {
    let view: PlatformView
    private(set) var platformFocus = false
    private(set) var requestCount = 0
    private(set) var clearCount = 0

    init(view: PlatformView) {
      self.view = view
      super.init()
    }

    var hasPlatformFocus: Bool { platformFocus }

    func requestPlatformFocus() {
      requestCount += 1
      setPlatformFocus(true)
    }

    func clearPlatformFocus() {
      clearCount += 1
      setPlatformFocus(false)
    }

    func setPlatformFocus(_ hasFocus: Bool) {
      guard platformFocus != hasFocus else { return }
      platformFocus = hasFocus
      emitPlatformFocusChange(hasFocus)
    }
  }

  private func makeBinding(_ store: FakeSignalStore<Bool>) -> WuiBinding<Bool> {
    WuiBinding<Bool>(
      inner: makeFakeInner(),
      read: store.read,
      watch: store.watch,
      set: store.set,
      drop: store.drop
    )
  }

  // -- WuiFocusTargetBase ----------------------------------------------------

  @Test func focusChangesFanOutToEveryObserver() {
    let base = WuiFocusTargetBase()
    var first: [Bool] = []
    var second: [Bool] = []
    let firstObservation = base.observePlatformFocusChanges { first.append($0) }
    let secondObservation = base.observePlatformFocusChanges { second.append($0) }

    base.emitPlatformFocusChange(true)
    base.emitPlatformFocusChange(false)

    #expect(first == [true, false])
    #expect(second == first)
    _ = firstObservation
    _ = secondObservation
  }

  @Test func releasedObservationStopsReceiving() async {
    let base = WuiFocusTargetBase()
    var received: [Bool] = []
    var observation: WuiFocusObservation? = base.observePlatformFocusChanges {
      received.append($0)
    }

    base.emitPlatformFocusChange(true)
    #expect(observation != nil)
    observation = nil
    // The observation's deinit dispatches its removal onto the main queue.
    await drainMainActor()
    base.emitPlatformFocusChange(false)

    #expect(received == [true])
  }

  // -- anchor counting -------------------------------------------------------

  @Test func subtreeWithoutAnchorCountsZero() {
    let container = PlatformView(frame: .zero)
    container.addSubview(PlatformView(frame: .zero))
    #expect(container.wuiFocusTargets().isEmpty)
  }

  @Test func singleAnchorNestedBelowChildrenResolves() {
    let container = PlatformView(frame: .zero)
    let inner = PlatformView(frame: .zero)
    let anchor = PlatformView(frame: .zero)
    let target = FakeFocusTarget(view: anchor)
    anchor.installWuiFocusTarget(target)
    inner.addSubview(anchor)
    container.addSubview(inner)

    #expect(container.wuiFocusTargets().count == 1)
    #expect(container.requireSingleWuiFocusTarget() === target)
  }

  @Test func twoAnchorsCountTwo() {
    let container = PlatformView(frame: .zero)
    for _ in 0 ..< 2 {
      let anchor = PlatformView(frame: .zero)
      anchor.installWuiFocusTarget(FakeFocusTarget(view: anchor))
      container.addSubview(anchor)
    }

    #expect(container.wuiFocusTargets().count == 2)
  }

  // -- WuiFocusedBindingController -------------------------------------------

  private func makeController(
    store: FakeSignalStore<Bool>
  ) -> (PlatformView, FakeFocusTarget, WuiFocusedBindingController) {
    let container = PlatformView(frame: .zero)
    let anchor = PlatformView(frame: .zero)
    let target = FakeFocusTarget(view: anchor)
    container.addSubview(anchor)
    let controller = WuiFocusedBindingController(
      container: container,
      focusTarget: target,
      binding: makeBinding(store)
    )
    return (container, target, controller)
  }

  @Test func bindingTrueFocusesOnlyAfterWindowAttach() async {
    let store = FakeSignalStore(true)
    let (container, target, controller) = makeController(store: store)

    // The initial sync is scheduled but the views have no window yet.
    await drainMainActor()
    #expect(target.requestCount == 0)

    #if canImport(AppKit)
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
        styleMask: [],
        backing: .buffered,
        defer: false
      )
      window.contentView?.addSubview(container)
      controller.syncRequestedFocusState()
      await drainMainActor()

      #expect(target.requestCount == 1)
      #expect(target.hasPlatformFocus)
    #endif
  }

  @Test func bindingFalseClearsFocusedTarget() async {
    let store = FakeSignalStore(true)
    let (container, target, controller) = makeController(store: store)

    #if canImport(AppKit)
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
        styleMask: [],
        backing: .buffered,
        defer: false
      )
      window.contentView?.addSubview(container)
      controller.syncRequestedFocusState()
      await drainMainActor()
      #expect(target.hasPlatformFocus)

      // A Rust-side write reaches the watcher, which schedules the sync that
      // clears platform focus; the converged state writes nothing back.
      store.publish(false)
      await drainMainActor()

      #expect(target.clearCount == 1)
      #expect(!target.hasPlatformFocus)
      #expect(store.setCalls.isEmpty)
    #endif
  }

  @Test func platformFocusDivergenceWritesBindingWithoutEchoing() async {
    let store = FakeSignalStore(false)
    let (_, target, controller) = makeController(store: store)

    target.setPlatformFocus(true)

    #expect(store.setCalls == [true])

    // The write echoes through the watcher; converged state must not loop back
    // into another platform request.
    await drainMainActor()
    #expect(target.requestCount == 0)
    _ = controller
  }
}
