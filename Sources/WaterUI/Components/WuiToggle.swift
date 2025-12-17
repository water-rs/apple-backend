// WuiToggle.swift
// Toggle/Switch component - merged UIKit and AppKit implementation
//
// # Layout Behavior
// Toggle expands horizontally when it has a label (stretchAxis from Rust).
// Horizontal layout: [label] --- flexible space --- [switch]
// Label on left, switch on right, space distributed between.
//
// // INTERNAL: Layout Contract for Backend Implementers
// // - stretchAxis: Determined by Rust side (Horizontal when has label, None otherwise)
// // - sizeThatFits: Returns proposed width (or minimum), intrinsic height
// // - Priority: 0 (default)

import CWaterUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
final class WuiToggle: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_toggle_id() }

    // Shared fields
    private let toggle = PlatformSwitch()
    private var bindingWatcher: WatcherGuard?
    private var binding: WuiBinding<Bool>
    private var labelView: WuiAnyView

    // Layout constants
    private let horizontalSpacing: CGFloat = 8.0

    // MARK: - WuiComponent Init

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
        let ffiToggle: CWaterUI.WuiToggle = waterui_force_as_toggle(anyview)
        let labelView = WuiAnyView(anyview: ffiToggle.label, env: env)
        let binding: WuiBinding<Bool> = WuiBinding(ffiToggle.toggle)
        self.init(label: labelView, binding: binding)
    }

    // MARK: - Designated Init

    init(label: WuiAnyView, binding: WuiBinding<Bool>) {
        self.binding = binding
        self.labelView = label
        super.init(frame: .zero)
        configureSubviews()
        syncToggleState()
        setupAction()
        startWatchingBinding()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - WuiComponent

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        let labelSize = labelView.sizeThatFits(WuiProposalSize())
        let toggleSize = toggle.intrinsicContentSize
        let hasLabel = labelSize.width > 0 && labelSize.height > 0

        // Calculate minimum width needed
        var minWidth: CGFloat = toggleSize.width
        var maxHeight: CGFloat = toggleSize.height

        if hasLabel {
            minWidth += horizontalSpacing + labelSize.width
            maxHeight = max(maxHeight, labelSize.height)
        }

        // With label: expand horizontally to fill proposed width (Rust controls stretchAxis)
        // Without label: content-sized (just switch)
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
        // Use AutoLayout for internal component layout
        labelView.translatesAutoresizingMaskIntoConstraints = false
        toggle.translatesAutoresizingMaskIntoConstraints = false

        addSubview(labelView)
        addSubview(toggle)

        // Ensure label doesn't get compressed - it should show its full content
        #if canImport(UIKit)
        labelView.setContentCompressionResistancePriority(.required, for: .horizontal)
        labelView.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        #elseif canImport(AppKit)
        labelView.setContentCompressionResistancePriority(.required, for: .horizontal)
        labelView.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        #endif

        // Layout: [label] --- flexible space --- [toggle]
        // Label on leading, toggle on trailing, both vertically centered
        NSLayoutConstraint.activate([
            // Label: leading, vertically centered
            labelView.leadingAnchor.constraint(equalTo: leadingAnchor),
            labelView.centerYAnchor.constraint(equalTo: centerYAnchor),

            // Toggle: trailing, vertically centered
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),

            // Prevent overlap: label must not extend past toggle
            labelView.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -horizontalSpacing),
        ])
    }

    private func syncToggleState() {
        #if canImport(UIKit)
        toggle.isOn = binding.value
        #elseif canImport(AppKit)
        toggle.state = binding.value ? .on : .off
        #endif
    }

    private func setupAction() {
        #if canImport(UIKit)
        toggle.addTarget(self, action: #selector(valueChanged), for: .valueChanged)
        #elseif canImport(AppKit)
        toggle.target = self
        toggle.action = #selector(valueChanged)
        #endif
    }

    private func startWatchingBinding() {
        bindingWatcher = binding.watch { [weak self] newValue, metadata in
            guard let self else { return }
            let animation = parseAnimation(metadata.getAnimation())
            #if canImport(UIKit)
            if toggle.isOn == newValue { return }
            toggle.setOn(newValue, animated: shouldAnimate(animation))
            #elseif canImport(AppKit)
            let newState: NSControl.StateValue = newValue ? .on : .off
            if toggle.state == newState { return }
            withPlatformAnimation(metadata) {
                self.toggle.state = newState
            }
            #endif
        }
    }

    @objc private func valueChanged() {
        #if canImport(UIKit)
        binding.value = toggle.isOn
        #elseif canImport(AppKit)
        binding.value = toggle.state == .on
        #endif
    }

    // MARK: - Update Methods

    func updateLabel(_ label: WuiAnyView) {
        guard label !== labelView else { return }
        labelView.removeFromSuperview()

        labelView = label
        labelView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(labelView)

        // Set content priorities
        #if canImport(UIKit)
        labelView.setContentCompressionResistancePriority(.required, for: .horizontal)
        labelView.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        #elseif canImport(AppKit)
        labelView.setContentCompressionResistancePriority(.required, for: .horizontal)
        labelView.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        #endif

        // Re-establish constraints for new label
        NSLayoutConstraint.activate([
            labelView.leadingAnchor.constraint(equalTo: leadingAnchor),
            labelView.centerYAnchor.constraint(equalTo: centerYAnchor),
            labelView.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -horizontalSpacing),
        ])
    }

    func updateBinding(_ newBinding: WuiBinding<Bool>) {
        guard newBinding !== binding else { return }
        bindingWatcher = nil
        binding = newBinding
        #if canImport(UIKit)
        toggle.setOn(newBinding.value, animated: false)
        #elseif canImport(AppKit)
        toggle.state = newBinding.value ? .on : .off
        #endif
        startWatchingBinding()
    }
}
