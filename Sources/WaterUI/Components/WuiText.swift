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
    static var rawId: CWaterUI.WuiTypeId { waterui_text_id() }

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
        // Use attributed string to measure text size directly (more reliable)
        guard let attributedText = label.attributedText, attributedText.length > 0 else {
            return .zero
        }

        // Measure text with unlimited width to get intrinsic single-line size
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

        // Text is content-sized: always returns intrinsic width
        if let proposedWidth = proposal.width {
            let constrainedWidth = CGFloat(proposedWidth)
            if intrinsicSize.width <= constrainedWidth {
                return intrinsicSize
            } else {
                // Text wider than proposal - calculate wrapped height
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
        // Use NSTextField's cell for accurate text measurement on macOS
        // boundingRect can underestimate width, causing text truncation
        guard let cell = textField.cell else {
            return .zero
        }

        let attributedText = textField.attributedStringValue
        guard attributedText.length > 0 else {
            return .zero
        }

        // Use cell's cellSize for accurate measurement - this accounts for
        // font metrics, line spacing, and other factors that boundingRect misses
        let intrinsicSize = cell.cellSize(forBounds: CGRect(
            origin: .zero,
            size: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        ))

        if let proposedWidth = proposal.width {
            let constrainedWidth = CGFloat(proposedWidth)
            if intrinsicSize.width <= constrainedWidth {
                return intrinsicSize
            } else {
                // Text wider than proposal - calculate wrapped height
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

    // MARK: - Configuration

    private func configureLabel() {
        #if canImport(UIKit)
        // Use manual frame layout - label uses intrinsic size, not bounded by parent
        label.translatesAutoresizingMaskIntoConstraints = true
        label.numberOfLines = 0
        addSubview(label)
        #elseif canImport(AppKit)
        // Use manual frame layout - textField uses intrinsic size
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

    #if canImport(UIKit)
    override func layoutSubviews() {
        super.layoutSubviews()
        // Use bounds - trust container's layout decision (SwiftUI-like)
        label.frame = bounds
    }
    #elseif canImport(AppKit)
    override func layout() {
        super.layout()
        // Use bounds - trust container's layout decision (SwiftUI-like)
        textField.frame = bounds
    }

    override var isFlipped: Bool { true }
    #endif

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
        let attributed = styled.toAttributedString(env: env)
        label.attributedText = attributed
        // Notify layout system that size may have changed
        label.invalidateIntrinsicContentSize()
        invalidateIntrinsicContentSize()
        // Propagate layout invalidation up the entire view hierarchy
        setNeedsLayout()
        var parent = superview
        while let p = parent {
            p.setNeedsLayout()
            parent = p.superview
        }
        #elseif canImport(AppKit)
        let attributed = styled.toAttributedString(env: env)
        textField.attributedStringValue = NSAttributedString(attributedString: attributed)
        // Notify layout system that size may have changed
        textField.invalidateIntrinsicContentSize()
        invalidateIntrinsicContentSize()
        // Propagate layout invalidation up the entire view hierarchy
        needsLayout = true
        var parent = superview
        while let p = parent {
            p.needsLayout = true
            parent = p.superview
        }
        #endif
    }
}
