// WuiText.swift
// Styled text component - merged UIKit and AppKit implementation
//
// # Layout Behavior
// Text is content-sized - it uses its intrinsic size based on content and styling.
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
final class WuiText: PlatformView, WuiComponent {
    static let id: String = decodeViewIdentifier(waterui_text_id())

    #if canImport(UIKit)
    private let label = UILabel()
    #elseif canImport(AppKit)
    private var textField: NSTextField!
    #endif

    private var content: WuiComputed<WuiStyledStr>
    private var env: WuiEnvironment
    private var watcher: WatcherGuard?

    // MARK: - WuiComponent Init

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
        let ffiText: CWaterUI.WuiText = waterui_force_as_text(anyview)
        let content = WuiComputed<WuiStyledStr>(ffiText.content)
        self.init(content: content, env: env)
    }

    // MARK: - Designated Init

    init(content: WuiComputed<WuiStyledStr>, env: WuiEnvironment) {
        self.content = content
        self.env = env
        super.init(frame: .zero)

        #if canImport(AppKit)
        self.textField = NSTextField(labelWithString: "")
        #endif

        configureLabel()
        applyText(content.value)
        startWatching()
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

    private func startWatching() {
        watcher = content.watch { [weak self] value, metadata in
            guard let self else { return }
            #if canImport(UIKit)
            if metadata.getAnimation() != nil {
                UIView.transition(
                    with: label,
                    duration: 0.15,
                    options: .transitionCrossDissolve,
                    animations: { self.applyText(value) }
                )
            } else {
                self.applyText(value)
            }
            #elseif canImport(AppKit)
            if metadata.getAnimation() != nil {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.15
                    context.allowsImplicitAnimation = true
                    self.applyText(value)
                }
            } else {
                self.applyText(value)
            }
            #endif
        }
    }

    private func applyText(_ styled: WuiStyledStr) {
        #if canImport(UIKit)
        let attributed = NSAttributedString(styled.toAttributedString(env: env))
        label.attributedText = attributed
        // Trigger layout update up the view hierarchy
        setNeedsLayout()
        superview?.setNeedsLayout()
        #elseif canImport(AppKit)
        let attributed = styled.toAttributedString(env: env)
        textField.attributedStringValue = NSAttributedString(attributedString: attributed)
        // Notify layout system that size may have changed
        textField.invalidateIntrinsicContentSize()
        invalidateIntrinsicContentSize()
        needsLayout = true
        // Propagate layout invalidation up the view hierarchy
        var parent = superview
        while let p = parent {
            p.needsLayout = true
            parent = p.superview
        }
        #endif
    }

    #if canImport(AppKit)
    override var isFlipped: Bool { true }
    #endif
}
