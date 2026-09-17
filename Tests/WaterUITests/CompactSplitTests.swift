// CompactSplitTests.swift
// A compact-width NavigationSplitView collapses onto its sidebar — the way
// SwiftUI's does — not onto the detail column.

#if canImport(UIKit)
  import UIKit
  import XCTest

  @testable import WaterUI

  @MainActor
  final class CompactSplitTests: XCTestCase {
    /// Hosts a real application at compact width — run with an example whose
    /// root is a NavigationSplitView, e.g.
    /// `.github/scripts/run-ios-device-tests.sh reminders` — and asserts the
    /// collapsed split's top column is the primary one even though the app
    /// carries a selection.
    func testCollapsedSplitShowsSidebar() async throws {
      let context = try await DeviceHostedApp.load()
      DeviceHostedApp.pump()

      guard
        let split = DeviceHostedApp.findViewController(ofType: UISplitViewController.self)
      else {
        throw XCTSkip("the hosted application shows no split view")
      }
      XCTAssertTrue(split.isCollapsed, "a 393pt window must collapse the split")

      // UIKit wraps the collapsed stack in an anonymous container, so the
      // observable contract is which column's view is on screen: the
      // sidebar's must be attached to the window, the detail's must not.
      let primary = try XCTUnwrap(split.viewController(for: .primary))
      XCTAssertNotNil(
        primary.viewIfLoaded?.window,
        "the collapsed split must show the sidebar column, not the detail")
      if let secondary = split.viewController(for: .secondary) {
        XCTAssertNil(
          secondary.viewIfLoaded?.window,
          "the detail column must not cover the sidebar in a collapsed split")
      }
    }
  }
#endif
