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
  private let disabled: WuiComputed<Bool>?
  private var disabledWatcher: WatcherGuard?
  private var accessibility: WuiControlAccessibility?

  // Layout constants
  private let verticalSpacing: CGFloat = 4.0
  private let horizontalSpacing: CGFloat = 8.0

  // AutoLayout constraints (stored for dynamic updates)
  private var activeConstraints: [NSLayoutConstraint] = []

  // MARK: - WuiComponent Init

  convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
    let stretchAxis = WuiStretchAxis(waterui_view_stretch_axis(anyview))
    let ffiSlider: CWaterUI.WuiSlider = waterui_force_as_slider(anyview)
    let labelView = WuiAnyView(anyview: ffiSlider.label.view, env: env)
    let minLabelView = WuiAnyView(anyview: ffiSlider.min_value_label, env: env)
    let maxLabelView = WuiAnyView(anyview: ffiSlider.max_value_label, env: env)
    let binding = WuiBinding<Double>(ffiSlider.value)
    let disabled = ffiSlider.disabled.map { WuiComputed<Bool>($0) }
    self.init(
      stretchAxis: stretchAxis,
      label: labelView,
      minLabel: minLabelView,
      maxLabel: maxLabelView,
      range: ffiSlider.range,
      binding: binding,
      disabled: disabled,
      semanticLabel: ffiSlider.label
    )
  }

  // MARK: - Designated Init

  init(
    stretchAxis: WuiStretchAxis,
    label: WuiAnyView,
    minLabel: WuiAnyView,
    maxLabel: WuiAnyView,
    range: WuiRange_f64,
    binding: WuiBinding<Double>,
    disabled: WuiComputed<Bool>? = nil,
    semanticLabel: CWaterUI.WuiLabel
  ) {
    self.disabled = disabled
    self.stretchAxis = stretchAxis
    self.labelView = label
    self.minLabelView = minLabel
    self.maxLabelView = maxLabel
    self.range = range
    self.binding = binding
    super.init(frame: .zero)
    configureSubviews()
    configureSlider()
    updateLabel(label, force: true)
    updateMinLabel(minLabel, force: true)
    updateMaxLabel(maxLabel, force: true)
    updateRange(range)
    updateBinding(binding, force: true)
    startWatchingDisabled()
    accessibility = WuiControlAccessibility(
      consuming: semanticLabel,
      target: slider,
      visualLabel: label
    )
  }

  private func startWatchingDisabled() {
    guard let disabled else { return }
    disabledWatcher = disabled.watch { [weak self] isDisabled, _ in
      self?.applyDisabled(isDisabled)
    }
    applyDisabled(disabled.value)
  }

  private func applyDisabled(_ isDisabled: Bool) {
    slider.isEnabled = !isDisabled
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
    let minWidth = max(
      labelSize.width,
      minLabelSize.width + horizontalSpacing + minSliderTrackWidth + horizontalSpacing
        + maxLabelSize.width)

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
    NSLayoutConstraint.deactivate(activeConstraints)

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
    var constraints = [NSLayoutConstraint]()
    constraints.append(contentsOf: [
      labelView.topAnchor.constraint(equalTo: topAnchor),
      labelView.leadingAnchor.constraint(equalTo: leadingAnchor),
    ])

    // Slider row: [minLabel] - [slider] - [maxLabel]
    // All vertically centered relative to each other, below label

    // Min label: leading, below label
    constraints.append(contentsOf: [
      minLabelView.topAnchor.constraint(equalTo: labelView.bottomAnchor, constant: verticalSpacing),
      minLabelView.leadingAnchor.constraint(equalTo: leadingAnchor),
      minLabelView.centerYAnchor.constraint(equalTo: slider.centerYAnchor),
    ])

    // Max label: trailing, aligned with slider row
    constraints.append(contentsOf: [
      maxLabelView.trailingAnchor.constraint(equalTo: trailingAnchor),
      maxLabelView.centerYAnchor.constraint(equalTo: slider.centerYAnchor),
    ])

    // Slider: between minLabel and maxLabel, below label
    constraints.append(contentsOf: [
      slider.topAnchor.constraint(equalTo: labelView.bottomAnchor, constant: verticalSpacing),
      slider.leadingAnchor.constraint(
        equalTo: minLabelView.trailingAnchor, constant: horizontalSpacing),
      slider.trailingAnchor.constraint(
        equalTo: maxLabelView.leadingAnchor, constant: -horizontalSpacing),
    ])

    NSLayoutConstraint.activate(constraints)
    activeConstraints = constraints
  }

  // MARK: - Update Methods

  func updateLabel(_ newLabel: WuiAnyView, force: Bool = false) {
    guard force || newLabel !== labelView else { return }
    labelView.removeFromSuperview()
    labelView = newLabel
    addSubview(labelView)
    setupConstraints()
  }

  func updateMinLabel(_ newLabel: WuiAnyView, force: Bool = false) {
    guard force || newLabel !== minLabelView else { return }
    minLabelView.removeFromSuperview()
    minLabelView = newLabel
    addSubview(minLabelView)
    setupConstraints()
  }

  func updateMaxLabel(_ newLabel: WuiAnyView, force: Bool = false) {
    guard force || newLabel !== maxLabelView else { return }
    maxLabelView.removeFromSuperview()
    maxLabelView = newLabel
    addSubview(maxLabelView)
    setupConstraints()
  }

  func updateBinding(_ newBinding: WuiBinding<Double>, force: Bool = false) {
    guard force || newBinding !== binding else { return }
    bindingWatcher = nil
    binding = newBinding
    startBindingWatcher()
    #if canImport(UIKit)
      slider.setValue(Float(clampedValue(newBinding.value)), animated: false)
    #elseif canImport(AppKit)
      slider.doubleValue = clampedValue(newBinding.value)
    #endif
  }

  func updateRange(_ newRange: WuiRange_f64) {
    range = newRange
    #if canImport(UIKit)
      slider.minimumValue = Float(newRange.start)
      slider.maximumValue = Float(newRange.end)
      slider.setValue(Float(clampedValue(binding.value)), animated: false)
    #elseif canImport(AppKit)
      slider.minValue = newRange.start
      slider.maxValue = newRange.end
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
      #if canImport(UIKit)
        let clampedFloat = Float(clamped)
        if slider.value == clampedFloat { return }
        let animated = shouldAnimate(parseAnimation(metadata.getAnimation()))
        slider.setValue(clampedFloat, animated: animated)
      #elseif canImport(AppKit)
        if slider.doubleValue == clamped { return }
        withPlatformAnimation(metadata) {
          self.slider.doubleValue = clamped
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
