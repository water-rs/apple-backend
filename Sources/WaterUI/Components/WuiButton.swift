// WuiButton.swift
// Button component - merged UIKit and AppKit implementation
//
// # Layout Behavior
// Button is content-sized - it uses its intrinsic size based on label content.
// Size adjusts to fit the label view plus standard button padding.
// Does not expand to fill available space.
//
// // INTERNAL: Layout Contract for Backend Implementers
// // - stretchAxis: .none (content-sized, does not expand)
// // - sizeThatFits: Returns intrinsic size based on label + padding
// // - Priority: 0 (default)

import CWaterUI
import os

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

private let logger = Logger(subsystem: "dev.waterui", category: "WuiButton")

@MainActor
final class WuiButton: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_button_id() }

    #if canImport(UIKit)
    private let button: UIButton = .init(type: .system)
    private let labelContainer = UIView()
    #elseif canImport(AppKit)
    private let button: NSButton
    private let labelContainer = NSView()
    #endif

    private var action: Action
    private var labelView: WuiAnyView
    private let style: WuiButtonStyle

    // MARK: - WuiComponent Init

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
        let ffiButton: CWaterUI.WuiButton = waterui_force_as_button(anyview)
        let labelView = WuiAnyView(anyview: ffiButton.label, env: env)
        let action = Action(inner: ffiButton.action, env: env)
        self.init(label: labelView, action: action, style: ffiButton.style)
    }

    // MARK: - Designated Init

    init(label: WuiAnyView, action: Action, style: WuiButtonStyle = WuiButtonStyle_Automatic) {
        self.action = action
        self.labelView = label
        self.style = style
        #if canImport(AppKit)
        self.button = NSButton()
        #endif
        super.init(frame: .zero)
        configureButton()
        embedLabel(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - WuiComponent

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        // Button has stretchAxis = .none, so it always reports its content size.
        // When width/height is constrained, the label measures with that constraint
        // (allowing text to wrap) and the button grows in the cross-axis as needed.

        // Use minimal padding for Link style, standard padding for others
        let horizontalPadding: CGFloat = style == WuiButtonStyle_Link ? 0 : 8
        let verticalPadding: CGFloat = style == WuiButtonStyle_Link ? 0 : 4

        var labelProposal = WuiProposalSize()
        if let proposedWidth = proposal.width {
            labelProposal.width = max(proposedWidth - Float(horizontalPadding * 2), 0)
        }
        if let proposedHeight = proposal.height {
            labelProposal.height = max(proposedHeight - Float(verticalPadding * 2), 0)
        }

        let labelSize = labelView.sizeThatFits(labelProposal)
        var result = CGSize(
            width: labelSize.width + horizontalPadding * 2,
            height: labelSize.height + verticalPadding * 2
        )

        // Defensively clamp to proposal when one is provided.
        if let proposedWidth = proposal.width {
            result.width = min(result.width, CGFloat(proposedWidth))
        }
        if let proposedHeight = proposal.height {
            result.height = min(result.height, CGFloat(proposedHeight))
        }

        return result
    }

    // MARK: - Update Methods

    func updateLabel(_ newLabel: WuiAnyView) {
        guard labelView !== newLabel else { return }
        labelContainer.subviews.forEach { $0.removeFromSuperview() }
        labelView = newLabel
        embedLabel(newLabel)
        #if canImport(UIKit)
        if style == WuiButtonStyle_Link {
            applyLinkStylingToLabelUIKit(labelView)
        }
        #elseif canImport(AppKit)
        if style == WuiButtonStyle_Link {
            applyLinkStylingToLabel(labelView)
        }
        #endif
    }

    // MARK: - Configuration

    private func configureButton() {
        button.translatesAutoresizingMaskIntoConstraints = false
        labelContainer.translatesAutoresizingMaskIntoConstraints = false
        #if canImport(UIKit)
        // The embedded label should not intercept touches meant for the button.
        labelContainer.isUserInteractionEnabled = false
        #endif

        // Use minimal padding for Link style, standard padding for others
        let horizontalPadding: CGFloat = style == WuiButtonStyle_Link ? 0 : 8
        let verticalPadding: CGFloat = style == WuiButtonStyle_Link ? 0 : 4

        #if canImport(AppKit)
        // On AppKit, add labelContainer directly to self (not to NSButton)
        // NSButton's internal layout doesn't properly propagate constraints to subviews
        addSubview(button)
        addSubview(labelContainer)

        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),

            labelContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: horizontalPadding),
            labelContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -horizontalPadding),
            labelContainer.topAnchor.constraint(equalTo: topAnchor, constant: verticalPadding),
            labelContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -verticalPadding)
        ])
        #else
        addSubview(button)
        button.addSubview(labelContainer)

        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),

            labelContainer.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: horizontalPadding),
            labelContainer.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -horizontalPadding),
            labelContainer.topAnchor.constraint(equalTo: button.topAnchor, constant: verticalPadding),
            labelContainer.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -verticalPadding)
        ])
        #endif

        #if canImport(UIKit)
        button.addTarget(self, action: #selector(didTap), for: .touchUpInside)
        applyStyleUIKit()
        #elseif canImport(AppKit)
        button.target = self
        button.action = #selector(didTap)
        button.title = ""
        applyStyleAppKit()
        #endif
    }

    #if canImport(UIKit)
    private func applyStyleUIKit() {
        switch style {
        case WuiButtonStyle_Automatic:
            // Default system button style
            break
        case WuiButtonStyle_Plain:
            button.configuration = .plain()
        case WuiButtonStyle_Link:
            // Link style: blue text, no background
            button.configuration = .plain()
            button.tintColor = .systemBlue
            applyLinkStylingToLabelUIKit(labelView)
        case WuiButtonStyle_Borderless:
            button.configuration = .plain()
        case WuiButtonStyle_Bordered:
            button.configuration = .bordered()
        case WuiButtonStyle_BorderedProminent:
            button.configuration = .borderedProminent()
        default:
            break
        }
    }

    /// Recursively applies link styling (blue color, underline) to text views.
    private func applyLinkStylingToLabelUIKit(_ view: UIView) {
        if let label = view as? UILabel {
            let base = label.attributedText ?? NSAttributedString(string: label.text ?? "")
            let attributed = NSMutableAttributedString(attributedString: base)
            let range = NSRange(location: 0, length: attributed.length)
            attributed.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            attributed.addAttribute(.foregroundColor, value: UIColor.systemBlue, range: range)
            label.attributedText = attributed
            label.invalidateIntrinsicContentSize()
        }

        for subview in view.subviews {
            applyLinkStylingToLabelUIKit(subview)
        }
    }
    #endif

    #if canImport(AppKit)
    private func applyStyleAppKit() {
        switch style {
        case WuiButtonStyle_Automatic:
            button.bezelStyle = .rounded
        case WuiButtonStyle_Plain:
            button.isBordered = false
        case WuiButtonStyle_Link:
            // Link style: no border, apply link color to embedded text
            button.isBordered = false
            button.contentTintColor = .linkColor
            // Apply link styling to the label text view
            applyLinkStylingToLabel(labelView)
            // Setup hover tracking for cursor change
            setupLinkTrackingArea()
        case WuiButtonStyle_Borderless:
            button.isBordered = false
            button.bezelStyle = .inline
        case WuiButtonStyle_Bordered:
            button.bezelStyle = .rounded
        case WuiButtonStyle_BorderedProminent:
            button.bezelStyle = .rounded
            button.keyEquivalent = "\r"  // Makes it the default button (blue)
        default:
            button.bezelStyle = .rounded
        }
    }

    /// Recursively applies link styling (blue color, underline) to text views
    private func applyLinkStylingToLabel(_ view: NSView) {
        if let textField = view as? NSTextField {
            // Apply link color and underline via attributed string
            let originalText = textField.stringValue
            logger.debug("[Link] applyLinkStyling: found NSTextField with text='\(originalText, privacy: .public)' len=\(originalText.count, privacy: .public)")
            if let attributedString = textField.attributedStringValue.mutableCopy() as? NSMutableAttributedString {
                let range = NSRange(location: 0, length: attributedString.length)
                attributedString.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                attributedString.addAttribute(.foregroundColor, value: NSColor.linkColor, range: range)
                textField.attributedStringValue = attributedString
                logger.debug("[Link] applyLinkStyling: after styling, attributedString.length=\(attributedString.length, privacy: .public)")
            }
            textField.invalidateIntrinsicContentSize()
        }
        for subview in view.subviews {
            applyLinkStylingToLabel(subview)
        }
    }

    /// Sets up tracking area for hover effects (Link style cursor change)
    private func setupLinkTrackingArea() {
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }

    override func mouseEntered(with event: NSEvent) {
        if style == WuiButtonStyle_Link {
            NSCursor.pointingHand.push()
        }
    }

    override func mouseExited(with event: NSEvent) {
        if style == WuiButtonStyle_Link {
            NSCursor.pop()
        }
    }

    override func mouseDown(with event: NSEvent) {
        if style == WuiButtonStyle_Link {
            // Natural press feedback: reduce opacity like SwiftUI
            labelView.alphaValue = 0.5
        }
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if style == WuiButtonStyle_Link {
            // Restore opacity
            labelView.alphaValue = 1.0
        }
        super.mouseUp(with: event)
    }
    #endif

    private func embedLabel(_ view: WuiAnyView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        labelContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: labelContainer.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: labelContainer.trailingAnchor),
            view.topAnchor.constraint(equalTo: labelContainer.topAnchor),
            view.bottomAnchor.constraint(equalTo: labelContainer.bottomAnchor)
        ])
    }

    @objc
    private func didTap() {
        action.call()
    }

    #if canImport(AppKit)
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        if style == WuiButtonStyle_Link {
            logger.debug("[Link] layout: self.bounds=\(self.bounds.width, privacy: .public)x\(self.bounds.height, privacy: .public), button.frame=\(self.button.frame.width, privacy: .public)x\(self.button.frame.height, privacy: .public), labelContainer.frame=\(self.labelContainer.frame.width, privacy: .public)x\(self.labelContainer.frame.height, privacy: .public), labelView.frame=\(self.labelView.frame.width, privacy: .public)x\(self.labelView.frame.height, privacy: .public)")
        }
    }
    #endif
}
