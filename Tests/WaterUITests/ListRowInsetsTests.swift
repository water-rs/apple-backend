// ListRowInsetsTests.swift
// iOS list row chrome parity.
//
// `WuiList` rows ran ~7 pt shorter than SwiftUI `List` rows on iOS 26 because
// the cell insets were hand-tuned (11/20) instead of the platform's. These
// tests pin the rendered row chrome of the archive-hosted application to the
// platform's own values: the margins the stock list-cell configuration
// reports, and the row pitch a hosted SwiftUI `List` produces. The staged
// `ios_test_host` app leads its list with measurement rows — a 24 pt
// reference row and a 4 pt reference row — so the rendered `UITableView` can
// be read directly. Skips when no packaged archive is linked.

#if canImport(UIKit)
  import SwiftUI
  import UIKit
  import XCTest

  @testable import WaterUI

  @MainActor
  final class ListRowInsetsTests: XCTestCase {
    /// The `ios_test_host` fixture leads its list with a text-field row, then
    /// the two measurement rows these indices name.
    private static let pitchRow = IndexPath(row: 1, section: 0)
    private static let floorRow = IndexPath(row: 2, section: 0)

    /// A row's content is pinned inside its `contentView` by the row insets,
    /// so the visible gap is the applied inset. The platform's row insets are
    /// the margins the stock list-cell configuration reports — the same
    /// margins `UITableView` cells and `UICollectionViewListCell` place
    /// content by — and the rendered gaps must be the same values.
    func testRowInsetsMatchDisplayedCellMargins() async throws {
      let margins = UIListContentConfiguration.cell().directionalLayoutMargins

      let table = try await hostedTable()
      let cell = try XCTUnwrap(
        table.cellForRow(at: Self.pitchRow),
        "the hosted application did not materialize the pitch reference row")
      cell.layoutIfNeeded()
      let content = try XCTUnwrap(
        cell.contentView.subviews.first,
        "the hosted row mounts no content view")

      XCTAssertEqual(content.frame.minX, margins.leading, accuracy: 0.5)
      XCTAssertEqual(content.frame.minY, margins.top, accuracy: 0.5)
      XCTAssertEqual(
        cell.contentView.bounds.width - content.frame.maxX,
        margins.trailing, accuracy: 0.5)
      XCTAssertEqual(
        cell.contentView.bounds.height - content.frame.maxY,
        margins.bottom, accuracy: 0.5)
    }

    /// A row's pitch is its content plus the platform chrome: the hosted
    /// application's 24 pt reference row must be the height a hosted SwiftUI
    /// `List` gives the same content.
    func testRowPitchMatchesHostedSwiftUI() async throws {
      let reference = try hostedSwiftUIRowHeight(
        List { Color.red.frame(height: 24) })
      let table = try await hostedTable()
      let pitch = table.rectForRow(at: Self.pitchRow).height
      XCTAssertGreaterThan(pitch, 0, "the hosted table does not size its rows")
      XCTAssertEqual(
        pitch, reference, accuracy: 0.5,
        "row pitch must match the hosted SwiftUI row")
    }

    /// Content shorter than the floor still renders a full-height row — the
    /// platform minimum, which the hosted application's 4 pt reference row
    /// measures.
    func testMinimumRowHeightMatchesHostedSwiftUI() async throws {
      let reference = try hostedSwiftUIRowHeight(
        List { Color.red.frame(height: 4) })
      let table = try await hostedTable()
      let height = table.rectForRow(at: Self.floorRow).height
      XCTAssertGreaterThan(height, 0, "the hosted table does not size its rows")
      XCTAssertEqual(
        height, reference, accuracy: 0.5,
        "the platform's minimum row height")
    }

    // MARK: - Hosting helpers

    /// The `UITableView` the archive-hosted application renders, waited on
    /// until the measurement rows the assertions read have materialized.
    private func hostedTable() async throws -> UITableView {
      let context = try await DeviceHostedApp.load()
      var table: UITableView?
      XCTAssertTrue(
        DeviceHostedApp.until {
          context.rootView.layoutIfNeeded()
          table = DeviceHostedApp.findView(in: context.rootView, where: {
            $0 is UITableView
          }) as? UITableView
          guard let table else { return false }
          table.layoutIfNeeded()
          return table.window != nil
            && table.numberOfRows(inSection: Self.floorRow.section) > Self.floorRow.row
            && table.cellForRow(at: Self.floorRow) != nil
        },
        "timed out waiting for the hosted list to materialize its rows")
      return try XCTUnwrap(table, "the hosted application shows no list")
    }

    /// The height of the first row a hosted SwiftUI `List` renders.
    private func hostedSwiftUIRowHeight<V: View>(_ content: V) throws -> CGFloat {
      let controller = UIHostingController(rootView: content)
      let window = UIWindow()
      window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
      window.windowScene = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .first
      window.rootViewController = controller
      window.makeKeyAndVisible()
      defer { window.isHidden = true }

      var cellHeight: CGFloat?
      XCTAssertTrue(
        DeviceHostedApp.until {
          window.layoutIfNeeded()
          cellHeight = firstListCellHeight(in: window)
          return (cellHeight ?? 0) > 0
        },
        "timed out waiting for the hosted SwiftUI List to render a cell")
      return try XCTUnwrap(cellHeight, "the hosted SwiftUI List rendered no cell")
    }

    /// The rendered height of the first list cell in `root`'s subtree —
    /// `nil` until the hosting controller's first layout pass lands it.
    private func firstListCellHeight(in root: UIView) -> CGFloat? {
      let name = String(describing: type(of: root))
      if name.contains("ListCollectionViewCell") || root is UICollectionViewListCell {
        return root.frame.height
      }
      for subview in root.subviews {
        if let height = firstListCellHeight(in: subview) { return height }
      }
      return nil
    }
  }
#endif
