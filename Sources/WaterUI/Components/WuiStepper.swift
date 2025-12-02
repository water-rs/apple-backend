// WuiStepper.swift
// Stepper component - merged UIKit and AppKit implementation
//
// # Layout Behavior
// Stepper is content-sized - it uses its intrinsic size based on label and controls.
// Horizontal layout: label on left, value display and stepper buttons on right.
// Does not expand to fill available space.
//
// // INTERNAL: Layout Contract for Backend Implementers
// // - stretchAxis: .none (content-sized, does not expand)
// // - sizeThatFits: Returns intrinsic size (label + value + stepper)
// // - Priority: 0 (default)

import CWaterUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
final class WuiStepper: PlatformView, WuiComponent {
    static let id: String = decodeViewIdentifier(waterui_stepper_id())

    #if canImport(UIKit)
    private let stepper = UIStepper()
    private let valueLabel = UILabel()
    #elseif canImport(AppKit)
    private let stepper = NSStepper()
    private let valueLabel = NSTextField(labelWithString: "")
    #endif
    private var bindingWatcher: WatcherGuard?
    private var isSyncingFromBinding = false

    private var labelView: WuiAnyView
    private var binding: WuiBinding<Int32>
    private var step: WuiComputed<Int32>

    // Layout constants
    private let spacing: CGFloat = 8.0   // Horizontal spacing between elements

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
        // Stepper is Content-Sized per LAYOUT_SPEC.md
        // Content-Sized views ALWAYS return their intrinsic size, regardless of proposal
        let labelSize = labelView.sizeThatFits(WuiProposalSize())
        let stepperSize = stepper.intrinsicContentSize
        let valueLabelSize = calculateValueLabelSize()

        // Layout: [label] [valueLabel] [stepper]
        // Only add spacing between elements that exist
        let hasLabel = labelSize.width > 0

        var intrinsicWidth: CGFloat = 0
        var intrinsicHeight: CGFloat = 0

        // Add label if present
        if hasLabel {
            intrinsicWidth += labelSize.width + spacing
            intrinsicHeight = max(intrinsicHeight, labelSize.height)
        }

        // Add value label + spacing + stepper
        intrinsicWidth += valueLabelSize.width + spacing + stepperSize.width
        intrinsicHeight = max(intrinsicHeight, valueLabelSize.height, stepperSize.height)

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
        let stepperSize = stepper.intrinsicContentSize
        let valueLabelSize = calculateValueLabelSize()
        let hasLabel = labelSize.width > 0

        var currentX: CGFloat = 0

        // Layout label on left, vertically centered (if present)
        if hasLabel {
            let labelY = (boundsHeight - labelSize.height) / 2
            labelView.frame = CGRect(
                x: currentX,
                y: labelY,
                width: labelSize.width,
                height: labelSize.height
            )
            currentX += labelSize.width + spacing
        } else {
            labelView.frame = .zero
        }

        // Layout value label, vertically centered
        let valueLabelY = (boundsHeight - valueLabelSize.height) / 2
        valueLabel.frame = CGRect(
            x: currentX,
            y: valueLabelY,
            width: valueLabelSize.width,
            height: valueLabelSize.height
        )
        currentX += valueLabelSize.width + spacing

        // Layout stepper, vertically centered
        let stepperY = (boundsHeight - stepperSize.height) / 2
        stepper.frame = CGRect(
            x: currentX,
            y: stepperY,
            width: stepperSize.width,
            height: stepperSize.height
        )
    }

    // MARK: - Update Methods

    func updateLabel(_ newLabel: WuiAnyView) {
        guard newLabel !== labelView else { return }
        labelView.removeFromSuperview()
        addSubview(newLabel)
        labelView = newLabel
        setNeedsLayoutCompat()
    }

    func updateBinding(_ newBinding: WuiBinding<Int32>) {
        guard newBinding !== binding else { return }
        bindingWatcher = nil
        binding = newBinding
        #if canImport(UIKit)
        stepper.value = Double(newBinding.value)
        valueLabel.text = String(newBinding.value)
        #elseif canImport(AppKit)
        stepper.integerValue = Int(newBinding.value)
        valueLabel.stringValue = String(newBinding.value)
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
        // Manual frame layout - just add subviews, performLayout() will position them
        addSubview(labelView)
        addSubview(valueLabel)
        addSubview(stepper)

        #if canImport(UIKit)
        valueLabel.text = String(binding.value)
        #elseif canImport(AppKit)
        valueLabel.stringValue = String(binding.value)
        #endif
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
            valueLabel.text = String(newValue)
            #elseif canImport(AppKit)
            stepper.integerValue = Int(newValue)
            valueLabel.stringValue = String(newValue)
            #endif
            isSyncingFromBinding = false
        }
    }

    private func setNeedsLayoutCompat() {
        #if canImport(UIKit)
        setNeedsLayout()
        #elseif canImport(AppKit)
        needsLayout = true
        #endif
    }

    /// Calculates the size needed for the value label based on current text content.
    /// Uses boundingRect for accurate text measurement.
    private func calculateValueLabelSize() -> CGSize {
        #if canImport(UIKit)
        guard let text = valueLabel.text, !text.isEmpty else {
            return valueLabel.intrinsicContentSize
        }
        let font = valueLabel.font ?? UIFont.systemFont(ofSize: UIFont.systemFontSize)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let boundingRect = (text as NSString).boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes,
            context: nil
        )
        // Add small padding for safety
        return CGSize(width: ceil(boundingRect.width) + 2, height: ceil(boundingRect.height))
        #elseif canImport(AppKit)
        let text = valueLabel.stringValue
        guard !text.isEmpty else {
            return valueLabel.intrinsicContentSize
        }
        let font = valueLabel.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let boundingRect = (text as NSString).boundingRect(
            with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes,
            context: nil
        )
        // Add small padding for safety
        return CGSize(width: ceil(boundingRect.width) + 2, height: ceil(boundingRect.height))
        #endif
    }

    @objc private func valueChanged() {
        guard !isSyncingFromBinding else { return }
        #if canImport(UIKit)
        binding.value = Int32(stepper.value)
        valueLabel.text = String(Int32(stepper.value))
        #elseif canImport(AppKit)
        binding.value = Int32(stepper.integerValue)
        valueLabel.stringValue = String(stepper.integerValue)
        #endif
    }
}
