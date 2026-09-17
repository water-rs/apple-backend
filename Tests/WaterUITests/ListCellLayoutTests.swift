// ListCellLayoutTests.swift
// Regression for the iOS list cell that measured a `vstack` nested in an
// `hstack` correctly — the row came out three lines tall — but painted
// nothing: the nested column never received a placement proposal, so its
// text views kept a zero frame.

#if canImport(UIKit)
  import UIKit
  import XCTest

  @testable import WaterUI

  @MainActor
  final class ListCellLayoutTests: XCTestCase {
    /// Hosts a real app showing a list of nested-stack rows —
    /// `hstack(icon, vstack(hstack(text, spacer, flag), text, text))` behind a
    /// `Label`, the shape `Tests/IOSTestHost` builds — and asserts every text
    /// view inside a cell lands with a non-zero frame inside the cell's
    /// bounds. Run with `.github/scripts/run-ios-device-tests.sh
    /// ios_test_host`.
    func testNestedStackTextHasNonZeroFramesInsideCells() async throws {
      let context = try await DeviceHostedApp.load()
      DeviceHostedApp.pump()

      guard
        let table = DeviceHostedApp.findView(in: context.rootView, where: {
          $0 is UITableView
        }) as? UITableView
      else {
        throw XCTSkip("the hosted application shows no list")
      }
      table.layoutIfNeeded()
      DeviceHostedApp.pump()

      var cellsChecked = 0
      var textViewsChecked = 0
      for cell in table.visibleCells {
        var cellText = 0
        for subview in cell.contentView.allSubviews where subview is UILabel {
          guard let label = subview as? UILabel, !(label.text ?? "").isEmpty else {
            continue
          }
          cellText += 1
          let frameInCell = label.convert(label.bounds, to: cell)
          XCTAssertGreaterThan(
            label.frame.width, 0,
            "a nested text view kept a zero-width frame in \(cell.bounds)")
          XCTAssertGreaterThan(
            label.frame.height, 0,
            "a nested text view kept a zero-height frame in \(cell.bounds)")
          XCTAssertTrue(
            cell.bounds.insetBy(dx: -1, dy: -1).intersects(frameInCell),
            "a nested text view was laid out outside its cell: \(frameInCell) "
              + "in \(cell.bounds)")
        }
        if cellText > 0 { cellsChecked += 1 }
        textViewsChecked += cellText
      }

      XCTAssertGreaterThan(cellsChecked, 0, "no materialized list cells found")
      XCTAssertGreaterThanOrEqual(
        textViewsChecked, 3,
        "a nested vstack row carries at least three text views")
    }
  }

  private extension UIView {
    var allSubviews: [UIView] {
      subviews.flatMap { [$0] + $0.allSubviews }
    }
  }
#endif
