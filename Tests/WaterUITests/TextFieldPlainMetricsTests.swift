// TextFieldPlainMetricsTests.swift
// A WaterUI text field with no explicit style is SwiftUI's automatic style,
// which on iOS is plain: the input is exactly its text's line box, with no
// border, fill or padding. The reference is measured live rather than baked
// in, so a platform change in SwiftUI's field height fails here first. The
// measured field is the one the archive-hosted `ios_test_host` application
// renders; skips when no packaged archive is linked.

#if canImport(UIKit)
  import SwiftUI
  import UIKit
  import XCTest

  @testable import WaterUI

  @MainActor
  final class TextFieldPlainMetricsTests: XCTestCase {
    private let width: CGFloat = 402

    private func hostedHeight<Content: View>(_ view: Content) -> CGFloat {
      let controller = UIHostingController(rootView: view)
      controller.view.frame = CGRect(x: 0, y: 0, width: width, height: 800)
      return controller.sizeThatFits(
        in: CGSize(width: width, height: UIView.layoutFittingCompressedSize.height)
      ).height
    }

    func testPlainInputMatchesSwiftUIAutomaticFieldHeight() async throws {
      let reference = hostedHeight(TextField("", text: .constant("x")))

      let context = try await DeviceHostedApp.load()
      var mounted: UITextField?
      XCTAssertTrue(
        DeviceHostedApp.until {
          context.rootView.layoutIfNeeded()
          mounted = DeviceHostedApp.findView(in: context.rootView, where: {
            $0 is UITextField
          }) as? UITextField
          return mounted?.window != nil
        },
        "timed out waiting for the hosted text field to mount")
      let field = try XCTUnwrap(
        mounted, "the hosted application shows no text field")

      let measured = field.sizeThatFits(
        CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
      ).height

      XCTAssertEqual(measured, reference, accuracy: 0.5)
      XCTAssertEqual(field.borderStyle, .none)
      XCTAssertNil(field.leftView)
      XCTAssertNil(field.rightView)
      XCTAssertTrue(
        field.backgroundColor == nil || field.backgroundColor == .clear,
        "a plain input carries no fill")
    }
  }
#endif
