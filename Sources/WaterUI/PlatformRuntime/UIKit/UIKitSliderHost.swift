#if canImport(UIKit)
import UIKit

@MainActor
final class UIKitSliderHost: UIView, WaterUILayoutMeasurable {
    private let stack = UIStackView()
    private let sliderRow = UIStackView()
    private let slider = UISlider()
    private var bindingWatcher: WatcherGuard?

    private var labelView: PlatformView
    private var minLabelView: PlatformView
    private var maxLabelView: PlatformView
    private var binding: WuiBinding<Double>
    private var range: WuiRange_f64

    var descriptor: PlatformViewDescriptor {
        PlatformViewDescriptor(typeId: WuiSlider.id, isSpacer: false)
    }

    init(
        label: PlatformView,
        minLabel: PlatformView,
        maxLabel: PlatformView,
        range: WuiRange_f64,
        binding: WuiBinding<Double>
    ) {
        self.labelView = label
        self.minLabelView = minLabel
        self.maxLabelView = maxLabel
        self.range = range
        self.binding = binding
        super.init(frame: .zero)
        configureStacks()
        configureSlider()
        startBindingWatcher()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func layoutPriority() -> UInt8 { 0 }

    func measure(in proposal: WuiProposalSize) -> CGSize {
        let targetWidth = proposal.width.map { CGFloat($0) } ?? UIView.noIntrinsicMetric
        let targetHeight = proposal.height.map { CGFloat($0) } ?? UIView.noIntrinsicMetric
        let fittingSize = CGSize(
            width: targetWidth == UIView.noIntrinsicMetric ? UIView.layoutFittingCompressedSize.width : targetWidth,
            height: targetHeight == UIView.noIntrinsicMetric ? UIView.layoutFittingCompressedSize.height : targetHeight
        )
        let horizontalPriority: UILayoutPriority =
            targetWidth == UIView.noIntrinsicMetric ? .fittingSizeLevel : .required
        let verticalPriority: UILayoutPriority =
            targetHeight == UIView.noIntrinsicMetric ? .fittingSizeLevel : .required
        return stack.systemLayoutSizeFitting(
            fittingSize,
            withHorizontalFittingPriority: horizontalPriority,
            verticalFittingPriority: verticalPriority
        )
    }

    func updateLabel(_ newLabel: PlatformView) {
        guard newLabel !== labelView else { return }
        replaceArrangedSubview(old: labelView, with: newLabel, in: stack, index: 0)
        labelView = newLabel
    }

    func updateMinLabel(_ newLabel: PlatformView) {
        guard newLabel !== minLabelView else { return }
        replaceArrangedSubview(old: minLabelView, with: newLabel, in: sliderRow, index: 0)
        minLabelView = newLabel
    }

    func updateMaxLabel(_ newLabel: PlatformView) {
        guard newLabel !== maxLabelView else { return }
        let index = sliderRow.arrangedSubviews.firstIndex(of: maxLabelView) ?? sliderRow.arrangedSubviews.count
        replaceArrangedSubview(old: maxLabelView, with: newLabel, in: sliderRow, index: index)
        maxLabelView = newLabel
    }

    func updateBinding(_ newBinding: WuiBinding<Double>) {
        guard newBinding !== binding else { return }
        bindingWatcher = nil
        binding = newBinding
        slider.setValue(Float(clampedValue(newBinding.value)), animated: false)
        startBindingWatcher()
    }

    func updateRange(_ range: WuiRange_f64) {
        self.range = range
        slider.minimumValue = Float(range.start)
        slider.maximumValue = Float(range.end)
        slider.setValue(Float(clampedValue(binding.value)), animated: false)
    }

    private func configureStacks() {
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        sliderRow.axis = .horizontal
        sliderRow.spacing = 8
        sliderRow.alignment = .center
        sliderRow.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        labelView.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(labelView)
        stack.addArrangedSubview(sliderRow)

        minLabelView.translatesAutoresizingMaskIntoConstraints = false
        sliderRow.addArrangedSubview(minLabelView)
        slider.translatesAutoresizingMaskIntoConstraints = false
        sliderRow.addArrangedSubview(slider)
        maxLabelView.translatesAutoresizingMaskIntoConstraints = false
        sliderRow.addArrangedSubview(maxLabelView)
    }

    private func configureSlider() {
        slider.minimumValue = Float(range.start)
        slider.maximumValue = Float(range.end)
        slider.value = Float(clampedValue(binding.value))
        slider.addTarget(self, action: #selector(valueChanged), for: .valueChanged)
    }

    private func startBindingWatcher() {
        bindingWatcher = binding.watch { [weak self] newValue, metadata in
            guard let self else { return }
            let clamped = Float(clampedValue(newValue))
            if slider.value == clamped { return }
            slider.setValue(clamped, animated: metadata.getAnimation() != nil)
        }
    }

    private func replaceArrangedSubview(
        old: UIView,
        with newView: UIView,
        in stack: UIStackView,
        index: Int
    ) {
        stack.removeArrangedSubview(old)
        old.removeFromSuperview()
        newView.translatesAutoresizingMaskIntoConstraints = false
        if index >= stack.arrangedSubviews.count {
            stack.addArrangedSubview(newView)
        } else {
            stack.insertArrangedSubview(newView, at: index)
        }
    }

    private func clampedValue(_ value: Double) -> Double {
        min(max(value, range.start), range.end)
    }

    @objc private func valueChanged() {
        binding.value = Double(slider.value)
    }
}
#endif
