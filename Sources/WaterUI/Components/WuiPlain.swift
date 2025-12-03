// WuiPlain.swift
// Plain text component (simple unstyled text) - merged UIKit and AppKit implementation
//
// # Layout Behavior
// Plain text is content-sized - it uses its intrinsic size based on content.
// When width is constrained, text wraps and height adjusts accordingly.
// Does not expand to fill available space.
//
// // INTERNAL: Layout Contract for Backend Implementers
// // - stretchAxis: .none (content-sized, does not expand)
// // - sizeThatFits: Returns intrinsic size, respects width constraint for wrapping
// // - Priority: 0 (default)

import CWaterUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
final class WuiPlain: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_plain_id() }

    #if canImport(UIKit)
    private let label = UILabel()
    #elseif canImport(AppKit)
    private let textField: NSTextField
    #endif
    private let text: String

    // MARK: - WuiComponent Init

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
        let ffiStr: CWaterUI.WuiStr = waterui_force_as_plain(anyview)
        let text = WuiStr(ffiStr).toString()
        self.init(text: text)
    }

    // MARK: - Designated Init

    init(text: String) {
        self.text = text
        #if canImport(AppKit)
        self.textField = NSTextField(labelWithString: text)
        #endif
        super.init(frame: .zero)
        configureLabel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - WuiComponent

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        #if canImport(UIKit)
        let targetWidth = proposal.width.map { CGFloat($0) } ?? UIView.noIntrinsicMetric
        let targetHeight = proposal.height.map { CGFloat($0) } ?? UIView.noIntrinsicMetric
        let fittingSize = CGSize(
            width: targetWidth == UIView.noIntrinsicMetric ? UIView.layoutFittingCompressedSize.width : targetWidth,
            height: targetHeight == UIView.noIntrinsicMetric ? UIView.layoutFittingCompressedSize.height : targetHeight
        )
        let horizontalPriority: UILayoutPriority =
            targetWidth == UIView.noIntrinsicMetric ? .fittingSizeLevel : .required
        let verticalPriority: UILayoutPriority =
            targetHeight == UIView.noIntrinsicMetric ? .fittingSizeLevel : .required
        return label.systemLayoutSizeFitting(
            fittingSize,
            withHorizontalFittingPriority: horizontalPriority,
            verticalFittingPriority: verticalPriority
        )
        #elseif canImport(AppKit)
        let maxWidth = proposal.width.map { CGFloat($0) } ?? CGFloat.greatestFiniteMagnitude
        textField.preferredMaxLayoutWidth = maxWidth
        let intrinsicSize = textField.intrinsicContentSize

        if let proposedWidth = proposal.width {
            let constrainedWidth = CGFloat(proposedWidth)
            textField.preferredMaxLayoutWidth = constrainedWidth
            let height = textField.intrinsicContentSize.height
            return CGSize(width: min(intrinsicSize.width, constrainedWidth), height: height)
        }

        return intrinsicSize
        #endif
    }

    // MARK: - Configuration

    private func configureLabel() {
        #if canImport(UIKit)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 0
        label.text = text
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

    #if canImport(AppKit)
    override var isFlipped: Bool { true }
    #endif
}
