#if canImport(UIKit)
import UIKit
import CWaterUI

@MainActor
final class UIKitTextFieldHost: UIView, WaterUILayoutMeasurable {
    private let stack = UIStackView()
    private let textField = UITextField()
    private var bindingWatcher: WatcherGuard?
    private var promptWatcher: WatcherGuard?
    private var isSyncingFromBinding = false

    private var labelView: PlatformView
    private var binding: WuiBinding<WuiStr>
    private var prompt: WuiComputed<WuiStyledStr>
    private var keyboard: CWaterUI.WuiKeyboardType
    private var env: WuiEnvironment

    var descriptor: PlatformViewDescriptor {
        PlatformViewDescriptor(typeId: WuiTextField.id, isSpacer: false)
    }

    init(
        label: PlatformView,
        binding: WuiBinding<WuiStr>,
        prompt: WuiComputed<WuiStyledStr>,
        keyboard: CWaterUI.WuiKeyboardType,
        env: WuiEnvironment
    ) {
        self.labelView = label
        self.binding = binding
        self.prompt = prompt
        self.keyboard = keyboard
        self.env = env
        super.init(frame: .zero)
        configureStack()
        configureTextField()
        applyPrompt(prompt.value)
        textField.text = binding.value.toString()
        startBindingWatcher()
        startPromptWatcher()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func layoutPriority() -> UInt8 { 0 }

    func measure(in proposal: WuiProposalSize) -> CGSize {
        // TextField is axis-expanding on width per LAYOUT_SPEC.md
        // When width is proposed, use it; otherwise measure intrinsic
        let targetWidth = proposal.width.map { CGFloat($0) } ?? UIView.noIntrinsicMetric
        let targetHeight = proposal.height.map { CGFloat($0) } ?? UIView.noIntrinsicMetric
        let fittingSize = CGSize(
            width: targetWidth == UIView.noIntrinsicMetric ? UIView.layoutFittingExpandedSize.width : targetWidth,
            height: targetHeight == UIView.noIntrinsicMetric ? UIView.layoutFittingCompressedSize.height : targetHeight
        )
        // Use high horizontal priority to expand, low vertical to compress
        let horizontalPriority: UILayoutPriority = targetWidth == UIView.noIntrinsicMetric ? .defaultLow : .required
        let verticalPriority: UILayoutPriority = targetHeight == UIView.noIntrinsicMetric ? .fittingSizeLevel : .required
        return stack.systemLayoutSizeFitting(
            fittingSize,
            withHorizontalFittingPriority: horizontalPriority,
            verticalFittingPriority: verticalPriority
        )
    }

    func updateLabel(_ newLabel: PlatformView) {
        guard newLabel !== labelView else { return }
        replaceLabel(with: newLabel)
        labelView = newLabel
    }

    func updateBinding(_ newBinding: WuiBinding<WuiStr>) {
        guard newBinding !== binding else { return }
        bindingWatcher = nil
        binding = newBinding
        textField.text = binding.value.toString()
        startBindingWatcher()
    }

    func updatePrompt(_ newPrompt: WuiComputed<WuiStyledStr>) {
        guard newPrompt !== prompt else { return }
        promptWatcher = nil
        prompt = newPrompt
        applyPrompt(newPrompt.value)
        startPromptWatcher()
    }

    func updateKeyboard(_ newKeyboard: CWaterUI.WuiKeyboardType) {
        keyboard = newKeyboard
        textField.keyboardType = newKeyboard.uiKeyboardType
        textField.isSecureTextEntry = newKeyboard.isSecureEntry
    }

    private func configureStack() {
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        labelView.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(labelView)
        stack.addArrangedSubview(textField)
    }

    private func configureTextField() {
        textField.borderStyle = .roundedRect
        textField.keyboardType = keyboard.uiKeyboardType
        textField.isSecureTextEntry = keyboard.isSecureEntry
        textField.addTarget(self, action: #selector(valueChanged), for: .editingChanged)
    }

    private func replaceLabel(with newLabel: UIView) {
        stack.removeArrangedSubview(labelView)
        labelView.removeFromSuperview()
        newLabel.translatesAutoresizingMaskIntoConstraints = false
        stack.insertArrangedSubview(newLabel, at: 0)
    }

    private func applyPrompt(_ styled: WuiStyledStr) {
        let attributed = styled.toAttributedString(env: env)
        textField.attributedPlaceholder = NSAttributedString(attributed)
    }

    private func startBindingWatcher() {
        bindingWatcher = binding.watch { [weak self] newValue, _ in
            guard let self else { return }
            let newText = newValue.toString()
            if textField.text == newText { return }
            isSyncingFromBinding = true
            textField.text = newText
            isSyncingFromBinding = false
        }
    }

    private func startPromptWatcher() {
        promptWatcher = prompt.watch { [weak self] newValue, _ in
            self?.applyPrompt(newValue)
        }
    }

    @objc private func valueChanged() {
        guard !isSyncingFromBinding else { return }
        binding.value = WuiStr(string: textField.text ?? "")
    }
}
#endif
