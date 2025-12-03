// WuiStepper.swift
// Stepper component - merged UIKit and AppKit implementation
//
// # Layout Behavior
// Stepper expands horizontally to fill available space (stretchAxis from Rust).
// Horizontal layout: [label] --- flexible space --- [+/- buttons]
// Label on left, buttons on right, space distributed between.
//
// // INTERNAL: Layout Contract for Backend Implementers
// // - stretchAxis: Determined by Rust side (Horizontal for stepper with label)
// // - sizeThatFits: Returns proposed width (or minimum), intrinsic height
// // - Priority: 0 (default)

import CWaterUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
final class WuiStepper: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_stepper_id() }

    #if canImport(UIKit)
    private let stepper = UIStepper()
    #elseif canImport(AppKit)
    private let stepper = NSStepper()
    #endif
    private var bindingWatcher: WatcherGuard?
    private var isSyncingFromBinding = false

    private var labelView: WuiAnyView
    private var binding: WuiBinding<Int32>
    private var step: WuiComputed<Int32>

    // Layout constants
    private let spacing: CGFloat = 8.0

    // MARK: - WuiComponent Init

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
        let ffiStepper: CWaterUI.WuiStepper = waterui_force_as_stepper(anyview)
        let labelView = WuiAnyView(anyview: ffiStepper.label, env: env)
        let binding = WuiBinding<Int32>(ffiStepper.value)
        let step = WuiComputed<Int32>(ffiStepper.step)
        self.init(label: labelView, binding: binding, step: step)
    }

    // MARK: - Designated Init

    init(label: WuiAnyView, binding: WuiBinding<Int32>, step: WuiComputed<Int32>) {
        self.labelView = label
        self.binding = binding
        self.step = step
        super.init(frame: .zero)
        configureSubviews()
        configureStepper()
        startBindingWatcher()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - WuiComponent

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        let labelSize = labelView.sizeThatFits(WuiProposalSize())
        let stepperSize = stepper.intrinsicContentSize
        let hasLabel = labelSize.width > 0 && labelSize.height > 0

        // Calculate minimum width needed
        var minWidth: CGFloat = stepperSize.width
        var maxHeight: CGFloat = stepperSize.height

        if hasLabel {
            minWidth += spacing + labelSize.width
            maxHeight = max(maxHeight, labelSize.height)
        }

        // With label: expand horizontally to fill proposed width
        // Without label: content-sized (just buttons)
        let finalWidth: CGFloat
        if hasLabel, let proposedWidth = proposal.width {
            finalWidth = max(CGFloat(proposedWidth), minWidth)
        } else {
            finalWidth = minWidth
        }

        return CGSize(width: finalWidth, height: maxHeight)
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

    private func performLayout() {
        let boundsWidth = bounds.width
        let boundsHeight = bounds.height

        // Calculate sizes
        let stepperSize = stepper.intrinsicContentSize
        let labelSize = labelView.sizeThatFits(WuiProposalSize())
        let hasLabel = labelSize.width > 0 && labelSize.height > 0

        if hasLabel {
            // With label: [label] --- flexible space --- [+/- buttons]
            // Label on left, buttons on right

            // 1. Stepper buttons (rightmost)
            let stepperX = boundsWidth - stepperSize.width
            let stepperY = (boundsHeight - stepperSize.height) / 2
            stepper.frame = CGRect(
                x: stepperX,
                y: stepperY,
                width: stepperSize.width,
                height: stepperSize.height
            )

            // 2. Label view (leftmost)
            let labelY = (boundsHeight - labelSize.height) / 2
            labelView.frame = CGRect(
                x: 0,
                y: labelY,
                width: labelSize.width,
                height: labelSize.height
            )
        } else {
            // Without label: just buttons, left-aligned
            labelView.frame = .zero
            let stepperY = (boundsHeight - stepperSize.height) / 2
            stepper.frame = CGRect(
                x: 0,
                y: stepperY,
                width: stepperSize.width,
                height: stepperSize.height
            )
        }
    }

    // MARK: - Update Methods

    func updateLabel(_ newLabel: WuiAnyView) {
        guard newLabel !== labelView else { return }
        labelView.removeFromSuperview()
        labelView = newLabel
        addSubview(newLabel)
        setNeedsLayoutCompat()
    }

    func updateBinding(_ newBinding: WuiBinding<Int32>) {
        guard newBinding !== binding else { return }
        bindingWatcher = nil
        binding = newBinding
        #if canImport(UIKit)
        stepper.value = Double(newBinding.value)
        #elseif canImport(AppKit)
        stepper.integerValue = Int(newBinding.value)
        #endif
        startBindingWatcher()
    }

    func updateStep(_ newStep: WuiComputed<Int32>) {
        guard newStep !== step else { return }
        step = newStep
        #if canImport(UIKit)
        stepper.stepValue = Double(newStep.value)
        #elseif canImport(AppKit)
        stepper.increment = Double(newStep.value)
        #endif
    }

    // MARK: - Configuration

    private func configureSubviews() {
        addSubview(labelView)
        addSubview(stepper)
    }

    private func configureStepper() {
        #if canImport(UIKit)
        stepper.minimumValue = -1000000
        stepper.maximumValue = 1000000
        stepper.stepValue = Double(step.value)
        stepper.value = Double(binding.value)
        stepper.addTarget(self, action: #selector(valueChanged), for: .valueChanged)
        #elseif canImport(AppKit)
        stepper.minValue = -1000000
        stepper.maxValue = 1000000
        stepper.increment = Double(step.value)
        stepper.integerValue = Int(binding.value)
        stepper.target = self
        stepper.action = #selector(valueChanged)
        #endif
    }

    private func startBindingWatcher() {
        bindingWatcher = binding.watch { [weak self] newValue, _ in
            guard let self, !isSyncingFromBinding else { return }
            isSyncingFromBinding = true
            #if canImport(UIKit)
            stepper.value = Double(newValue)
            #elseif canImport(AppKit)
            stepper.integerValue = Int(newValue)
            #endif
            isSyncingFromBinding = false
            // Trigger layout update since label content may have changed
            setNeedsLayoutCompat()
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
        guard !isSyncingFromBinding else { return }
        #if canImport(UIKit)
        binding.value = Int32(stepper.value)
        #elseif canImport(AppKit)
        binding.value = Int32(stepper.integerValue)
        #endif
    }
}
