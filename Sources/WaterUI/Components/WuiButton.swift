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

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

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

    // MARK: - WuiComponent Init

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
        let ffiButton: CWaterUI.WuiButton = waterui_force_as_button(anyview)
        let labelView = WuiAnyView(anyview: ffiButton.label, env: env)
        let action = Action(inner: ffiButton.action, env: env)
        self.init(label: labelView, action: action)
    }

    // MARK: - Designated Init

    init(label: WuiAnyView, action: Action) {
        self.action = action
        self.labelView = label
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
        // Button has stretchAxis = .none, so it always reports its intrinsic size.
        // It never expands to fill space, and it should not be compressed below intrinsic.
        #if canImport(UIKit)
        return button.systemLayoutSizeFitting(
            UIView.layoutFittingCompressedSize,
            withHorizontalFittingPriority: .fittingSizeLevel,
            verticalFittingPriority: .fittingSizeLevel
        )
        #elseif canImport(AppKit)
        // Calculate size based on label content plus padding
        // NSButton.fittingSize doesn't always account for custom embedded views correctly
        let labelSize = labelView.sizeThatFits(WuiProposalSize())
        let horizontalPadding: CGFloat = 16 // 8pt on each side
        let verticalPadding: CGFloat = 8    // 4pt on each side
        return CGSize(
            width: labelSize.width + horizontalPadding,
            height: labelSize.height + verticalPadding
        )
        #endif
    }

    // MARK: - Update Methods

    func updateLabel(_ newLabel: WuiAnyView) {
        guard labelView !== newLabel else { return }
        labelContainer.subviews.forEach { $0.removeFromSuperview() }
        labelView = newLabel
        embedLabel(newLabel)
    }

    // MARK: - Configuration

    private func configureButton() {
        button.translatesAutoresizingMaskIntoConstraints = false
        labelContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)

        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        button.addSubview(labelContainer)
        NSLayoutConstraint.activate([
            labelContainer.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 8),
            labelContainer.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -8),
            labelContainer.topAnchor.constraint(equalTo: button.topAnchor, constant: 4),
            labelContainer.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -4)
        ])

        #if canImport(UIKit)
        button.addTarget(self, action: #selector(didTap), for: .touchUpInside)
        #elseif canImport(AppKit)
        button.bezelStyle = .rounded
        button.target = self
        button.action = #selector(didTap)
        button.title = ""
        #endif
    }

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
    #endif
}
