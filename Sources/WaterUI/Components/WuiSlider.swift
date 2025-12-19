// WuiSlider.swift
// Slider component - merged UIKit and AppKit implementation
//
// # Layout Behavior
// Slider expands horizontally to fill available width, but has fixed intrinsic height.
// Includes optional label at top and min/max value labels beside the track.
// Use frame modifiers to constrain width if needed.
//
// // INTERNAL: Layout Contract for Backend Implementers
// // - stretchAxis: .horizontal (expands width, intrinsic height)
// // - sizeThatFits: Returns proposed width (min 50pt track), intrinsic height
// // - Priority: 0 (default)

import CWaterUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
final class WuiSlider: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_slider_id() }

    private(set) var stretchAxis: WuiStretchAxis

    #if canImport(UIKit)
    private let slider = UISlider()
    #elseif canImport(AppKit)
    private let slider = NSSlider()
    #endif
    private var bindingWatcher: WatcherGuard?

    private var labelView: WuiAnyView
    private var minLabelView: WuiAnyView
    private var maxLabelView: WuiAnyView
    private var binding: WuiBinding<Double>
    private var range: WuiRange_f64

    // Layout constants
    private let verticalSpacing: CGFloat = 4.0
    private let horizontalSpacing: CGFloat = 8.0

    // AutoLayout constraints (stored for dynamic updates)
    private var sliderLeadingConstraint: NSLayoutConstraint?
    private var sliderTrailingConstraint: NSLayoutConstraint?

    // MARK: - WuiComponent Init

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
        let stretchAxis = WuiStretchAxis(waterui_view_stretch_axis(anyview))
        let ffiSlider: CWaterUI.WuiSlider = waterui_force_as_slider(anyview)
        let labelView = WuiAnyView(anyview: ffiSlider.label, env: env)
        let minLabelView = WuiAnyView(anyview: ffiSlider.min_value_label, env: env)
        let maxLabelView = WuiAnyView(anyview: ffiSlider.max_value_label, env: env)
        let binding = WuiBinding<Double>(ffiSlider.value)
        self.init(
            stretchAxis: stretchAxis,
            label: labelView,
            minLabel: minLabelView,
            maxLabel: maxLabelView,
            range: ffiSlider.range,
            binding: binding
        )
    }

    // MARK: - Designated Init

    init(
        stretchAxis: WuiStretchAxis,
        label: WuiAnyView,
        minLabel: WuiAnyView,
        maxLabel: WuiAnyView,
        range: WuiRange_f64,
        binding: WuiBinding<Double>
    ) {
        self.stretchAxis = stretchAxis
        self.labelView = label
        self.minLabelView = minLabel
        self.maxLabelView = maxLabel
        self.range = range
        self.binding = binding
        super.init(frame: .zero)
        configureSubviews()
        configureSlider()
        startBindingWatcher()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - WuiComponent

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        // Slider is axis-expanding on width per LAYOUT_SPEC.md
        // It uses isStretch: true to expand, so here we report MINIMUM usable size
        let labelSize = labelView.sizeThatFits(WuiProposalSize())
        let minLabelSize = minLabelView.sizeThatFits(WuiProposalSize())
        let maxLabelSize = maxLabelView.sizeThatFits(WuiProposalSize())
        let sliderHeight = slider.intrinsicContentSize.height

        // Slider row height: max of slider and labels
        let sliderRowHeight = max(sliderHeight, max(minLabelSize.height, maxLabelSize.height))

        // Intrinsic height: label height + spacing + slider row height
        let intrinsicHeight = labelSize.height + verticalSpacing + sliderRowHeight

        // For width: report MINIMUM usable size
        // The minimum width ensures labels fit and slider track is usable (at least 50pt)
        let minSliderTrackWidth: CGFloat = 50.0
        let minWidth = max(labelSize.width, minLabelSize.width + horizontalSpacing + minSliderTrackWidth + horizontalSpacing + maxLabelSize.width)

        // When width is proposed, use it (but not less than minimum)
        // When None, return minimum - isStretch:true will expand it to fill remaining space
        let width = proposal.width.map { max(CGFloat($0), minWidth) } ?? minWidth
        let height = proposal.height.map { CGFloat($0) } ?? intrinsicHeight

        return CGSize(width: width, height: max(height, intrinsicHeight))
    }

    // MARK: - Layout

    #if canImport(AppKit)
    override var isFlipped: Bool { true }
    #endif

    private func setupConstraints() {
        labelView.translatesAutoresizingMaskIntoConstraints = false
        minLabelView.translatesAutoresizingMaskIntoConstraints = false
        slider.translatesAutoresizingMaskIntoConstraints = false
        maxLabelView.translatesAutoresizingMaskIntoConstraints = false

        // Ensure labels don't get compressed - they should show their full content
        #if canImport(UIKit)
        labelView.setContentCompressionResistancePriority(.required, for: .horizontal)
        minLabelView.setContentCompressionResistancePriority(.required, for: .horizontal)
        maxLabelView.setContentCompressionResistancePriority(.required, for: .horizontal)
        #elseif canImport(AppKit)
        labelView.setContentCompressionResistancePriority(.required, for: .horizontal)
        minLabelView.setContentCompressionResistancePriority(.required, for: .horizontal)
        maxLabelView.setContentCompressionResistancePriority(.required, for: .horizontal)
        #endif

        // Label at top-leading
        NSLayoutConstraint.activate([
            labelView.topAnchor.constraint(equalTo: topAnchor),
            labelView.leadingAnchor.constraint(equalTo: leadingAnchor),
        ])

        // Slider row: [minLabel] - [slider] - [maxLabel]
        // All vertically centered relative to each other, below label

        // Min label: leading, below label
        NSLayoutConstraint.activate([
            minLabelView.topAnchor.constraint(equalTo: labelView.bottomAnchor, constant: verticalSpacing),
            minLabelView.leadingAnchor.constraint(equalTo: leadingAnchor),
            minLabelView.centerYAnchor.constraint(equalTo: slider.centerYAnchor),
        ])

        // Max label: trailing, aligned with slider row
        NSLayoutConstraint.activate([
            maxLabelView.trailingAnchor.constraint(equalTo: trailingAnchor),
            maxLabelView.centerYAnchor.constraint(equalTo: slider.centerYAnchor),
        ])

        // Slider: between minLabel and maxLabel, below label
        sliderLeadingConstraint = slider.leadingAnchor.constraint(equalTo: minLabelView.trailingAnchor, constant: horizontalSpacing)
        sliderTrailingConstraint = slider.trailingAnchor.constraint(equalTo: maxLabelView.leadingAnchor, constant: -horizontalSpacing)

        NSLayoutConstraint.activate([
            slider.topAnchor.constraint(equalTo: labelView.bottomAnchor, constant: verticalSpacing),
            sliderLeadingConstraint!,
            sliderTrailingConstraint!,
        ])
    }

    // MARK: - Update Methods

    func updateLabel(_ newLabel: WuiAnyView) {
        guard newLabel !== labelView else { return }
        labelView.removeFromSuperview()

        labelView = newLabel
        labelView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(labelView)

        #if canImport(UIKit)
        labelView.setContentCompressionResistancePriority(.required, for: .horizontal)
        #elseif canImport(AppKit)
        labelView.setContentCompressionResistancePriority(.required, for: .horizontal)
        #endif

        NSLayoutConstraint.activate([
            labelView.topAnchor.constraint(equalTo: topAnchor),
            labelView.leadingAnchor.constraint(equalTo: leadingAnchor),
        ])
    }

    func updateMinLabel(_ newLabel: WuiAnyView) {
        guard newLabel !== minLabelView else { return }
        minLabelView.removeFromSuperview()

        minLabelView = newLabel
        minLabelView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(minLabelView)

        #if canImport(UIKit)
        minLabelView.setContentCompressionResistancePriority(.required, for: .horizontal)
        #elseif canImport(AppKit)
        minLabelView.setContentCompressionResistancePriority(.required, for: .horizontal)
        #endif

        NSLayoutConstraint.activate([
            minLabelView.topAnchor.constraint(equalTo: labelView.bottomAnchor, constant: verticalSpacing),
            minLabelView.leadingAnchor.constraint(equalTo: leadingAnchor),
            minLabelView.centerYAnchor.constraint(equalTo: slider.centerYAnchor),
        ])
    }

    func updateMaxLabel(_ newLabel: WuiAnyView) {
        guard newLabel !== maxLabelView else { return }
        maxLabelView.removeFromSuperview()

        maxLabelView = newLabel
        maxLabelView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(maxLabelView)

        #if canImport(UIKit)
        maxLabelView.setContentCompressionResistancePriority(.required, for: .horizontal)
        #elseif canImport(AppKit)
        maxLabelView.setContentCompressionResistancePriority(.required, for: .horizontal)
        #endif

        NSLayoutConstraint.activate([
            maxLabelView.trailingAnchor.constraint(equalTo: trailingAnchor),
            maxLabelView.centerYAnchor.constraint(equalTo: slider.centerYAnchor),
        ])
    }

    func updateBinding(_ newBinding: WuiBinding<Double>) {
        guard newBinding !== binding else { return }
        bindingWatcher = nil
        binding = newBinding
        #if canImport(UIKit)
        slider.setValue(Float(clampedValue(newBinding.value)), animated: false)
        #elseif canImport(AppKit)
        slider.doubleValue = clampedValue(newBinding.value)
        #endif
        startBindingWatcher()
    }

    func updateRange(_ range: WuiRange_f64) {
        self.range = range
        #if canImport(UIKit)
        slider.minimumValue = Float(range.start)
        slider.maximumValue = Float(range.end)
        slider.setValue(Float(clampedValue(binding.value)), animated: false)
        #elseif canImport(AppKit)
        slider.minValue = range.start
        slider.maxValue = range.end
        slider.doubleValue = clampedValue(binding.value)
        #endif
    }

    // MARK: - Configuration

    private func configureSubviews() {
        addSubview(labelView)
        addSubview(minLabelView)
        addSubview(slider)
        addSubview(maxLabelView)
        setupConstraints()
    }

    private func configureSlider() {
        #if canImport(UIKit)
        slider.minimumValue = Float(range.start)
        slider.maximumValue = Float(range.end)
        slider.value = Float(clampedValue(binding.value))
        slider.addTarget(self, action: #selector(valueChanged), for: .valueChanged)
        #elseif canImport(AppKit)
        slider.minValue = range.start
        slider.maxValue = range.end
        slider.doubleValue = clampedValue(binding.value)
        slider.target = self
        slider.action = #selector(valueChanged)
        slider.isContinuous = true
        #endif
    }

    private func startBindingWatcher() {
        bindingWatcher = binding.watch { [weak self] newValue, metadata in
            guard let self else { return }
            let clamped = clampedValue(newValue)
            let animation = parseAnimation(metadata.getAnimation())
            let animated = shouldAnimate(animation)
            #if canImport(UIKit)
            let clampedFloat = Float(clamped)
            if slider.value == clampedFloat { return }
            slider.setValue(clampedFloat, animated: animated)
            #elseif canImport(AppKit)
            if slider.doubleValue == clamped { return }
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    context.allowsImplicitAnimation = true
                    slider.doubleValue = clamped
                }
            } else {
                slider.doubleValue = clamped
            }
            #endif
        }
    }

    private func clampedValue(_ value: Double) -> Double {
        min(max(value, range.start), range.end)
    }

    @objc private func valueChanged() {
        #if canImport(UIKit)
        binding.value = Double(slider.value)
        #elseif canImport(AppKit)
        binding.value = slider.doubleValue
        #endif
    }
}
