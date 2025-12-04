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
        label.translatesAutoresizingMaskIntoConstraints = true
        label.numberOfLines = 0
        addSubview(label)
        #elseif canImport(AppKit)
        textField.translatesAutoresizingMaskIntoConstraints = true
        textField.isEditable = false
        textField.isSelectable = false
        textField.isBordered = false
        textField.drawsBackground = false
        textField.lineBreakMode = .byWordWrapping
        textField.maximumNumberOfLines = 0
        textField.cell?.wraps = true
        textField.cell?.isScrollable = false
        addSubview(textField)
        #endif
    }

    // MARK: - Layout

    #if canImport(UIKit)
    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds
    }
    #elseif canImport(AppKit)
    override func layout() {
        super.layout()
        textField.frame = bounds
    }

    override var isFlipped: Bool { true }
    #endif

    // MARK: - Size Calculation

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        #if canImport(UIKit)
        guard let attributedText = label.attributedText, attributedText.length > 0 else {
            return .zero
        }

        let maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let intrinsicRect = attributedText.boundingRect(
            with: maxSize,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        let intrinsicSize = CGSize(
            width: ceil(intrinsicRect.width),
            height: ceil(intrinsicRect.height)
        )

        if let proposedWidth = proposal.width {
            let constrainedWidth = CGFloat(proposedWidth)
            if intrinsicSize.width <= constrainedWidth {
                return intrinsicSize
            } else {
                let constrainedRect = attributedText.boundingRect(
                    with: CGSize(width: constrainedWidth, height: CGFloat.greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    context: nil
                )
                return CGSize(width: intrinsicSize.width, height: ceil(constrainedRect.height))
            }
        }

        return intrinsicSize
        #elseif canImport(AppKit)
        guard let cell = textField.cell else {
            return .zero
        }

        let attributedText = textField.attributedStringValue
        guard attributedText.length > 0 else {
            return .zero
        }

        let intrinsicSize = cell.cellSize(forBounds: CGRect(
            origin: .zero,
            size: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        ))

        if let proposedWidth = proposal.width {
            let constrainedWidth = CGFloat(proposedWidth)
            if intrinsicSize.width <= constrainedWidth {
                return intrinsicSize
            } else {
                let constrainedSize = cell.cellSize(forBounds: CGRect(
                    origin: .zero,
                    size: CGSize(width: constrainedWidth, height: CGFloat.greatestFiniteMagnitude)
                ))
                return CGSize(width: intrinsicSize.width, height: constrainedSize.height)
            }
        }

        return intrinsicSize
        #endif
    }

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
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        var parent = superview
        while let p = parent {
            p.setNeedsLayout()
            parent = p.superview
        }
        #elseif canImport(AppKit)
        textField.invalidateIntrinsicContentSize()
        invalidateIntrinsicContentSize()
        needsLayout = true
        var parent = superview
        while let p = parent {
            p.needsLayout = true
            parent = p.superview
        }
        #endif
    }
}
