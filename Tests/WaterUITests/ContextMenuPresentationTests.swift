import Foundation
import Testing

@testable import WaterUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

@MainActor
struct ContextMenuPresentationTests {
  private func makeRequests(
    _ store: FakeSignalStore<Int32>
  ) -> WuiComputed<Int32> {
    WuiComputed<Int32>(
      inner: makeFakeInner(),
      read: store.read,
      watch: store.watch,
      drop: store.drop
    )
  }

  // MARK: - Accessory placement

  @Test func accessoryCentersAbovePreview() {
    let container = CGRect(x: 0, y: 0, width: 400, height: 800)
    let preview = CGRect(x: 100, y: 300, width: 200, height: 120)
    let frame = wuiContextMenuAccessoryFrame(
      previewFrame: preview,
      accessorySize: CGSize(width: 120, height: 44),
      containerBounds: container
    )
    #expect(frame.midX == preview.midX)
    #expect(frame.maxY + 8 == preview.minY)
  }

  @Test func accessoryFlipsBelowPreviewWhenNoRoomAbove() {
    let container = CGRect(x: 0, y: 0, width: 400, height: 800)
    let preview = CGRect(x: 100, y: 40, width: 200, height: 60)
    let frame = wuiContextMenuAccessoryFrame(
      previewFrame: preview,
      accessorySize: CGSize(width: 120, height: 44),
      containerBounds: container
    )
    #expect(frame.minY == preview.maxY + 8)
  }

  @Test func accessoryClampsInsideContainerEdges() {
    let container = CGRect(x: 0, y: 0, width: 300, height: 800)
    let preview = CGRect(x: 0, y: 300, width: 40, height: 60)
    let frame = wuiContextMenuAccessoryFrame(
      previewFrame: preview,
      accessorySize: CGSize(width: 120, height: 44),
      containerBounds: container
    )
    #expect(frame.minX == 8)
    #expect(container.insetBy(dx: 8, dy: 8).contains(frame))
  }

  @Test func accessoryClipsOversizeToContainer() {
    let container = CGRect(x: 0, y: 0, width: 200, height: 300)
    let preview = CGRect(x: 50, y: 100, width: 100, height: 60)
    let frame = wuiContextMenuAccessoryFrame(
      previewFrame: preview,
      accessorySize: CGSize(width: 500, height: 400),
      containerBounds: container
    )
    #expect(frame.width == 184)
    #expect(frame.height == 284)
    #expect(container.insetBy(dx: 8, dy: 8).contains(frame))
  }

  // MARK: - Dismiss requests

  @Test func dismissRequestFiresOnEachChange() {
    let store = FakeSignalStore<Int32>(0)
    var dismissals = 0
    let dismissal = WuiContextMenuDismissal(requests: makeRequests(store)) {
      dismissals += 1
    }
    store.publish(1)
    store.publish(2)
    #expect(dismissals == 2)
    _ = dismissal
  }

  @Test func droppingDismissalCancelsTheWatcher() async {
    let store = FakeSignalStore<Int32>(0)
    do {
      _ = WuiContextMenuDismissal(requests: makeRequests(store)) {}
    }
    await drainMainActor()
    #expect(store.watcherCancelCount == 1)
  }

  #if canImport(AppKit)
    // MARK: - AppKit accessory placement

    @Test func accessoryScreenFrameLandsAbovePreviewOnScreen() {
      let bounds = CGRect(x: 0, y: 0, width: 1000, height: 700)
      let preview = CGRect(x: 300, y: 150, width: 200, height: 100)
      let frame = wuiContextMenuAccessoryScreenFrame(
        previewFrame: preview,
        accessorySize: CGSize(width: 120, height: 44),
        screenBounds: bounds
      )
      // Screen y grows upward, so "above the preview" is a higher minY.
      #expect(frame.minY == preview.maxY + 8)
      #expect(frame.midX == preview.midX)
      #expect(bounds.insetBy(dx: 8, dy: 8).contains(frame))
    }

    @Test func accessoryScreenFrameDropsBelowWhenPreviewIsAtTopOfScreen() {
      let bounds = CGRect(x: 0, y: 0, width: 1000, height: 700)
      let preview = CGRect(x: 300, y: 640, width: 200, height: 50)
      let frame = wuiContextMenuAccessoryScreenFrame(
        previewFrame: preview,
        accessorySize: CGSize(width: 120, height: 44),
        screenBounds: bounds
      )
      // No room above (preview.maxY + gap + height > top margin), so the
      // accessory lands just below the preview's screen-bottom edge.
      #expect(frame.maxY == preview.minY - 8)
    }

    // MARK: - AppKit menu item presentation

    @Test func destructiveCommandGetsSystemRedTitle() {
      let item = NSMenuItem(title: "Delete", action: nil, keyEquivalent: "")
      wuiApplyCommandPresentation(
        item, title: "Delete", subtitle: "Gone forever", isDestructive: true)
      #expect(item.subtitle == "Gone forever")
      #expect(item.attributedTitle?.string == "Delete")
      let color = item.attributedTitle?.attribute(
        .foregroundColor, at: 0, effectiveRange: nil) as? NSColor
      #expect(color == .systemRed)
    }

    @Test func standardCommandKeepsPlainTitleAndNoSubtitle() {
      let item = NSMenuItem(title: "Copy", action: nil, keyEquivalent: "")
      wuiApplyCommandPresentation(
        item, title: "Copy", subtitle: nil, isDestructive: false)
      #expect(item.attributedTitle == nil)
      #expect(item.title == "Copy")
      #expect(item.subtitle == nil)
    }
  #endif

  #if canImport(UIKit)
    // MARK: - UIKit menu element attributes

    @Test func commandRolesMapToMenuElementAttributes() {
      #expect(
        wuiMenuElementAttributes(isDisabled: false, isDestructive: true)
          == .destructive)
      #expect(
        wuiMenuElementAttributes(isDisabled: true, isDestructive: true)
          == [.disabled, .destructive])
      #expect(
        wuiMenuElementAttributes(isDisabled: true, isDestructive: false)
          == .disabled)
      #expect(
        wuiMenuElementAttributes(isDisabled: false, isDestructive: false)
          .isEmpty)
    }
  #endif
}
