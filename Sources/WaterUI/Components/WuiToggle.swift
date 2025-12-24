// WuiToggle.swift
// Toggle/Switch component - merged UIKit and AppKit implementation
//
// # Layout Behavior
// Toggle expands horizontally when it has a label (stretchAxis from Rust).
// Horizontal layout: [label] --- flexible space --- [switch]
// Label on left, switch on right, space distributed between.

import CWaterUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Toggle style determines the visual representation
enum ToggleStyle {
    case automatic
    case switchStyle
    case checkbox

    init(from ffiStyle: WuiToggleStyle) {
        switch ffiStyle {
        case WuiToggleStyle_Automatic: self = .automatic
        case WuiToggleStyle_Switch: self = .switchStyle
        case WuiToggleStyle_Checkbox: self = .checkbox
        default: self = .automatic
        }
    }
}

@MainActor
final class WuiToggle: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_toggle_id() }

    // Shared fields
    private var toggleControl: PlatformView!
    private var bindingWatcher: WatcherGuard?
    private var binding: WuiBinding<Bool>
    private var labelView: WuiAnyView
    private let style: ToggleStyle

    // Layout constants
    private let horizontalSpacing: CGFloat = 8.0

    // MARK: - WuiComponent Init

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
        let ffiToggle: CWaterUI.WuiToggle = waterui_force_as_toggle(anyview)
        let labelView = WuiAnyView(anyview: ffiToggle.label, env: env)
        let binding: WuiBinding<Bool> = WuiBinding(ffiToggle.toggle)
        let style = ToggleStyle(from: ffiToggle.style)
        self.init(label: labelView, binding: binding, style: style)
    }

    // MARK: - Designated Init

    init(label: WuiAnyView, binding: WuiBinding<Bool>, style: ToggleStyle = .automatic) {
        self.binding = binding
        self.labelView = label
        self.style = style
        super.init(frame: .zero)
        createToggleControl()
        configureSubviews()
        syncToggleState()
        setupAction()
        startWatchingBinding()
    }

    // MARK: - Toggle Control Creation

    private func createToggleControl() {
        switch style {
        case .automatic, .switchStyle:
            toggleControl = PlatformSwitch()
        case .checkbox:
            toggleControl = createCheckbox()
        }
    }

    #if canImport(UIKit)
    private func createCheckbox() -> UIButton {
        let button = UIButton(type: .system)
        button.setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: 22, weight: .regular),
            forImageIn: .normal
        )
        updateCheckboxImage(button, isChecked: binding.value)
        return button
    }

    private func updateCheckboxImage(_ button: UIButton, isChecked: Bool) {
        let imageName = isChecked ? "checkmark.square.fill" : "square"
        button.setImage(UIImage(systemName: imageName), for: .normal)
    }
    #elseif canImport(AppKit)
    private func createCheckbox() -> NSButton {
        return NSButton(checkboxWithTitle: "", target: nil, action: nil)
    }
    #endif

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - WuiComponent

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        let labelSize = labelView.sizeThatFits(WuiProposalSize())
        let toggleSize = toggleControl.intrinsicContentSize
        let hasLabel = labelSize.width > 0 && labelSize.height > 0

        var minWidth: CGFloat = toggleSize.width
        var maxHeight: CGFloat = toggleSize.height

        if hasLabel {
            minWidth += horizontalSpacing + labelSize.width
            maxHeight = max(maxHeight, labelSize.height)
        }

        let finalWidth: CGFloat
        if hasLabel, let proposedWidth = proposal.width {
            finalWidth = max(CGFloat(proposedWidth), minWidth)
        } else {
            finalWidth = minWidth
        }

        return CGSize(width: finalWidth, height: maxHeight)
    }

    // MARK: - Layout

    #if canImport(AppKit)
    override var isFlipped: Bool { true }
    #endif

    // MARK: - Configuration

    private func configureSubviews() {
        labelView.translatesAutoresizingMaskIntoConstraints = false
        toggleControl.translatesAutoresizingMaskIntoConstraints = false

        addSubview(labelView)
        addSubview(toggleControl)

        labelView.setContentCompressionResistancePriority(.required, for: .horizontal)
        labelView.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        NSLayoutConstraint.activate([
            labelView.leadingAnchor.constraint(equalTo: leadingAnchor),
            labelView.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggleControl.trailingAnchor.constraint(equalTo: trailingAnchor),
            toggleControl.centerYAnchor.constraint(equalTo: centerYAnchor),
            labelView.trailingAnchor.constraint(lessThanOrEqualTo: toggleControl.leadingAnchor, constant: -horizontalSpacing),
        ])
    }

    private func syncToggleState() {
        let value = binding.value
        switch style {
        case .automatic, .switchStyle:
            #if canImport(UIKit)
            (toggleControl as? UISwitch)?.isOn = value
            #elseif canImport(AppKit)
            (toggleControl as? NSSwitch)?.state = value ? .on : .off
            #endif
        case .checkbox:
            #if canImport(UIKit)
            if let button = toggleControl as? UIButton {
                updateCheckboxImage(button, isChecked: value)
            }
            #elseif canImport(AppKit)
            (toggleControl as? NSButton)?.state = value ? .on : .off
            #endif
        }
    }

    private func setupAction() {
        switch style {
        case .automatic, .switchStyle:
            #if canImport(UIKit)
            (toggleControl as? UISwitch)?.addTarget(self, action: #selector(valueChanged), for: .valueChanged)
            #elseif canImport(AppKit)
            if let toggle = toggleControl as? NSSwitch {
                toggle.target = self
                toggle.action = #selector(valueChanged)
            }
            #endif
        case .checkbox:
            #if canImport(UIKit)
            (toggleControl as? UIButton)?.addTarget(self, action: #selector(checkboxTapped), for: .touchUpInside)
            #elseif canImport(AppKit)
            if let button = toggleControl as? NSButton {
                button.target = self
                button.action = #selector(valueChanged)
            }
            #endif
        }
    }

    private func startWatchingBinding() {
        bindingWatcher = binding.watch { [weak self] newValue, metadata in
            guard let self else { return }
            switch style {
            case .automatic, .switchStyle:
                #if canImport(UIKit)
                guard let toggle = toggleControl as? UISwitch else { return }
                if toggle.isOn == newValue { return }
                let animation = parseAnimation(metadata.getAnimation())
                toggle.setOn(newValue, animated: shouldAnimate(animation))
                #elseif canImport(AppKit)
                guard let toggle = toggleControl as? NSSwitch else { return }
                let newState: NSControl.StateValue = newValue ? .on : .off
                if toggle.state == newState { return }
                withPlatformAnimation(metadata) { toggle.state = newState }
                #endif
            case .checkbox:
                #if canImport(UIKit)
                guard let button = toggleControl as? UIButton else { return }
                withPlatformAnimation(metadata) { self.updateCheckboxImage(button, isChecked: newValue) }
                #elseif canImport(AppKit)
                guard let button = toggleControl as? NSButton else { return }
                let newState: NSControl.StateValue = newValue ? .on : .off
                if button.state == newState { return }
                withPlatformAnimation(metadata) { button.state = newState }
                #endif
            }
        }
    }

    @objc private func valueChanged() {
        switch style {
        case .automatic, .switchStyle:
            #if canImport(UIKit)
            binding.value = (toggleControl as? UISwitch)?.isOn ?? false
            #elseif canImport(AppKit)
            binding.value = (toggleControl as? NSSwitch)?.state == .on
            #endif
        case .checkbox:
            #if canImport(AppKit)
            binding.value = (toggleControl as? NSButton)?.state == .on
            #endif
        }
    }

    #if canImport(UIKit)
    @objc private func checkboxTapped() {
        let newValue = !binding.value
        binding.value = newValue
        if let button = toggleControl as? UIButton {
            updateCheckboxImage(button, isChecked: newValue)
        }
    }
    #endif

    // MARK: - Update Methods

    func updateLabel(_ label: WuiAnyView) {
        guard label !== labelView else { return }
        labelView.removeFromSuperview()
        labelView = label
        labelView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(labelView)
        labelView.setContentCompressionResistancePriority(.required, for: .horizontal)
        labelView.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        NSLayoutConstraint.activate([
            labelView.leadingAnchor.constraint(equalTo: leadingAnchor),
            labelView.centerYAnchor.constraint(equalTo: centerYAnchor),
            labelView.trailingAnchor.constraint(lessThanOrEqualTo: toggleControl.leadingAnchor, constant: -horizontalSpacing),
        ])
    }

    func updateBinding(_ newBinding: WuiBinding<Bool>) {
        guard newBinding !== binding else { return }
        bindingWatcher = nil
        binding = newBinding
        syncToggleState()
        startWatchingBinding()
    }
}
