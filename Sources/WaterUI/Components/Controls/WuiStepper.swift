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

  private let labelView: WuiAnyView
  private let formattedValueLabel: PlatformLabel?
  private let binding: WuiBinding<Int32>
  private let range: CWaterUI.WuiRange_i32
  private let env: WuiEnvironment
  private var bindingWatcher: WatcherGuard?
  private var stepObservation: WuiComputedObservation<Int32>?
  private var valueFormatterObservation: WuiComputedObservation<WuiStyledStr>?
  private var valueRenderer: WuiStyledStrRenderer?
  private var accessibility: WuiControlAccessibility?
  private var isSyncingFromBinding = false
  private let spacing: CGFloat = 8

  convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
    let stepper = waterui_force_as_stepper(anyview)
    let valueFormatter = stepper.value_formatter.map {
      WuiComputed<WuiStyledStr>($0)
    }
    self.init(
      label: WuiAnyView(anyview: stepper.label.view, env: env),
      binding: WuiBinding<Int32>(stepper.value),
      step: WuiComputed<Int32>(stepper.step),
      valueFormatter: valueFormatter,
      range: stepper.range,
      semanticLabel: stepper.label,
      env: env
    )
  }

  private init(
    label: WuiAnyView,
    binding: WuiBinding<Int32>,
    step: WuiComputed<Int32>,
    valueFormatter: WuiComputed<WuiStyledStr>?,
    range: CWaterUI.WuiRange_i32,
    semanticLabel: CWaterUI.WuiLabel,
    env: WuiEnvironment
  ) {
    precondition(range.start <= range.end, "WaterUI Stepper range must not be empty")
    self.labelView = label
    self.binding = binding
    self.range = range
    self.env = env
    #if canImport(UIKit)
      self.formattedValueLabel = valueFormatter.map { _ in UILabel() }
    #elseif canImport(AppKit)
      self.formattedValueLabel = valueFormatter.map { _ in NSTextField(labelWithString: "") }
    #endif
    super.init(frame: .zero)

    configureSubviews()
    startBindingWatcher()
    configureStepper()
    installStepObservation(step)
    installValueFormatterObservation(valueFormatter)
    accessibility = WuiControlAccessibility(
      consuming: semanticLabel,
      target: stepper,
      visualLabel: label
    )
    applyAccessibilityValue(binding.value)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
    let labelSize = labelView.sizeThatFits(WuiProposalSize())
    let stepperSize = stepper.intrinsicContentSize
    let formattedValueSize = formattedValueLabel?.intrinsicContentSize ?? .zero
    let hasLabel = labelSize.width > 0 && labelSize.height > 0

    var minimumWidth = stepperSize.width
    if formattedValueLabel != nil {
      minimumWidth += spacing + formattedValueSize.width
    }
    if hasLabel {
      minimumWidth += spacing + labelSize.width
    }

    let intrinsicHeight = max(stepperSize.height, max(labelSize.height, formattedValueSize.height))
    let width =
      hasLabel
      ? proposal.width.map { max(CGFloat($0), minimumWidth) } ?? minimumWidth
      : minimumWidth
    return CGSize(width: width, height: intrinsicHeight)
  }

  #if canImport(AppKit)
    override var isFlipped: Bool { true }
  #endif

  private func configureSubviews() {
    labelView.translatesAutoresizingMaskIntoConstraints = false
    stepper.translatesAutoresizingMaskIntoConstraints = false
    addSubview(labelView)
    addSubview(stepper)

    labelView.setContentCompressionResistancePriority(.required, for: .horizontal)
    labelView.setContentHuggingPriority(.defaultHigh, for: .horizontal)

    var constraints = [
      labelView.leadingAnchor.constraint(equalTo: leadingAnchor),
      labelView.centerYAnchor.constraint(equalTo: centerYAnchor),
      stepper.trailingAnchor.constraint(equalTo: trailingAnchor),
      stepper.centerYAnchor.constraint(equalTo: centerYAnchor),
    ]

    if let formattedValueLabel {
      formattedValueLabel.translatesAutoresizingMaskIntoConstraints = false
      addSubview(formattedValueLabel)
      formattedValueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
      formattedValueLabel.setContentHuggingPriority(.required, for: .horizontal)
      #if canImport(UIKit)
        formattedValueLabel.accessibilityElementsHidden = true
      #elseif canImport(AppKit)
        formattedValueLabel.setAccessibilityElement(false)
      #endif
      constraints += [
        labelView.trailingAnchor.constraint(
          lessThanOrEqualTo: formattedValueLabel.leadingAnchor,
          constant: -spacing
        ),
        formattedValueLabel.trailingAnchor.constraint(
          equalTo: stepper.leadingAnchor,
          constant: -spacing
        ),
        formattedValueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
      ]
    } else {
      constraints.append(
        labelView.trailingAnchor.constraint(
          lessThanOrEqualTo: stepper.leadingAnchor,
          constant: -spacing
        )
      )
    }

    NSLayoutConstraint.activate(constraints)
  }

  private func configureStepper() {
    #if canImport(UIKit)
      stepper.minimumValue = Double(range.start)
      stepper.maximumValue = Double(range.end)
      stepper.value = Double(binding.value)
      stepper.addTarget(self, action: #selector(valueChanged), for: .valueChanged)
    #elseif canImport(AppKit)
      stepper.minValue = Double(range.start)
      stepper.maxValue = Double(range.end)
      stepper.integerValue = Int(binding.value)
      stepper.target = self
      stepper.action = #selector(valueChanged)
    #endif
  }

  private func installStepObservation(_ step: WuiComputed<Int32>) {
    let observation = WuiComputedObservation(step) { [weak self] value, _ in
      self?.applyStep(value)
    }
    stepObservation = observation
    applyStep(observation.value)
  }

  private func applyStep(_ value: Int32) {
    #if canImport(UIKit)
      stepper.stepValue = Double(value)
    #elseif canImport(AppKit)
      stepper.increment = Double(value)
    #endif
  }

  private func installValueFormatterObservation(
    _ formatter: WuiComputed<WuiStyledStr>?
  ) {
    guard let formatter else { return }
    let observation = WuiComputedObservation(formatter) { [weak self] value, metadata in
      guard let self, let formattedValueLabel else { return }
      withCrossDissolveAnimation(formattedValueLabel, metadata) {
        self.applyFormattedValue(value)
      }
    }
    valueFormatterObservation = observation
    applyFormattedValue(observation.value)
  }

  private func applyFormattedValue(_ value: WuiStyledStr) {
    valueRenderer = WuiStyledStrRenderer(styled: value, env: env) { [weak self] in
      self?.applyResolvedFormattedValue()
    }
    applyResolvedFormattedValue()
    applyAccessibilityValue(binding.value)
  }

  private func applyResolvedFormattedValue() {
    guard let formattedValueLabel, let valueRenderer else { return }
    #if canImport(UIKit)
      formattedValueLabel.attributedText = valueRenderer.attributedString()
    #elseif canImport(AppKit)
      formattedValueLabel.attributedStringValue = valueRenderer.attributedString()
    #endif
    invalidateLayoutHierarchy()
  }

  private func startBindingWatcher() {
    bindingWatcher = binding.watch { [weak self] value, _ in
      guard let self, !isSyncingFromBinding else { return }
      isSyncingFromBinding = true
      #if canImport(UIKit)
        stepper.value = Double(value)
      #elseif canImport(AppKit)
        stepper.integerValue = Int(value)
      #endif
      applyAccessibilityValue(value)
      isSyncingFromBinding = false
    }
  }

  private func applyAccessibilityValue(_ value: Int32) {
    let text = valueFormatterObservation?.value.toString() ?? String(value)
    #if canImport(UIKit)
      stepper.accessibilityValue = text
    #elseif canImport(AppKit)
      stepper.setAccessibilityValue(text)
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
