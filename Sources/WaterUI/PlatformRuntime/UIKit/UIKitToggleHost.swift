#if canImport(UIKit)
import UIKit

@MainActor
final class UIKitToggleHost: UIView, WaterUILayoutMeasurable {
    private let stack = UIStackView()
    private let toggle = UISwitch()
    private var bindingWatcher: WatcherGuard?
    private var binding: WuiBinding<Bool>
    private var labelView: PlatformView

    var descriptor: PlatformViewDescriptor {
        PlatformViewDescriptor(typeId: WuiToggle.id, isSpacer: false)
    }

    init(label: PlatformView, binding: WuiBinding<Bool>) {
        self.binding = binding
        self.labelView = label
        super.init(frame: .zero)
        configureStack()
        toggle.isOn = binding.value
        toggle.addTarget(self, action: #selector(valueChanged), for: .valueChanged)
        startWatchingBinding()
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

    func updateLabel(_ label: PlatformView) {
        guard label !== labelView else { return }
        replaceArrangedView(old: labelView, with: label, at: 0)
        labelView = label
    }

    func updateBinding(_ newBinding: WuiBinding<Bool>) {
        guard newBinding !== binding else { return }
        bindingWatcher = nil
        binding = newBinding
        toggle.setOn(newBinding.value, animated: false)
        startWatchingBinding()
    }

    private func configureStack() {
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        labelView.translatesAutoresizingMaskIntoConstraints = false
        toggle.setContentHuggingPriority(.required, for: .horizontal)
        toggle.setContentCompressionResistancePriority(.required, for: .horizontal)

        stack.addArrangedSubview(labelView)
        stack.addArrangedSubview(toggle)
    }

    private func replaceArrangedView(old: UIView, with newView: UIView, at index: Int) {
        stack.removeArrangedSubview(old)
        old.removeFromSuperview()

        newView.translatesAutoresizingMaskIntoConstraints = false
        if index >= stack.arrangedSubviews.count {
            stack.addArrangedSubview(newView)
        } else {
            stack.insertArrangedSubview(newView, at: index)
        }
    }

    private func startWatchingBinding() {
        bindingWatcher = binding.watch { [weak self] newValue, metadata in
            guard let self else { return }
            if toggle.isOn == newValue { return }
            toggle.setOn(newValue, animated: metadata.getAnimation() != nil)
        }
    }

    @objc private func valueChanged() {
        binding.value = toggle.isOn
    }
}
#endif
