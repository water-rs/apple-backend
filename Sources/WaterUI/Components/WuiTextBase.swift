// WuiTextBase.swift
// Base class for text components (WuiText and WuiPlain)
//
// # Layout Behavior
// Text is content-sized - it uses its intrinsic size based on content and styling.
// When width is constrained, text wraps and height adjusts accordingly.
// Does not expand to fill available space.

import CWaterUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Base class providing shared text rendering functionality for WuiText and WuiPlain.
@MainActor
class WuiTextBase: PlatformView {
    #if canImport(UIKit)
    let label = UILabel()
    #elseif canImport(AppKit)
    let textField: NSTextField
    #endif

    #if canImport(AppKit)
    init(initialText: String = "") {
        self.textField = NSTextField(labelWithString: initialText)
        super.init(frame: .zero)
        configureTextView()
    }
    #else
    override init(frame: CGRect) {
        super.init(frame: frame)
        configureTextView()
    }
    #endif

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Configuration

    private func configureTextView() {
        #if canImport(UIKit)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        #elseif canImport(AppKit)
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.isEditable = false
        textField.isSelectable = false
        textField.isBordered = false
        textField.drawsBackground = false
        textField.lineBreakMode = .byWordWrapping
        textField.maximumNumberOfLines = 0
        textField.cell?.wraps = true
        textField.cell?.isScrollable = false
        addSubview(textField)
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: leadingAnchor),
            textField.trailingAnchor.constraint(equalTo: trailingAnchor),
            textField.topAnchor.constraint(equalTo: topAnchor),
            textField.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        #endif
    }

    // MARK: - Size Calculation

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        #if canImport(UIKit)
        let maxWidth = proposal.width.map(CGFloat.init) ?? CGFloat.greatestFiniteMagnitude
        let maxHeight = proposal.height.map(CGFloat.init) ?? CGFloat.greatestFiniteMagnitude
        let measured = label.sizeThatFits(CGSize(width: maxWidth, height: maxHeight))
        return CGSize(
            width: ceil(min(measured.width, maxWidth)),
            height: ceil(min(measured.height, maxHeight))
        )
        #elseif canImport(AppKit)
        guard let cell = textField.cell else {
            return .zero
        }

        let attributedText = textField.attributedStringValue
        guard attributedText.length > 0 else {
            return .zero
        }

        let maxWidth = proposal.width.map(CGFloat.init) ?? CGFloat.greatestFiniteMagnitude
        let maxHeight = proposal.height.map(CGFloat.init) ?? CGFloat.greatestFiniteMagnitude
        let measured = cell.cellSize(forBounds: CGRect(
            origin: .zero,
            size: CGSize(width: maxWidth, height: maxHeight)
        ))
        return CGSize(
            width: ceil(min(measured.width, maxWidth)),
            height: ceil(min(measured.height, maxHeight))
        )
        #endif
    }

    #if canImport(AppKit)
    override var isFlipped: Bool { true }
    #endif

    // MARK: - Text Updates

    func setAttributedText(_ attributed: NSAttributedString) {
        #if canImport(UIKit)
        label.attributedText = attributed
        #elseif canImport(AppKit)
        textField.attributedStringValue = NSAttributedString(attributedString: attributed)
        #endif
        invalidateLayout()
    }

    func setFont(_ font: PlatformFont) {
        #if canImport(UIKit)
        label.font = font
        #elseif canImport(AppKit)
        textField.font = font
        #endif
        invalidateLayout()
    }

    func invalidateLayout() {
        #if canImport(UIKit)
        label.invalidateIntrinsicContentSize()
        #elseif canImport(AppKit)
        textField.invalidateIntrinsicContentSize()
        #endif
        invalidateLayoutHierarchy()
    }
}
