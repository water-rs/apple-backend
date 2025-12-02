// WuiToggle.swift
// Toggle/Switch component - merged UIKit and AppKit implementation
//
// # Layout Behavior
// Toggle is content-sized - it uses its intrinsic size based on label and switch control.
// Horizontal layout: label on left, switch on right with fixed spacing.
// Does not expand to fill available space.
//
// // INTERNAL: Layout Contract for Backend Implementers
// // - stretchAxis: .none (content-sized, does not expand)
// // - sizeThatFits: Returns intrinsic size (label + spacing + switch)
// // - Priority: 0 (default)

import CWaterUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
final class WuiToggle: PlatformView, WuiComponent {
    static let id: String = decodeViewIdentifier(waterui_toggle_id())

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
        // Toggle is Content-Sized per LAYOUT_SPEC.md
        // Content-Sized views ALWAYS return their intrinsic size, regardless of proposal
        let labelSize = labelView.sizeThatFits(WuiProposalSize())
        let toggleSize = toggle.intrinsicContentSize

        // Intrinsic size: label width + spacing + toggle width, max height
        let intrinsicWidth = labelSize.width + horizontalSpacing + toggleSize.width
        let intrinsicHeight = max(labelSize.height, toggleSize.height)

        // Content-Sized: always return intrinsic size (don't expand to proposal)
        return CGSize(width: intrinsicWidth, height: intrinsicHeight)
    }

    // MARK: - Layout

    #if canImport(UIKit)
    override func layoutSubviews() {
        super.layoutSubviews()
        performLayout()
    }
    #elseif canImport(AppKit)
    override func layout() {
        super.layout()
        performLayout()
    }

    override var isFlipped: Bool { true }
    #endif

    /// Shared layout logic for both UIKit and AppKit
    private func performLayout() {
        let boundsHeight = bounds.height

        // Calculate sizes
        let labelSize = labelView.sizeThatFits(WuiProposalSize())
        let toggleSize = toggle.intrinsicContentSize

        // Layout label on left, vertically centered
        let labelY = (boundsHeight - labelSize.height) / 2
        labelView.frame = CGRect(
            x: 0,
            y: labelY,
            width: labelSize.width,
            height: labelSize.height
        )

        // Layout toggle on right of label, vertically centered
        let toggleX = labelSize.width + horizontalSpacing
        let toggleY = (boundsHeight - toggleSize.height) / 2
        toggle.frame = CGRect(
            x: toggleX,
            y: toggleY,
            width: toggleSize.width,
            height: toggleSize.height
        )
    }

    // MARK: - Configuration

    private func configureSubviews() {
        // Manual frame layout - just add subviews, performLayout() will position them
        addSubview(labelView)
        addSubview(toggle)
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
            #if canImport(UIKit)
            if toggle.isOn == newValue { return }
            toggle.setOn(newValue, animated: metadata.getAnimation() != nil)
            #elseif canImport(AppKit)
            let newState: NSControl.StateValue = newValue ? .on : .off
            if toggle.state == newState { return }
            if metadata.getAnimation() != nil {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.15
                    context.allowsImplicitAnimation = true
                    toggle.state = newState
                }
            } else {
                toggle.state = newState
            }
            #endif
        }
    }

    private func setNeedsLayoutCompat() {
        #if canImport(UIKit)
        setNeedsLayout()
        #elseif canImport(AppKit)
        needsLayout = true
        #endif
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
        addSubview(label)
        labelView = label
        setNeedsLayoutCompat()
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
