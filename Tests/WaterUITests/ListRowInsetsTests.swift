// ListRowInsetsTests.swift
// iOS list row chrome parity.
//
// `WuiList` rows ran ~7 pt shorter than SwiftUI `List` rows on iOS 26 because
// the cell insets were hand-tuned (11/20) instead of the platform's. These
// tests pin the row chrome to the platform's own list cell: the margins a
// live inset-grouped `UITableViewCell` reports, the minimum row height a
// stock cell reports, and the row pitch a hosted SwiftUI `List` produces.

#if canImport(UIKit)
  import SwiftUI
  import UIKit
  import XCTest

  @testable import WaterUI

  @MainActor
  final class ListRowInsetsTests: XCTestCase {
    private var window: UIWindow?

    override func tearDown() {
      window?.isHidden = true
      window = nil
      super.tearDown()
    }

    /// The margins a live inset-grouped table cell applies to its content are
    /// the platform's row insets — `WuiListCell.rowInsets` must be the same
    /// values.
    func testRowInsetsMatchDisplayedCellMargins() throws {
      let source = OneCellSource()
      let table = UITableView(
        frame: CGRect(x: 0, y: 0, width: 402, height: 874), style: .insetGrouped)
      table.dataSource = source
      host(table)
      table.reloadData()
      pump()

      let cell = try XCTUnwrap(
        table.cellForRow(at: IndexPath(row: 0, section: 0)),
        "the hosted table did not materialize its row")
      let margins = cell.contentView.directionalLayoutMargins
      let insets = WuiListCell.rowInsets
      XCTAssertEqual(insets.top, margins.top, accuracy: 0.5)
      XCTAssertEqual(insets.leading, margins.leading, accuracy: 0.5)
      XCTAssertEqual(insets.bottom, margins.bottom, accuracy: 0.5)
      XCTAssertEqual(insets.trailing, margins.trailing, accuracy: 0.5)
    }

    /// A row's pitch is its content plus the platform chrome: 24 pt of
    /// content must produce the same row height a hosted SwiftUI `List`
    /// gives the same content.
    func testRowPitchMatchesHostedSwiftUI() throws {
      let reference = try hostedSwiftUIRowHeight(
        List { Color.red.frame(height: 24) })
      let insets = WuiListCell.rowInsets
      let pitch = max(
        24 + insets.top + insets.bottom,
        WuiListCell.minimumRowHeight
      )
      XCTAssertEqual(
        pitch, reference, accuracy: 0.5,
        "row pitch must match the hosted SwiftUI row")
    }

    /// Content shorter than the floor still renders a full-height row — the
    /// platform minimum, which `minimumRowHeight` measures.
    func testMinimumRowHeightMatchesHostedSwiftUI() throws {
      let reference = try hostedSwiftUIRowHeight(
        List { Color.red.frame(height: 4) })
      XCTAssertEqual(
        WuiListCell.minimumRowHeight, reference, accuracy: 0.5,
        "the platform's minimum row height")
    }

    // MARK: - Hosting helpers

    /// A single-row data source for the margins probe.
    private final class OneCellSource: NSObject, UITableViewDataSource {
      func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        1
      }

      func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath)
        -> UITableViewCell
      {
        UITableViewCell(style: .default, reuseIdentifier: nil)
      }
    }

    /// Hosts a view in a key window so Auto Layout resolves it.
    private func host(_ view: UIView) {
      let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
      let controller = UIViewController()
      controller.view = view
      window.rootViewController = controller
      window.makeKeyAndVisible()
      self.window = window
    }

    /// Lets the run loop drive the pending layout pass.
    private func pump() {
      RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25))
    }

    /// The height of the first row a hosted SwiftUI `List` renders.
    private func hostedSwiftUIRowHeight<V: View>(_ content: V) throws -> CGFloat {
      let controller = UIHostingController(rootView: content)
      let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
      window.rootViewController = controller
      window.makeKeyAndVisible()
      self.window = window
      pump()

      var cellHeight: CGFloat?
      func walk(_ view: UIView) {
        guard cellHeight == nil else { return }
        let name = String(describing: type(of: view))
        if name.contains("ListCollectionViewCell") || view is UICollectionViewListCell {
          cellHeight = view.frame.height
          return
        }
        for subview in view.subviews { walk(subview) }
      }
      walk(window)
      return try XCTUnwrap(cellHeight, "the hosted SwiftUI List rendered no cell")
    }
  }
#endif
