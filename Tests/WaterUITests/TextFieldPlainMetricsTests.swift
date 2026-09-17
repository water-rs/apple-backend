// TextFieldPlainMetricsTests.swift
// A WaterUI text field with no explicit style is SwiftUI's automatic style,
// which on iOS is plain: the input is exactly its text's line box, with no
// border, fill or padding. The reference is measured live rather than baked
// in, so a platform change in SwiftUI's field height fails here first.

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

    func testPlainInputMatchesSwiftUIAutomaticFieldHeight() {
      let reference = hostedHeight(TextField("", text: .constant("x")))

      let textView = UITextView()
      WuiTextField.configurePlainInput(textView)
      textView.font = .preferredFont(forTextStyle: .body)
      textView.text = "x"
      let measured = textView.sizeThatFits(
        CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
      ).height

      XCTAssertEqual(measured, reference, accuracy: 0.5)
      XCTAssertEqual(textView.textContainerInset, .zero)
      XCTAssertEqual(textView.layer.borderWidth, 0)
      XCTAssertEqual(textView.backgroundColor, .clear)
    }
  }
#endif
