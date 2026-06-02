// WuiTextField.swift
// Text field component - merged UIKit and AppKit implementation

import CWaterUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit)
extension CWaterUI.WuiKeyboardType {
    var uiKeyboardType: UIKeyboardType {
        switch self {
        case WuiKeyboardType_Text: return .default
        case WuiKeyboardType_Email: return .emailAddress
        case WuiKeyboardType_URL: return .URL
        case WuiKeyboardType_Number: return .numberPad
        case WuiKeyboardType_PhoneNumber: return .phonePad
        default: return .default
        }
    }
}
#endif

@MainActor
final class WuiTextField: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_text_field_id() }

    private(set) var stretchAxis: WuiStretchAxis

    #if canImport(UIKit)
    private let textView = UITextView()
    private let placeholderLabel = UILabel()
    private lazy var focusTarget = WuiUIKitFocusTarget(control: textView)
    #elseif canImport(AppKit)
    private let textField = NSTextField()
    private lazy var focusTarget = WuiAppKitTextFieldFocusTarget(control: textField)
    #endif

    private var bindingWatcher: WatcherGuard?
    private var promptWatcher: WatcherGuard?
    private var selectionMenuWatcher: WatcherGuard?
    private var isSyncingFromBinding = false

    private var labelView: WuiAnyView
    private var binding: WuiBinding<WuiStyledStr>
    private var prompt: WuiComputed<WuiStyledStr>
    private var selectionMenu: WuiComputed<CWaterUI.WuiArray_WuiMenuItem>?
    private var selectionMenuItems: [SelectionMenuItem] = []
    #if canImport(UIKit)
    private var keyboard: CWaterUI.WuiKeyboardType
    #endif
    private var env: WuiEnvironment

    private var labelTopConstraint: NSLayoutConstraint?
    private var labelLeadingConstraint: NSLayoutConstraint?
    private var inputTopToLabelConstraint: NSLayoutConstraint?
    private var inputTopToSelfConstraint: NSLayoutConstraint?

    private let verticalSpacing: CGFloat = 4.0

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
        let stretchAxis = WuiStretchAxis(waterui_view_stretch_axis(anyview))
        let ffiTextField: CWaterUI.WuiTextField = waterui_force_as_text_field(anyview)
        let labelView = WuiAnyView(anyview: ffiTextField.label.view, env: env)
        let binding = WuiBinding<WuiStyledStr>(ffiTextField.value)
        let prompt = WuiComputed<WuiStyledStr>(ffiTextField.prompt.content)
        let selectionMenu = ffiTextField.selection_menu.map {
            WuiComputed<CWaterUI.WuiArray_WuiMenuItem>(OpaquePointer(UnsafeMutableRawPointer($0)))
        }
        #if canImport(UIKit)
        self.init(
            stretchAxis: stretchAxis,
            label: labelView,
            binding: binding,
            prompt: prompt,
            selectionMenu: selectionMenu,
            keyboard: ffiTextField.keyboard,
            env: env
        )
        #elseif canImport(AppKit)
        self.init(
            stretchAxis: stretchAxis,
            label: labelView,
            binding: binding,
            prompt: prompt,
            selectionMenu: selectionMenu,
            env: env
        )
        #endif
    }

    #if canImport(UIKit)
    init(
        stretchAxis: WuiStretchAxis,
        label: WuiAnyView,
        binding: WuiBinding<WuiStyledStr>,
        prompt: WuiComputed<WuiStyledStr>,
        selectionMenu: WuiComputed<CWaterUI.WuiArray_WuiMenuItem>?,
        keyboard: CWaterUI.WuiKeyboardType,
        env: WuiEnvironment
    ) {
        self.stretchAxis = stretchAxis
        self.labelView = label
        self.binding = binding
        self.prompt = prompt
        self.selectionMenu = selectionMenu
        self.keyboard = keyboard
        self.env = env
        super.init(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        configureSubviews()
        configureTextInput()
        updateLabel(label, force: true)
        updatePrompt(prompt, force: true)
        updateBinding(binding, force: true)
        startSelectionMenuWatcher()
    }
    #elseif canImport(AppKit)
    init(
        stretchAxis: WuiStretchAxis,
        label: WuiAnyView,
        binding: WuiBinding<WuiStyledStr>,
        prompt: WuiComputed<WuiStyledStr>,
        selectionMenu: WuiComputed<CWaterUI.WuiArray_WuiMenuItem>?,
        env: WuiEnvironment
    ) {
        self.stretchAxis = stretchAxis
        self.labelView = label
        self.binding = binding
        self.prompt = prompt
        self.selectionMenu = selectionMenu
        self.env = env
        super.init(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        configureSubviews()
        configureTextInput()
        updateLabel(label, force: true)
        updatePrompt(prompt, force: true)
        updateBinding(binding, force: true)
        startSelectionMenuWatcher()
    }
    #endif

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        let labelSize = labelView.sizeThatFits(WuiProposalSize())

        #if canImport(UIKit)
        let minTextWidth: CGFloat = 100.0
        let proposedWidth = proposal.width.map(CGFloat.init) ?? minTextWidth
        let targetWidth = max(minTextWidth, max(labelSize.width, proposedWidth))
        let textHeight = max(36.0, textView.sizeThatFits(CGSize(width: targetWidth, height: .greatestFiniteMagnitude)).height)
        #elseif canImport(AppKit)
        let textHeight = textField.intrinsicContentSize.height
        #endif

        let hasLabel = labelSize.height > 0
        let spacing = hasLabel ? verticalSpacing : 0
        let intrinsicHeight = labelSize.height + spacing + textHeight

        let minWidth = max(labelSize.width, 100.0)
        let width = proposal.width.map { max(CGFloat($0), minWidth) } ?? minWidth
        let height = proposal.height.map { CGFloat($0) } ?? intrinsicHeight

        return CGSize(width: width, height: max(height, intrinsicHeight))
    }

    #if canImport(AppKit)
    override var isFlipped: Bool { true }
    #endif

    func updateLabel(_ newLabel: WuiAnyView, force: Bool = false) {
        guard force || newLabel !== labelView else { return }

        labelTopConstraint?.isActive = false
        labelLeadingConstraint?.isActive = false
        inputTopToLabelConstraint?.isActive = false

        labelView.removeFromSuperview()
        labelView = newLabel
        labelView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(labelView)

        labelTopConstraint = labelView.topAnchor.constraint(equalTo: topAnchor)
        labelLeadingConstraint = labelView.leadingAnchor.constraint(equalTo: leadingAnchor)
        #if canImport(UIKit)
        inputTopToLabelConstraint = textView.topAnchor.constraint(equalTo: labelView.bottomAnchor, constant: verticalSpacing)
        #elseif canImport(AppKit)
        inputTopToLabelConstraint = textField.topAnchor.constraint(equalTo: labelView.bottomAnchor, constant: verticalSpacing)
        #endif

        NSLayoutConstraint.activate([
            labelTopConstraint,
            labelLeadingConstraint,
        ].compactMap { $0 })

        updateLabelLayout()
    }

    func updateBinding(_ newBinding: WuiBinding<WuiStyledStr>, force: Bool = false) {
        guard force || newBinding !== binding else { return }
        bindingWatcher = nil
        binding = newBinding
        applyBindingValue(newBinding.value)
        startBindingWatcher()
    }

    func updatePrompt(_ newPrompt: WuiComputed<WuiStyledStr>, force: Bool = false) {
        guard force || newPrompt !== prompt else { return }
        promptWatcher = nil
        prompt = newPrompt
        applyPrompt(newPrompt.value)
        startPromptWatcher()
    }

    #if canImport(UIKit)
    func updateKeyboard(_ newKeyboard: CWaterUI.WuiKeyboardType) {
        keyboard = newKeyboard
        textView.keyboardType = newKeyboard.uiKeyboardType
        textView.reloadInputViews()
    }
    #endif

    private func configureSubviews() {
        labelView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(labelView)

        #if canImport(UIKit)
        textView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textView)
        inputTopToSelfConstraint = textView.topAnchor.constraint(equalTo: topAnchor)
        inputTopToLabelConstraint = textView.topAnchor.constraint(equalTo: labelView.bottomAnchor, constant: verticalSpacing)
        #elseif canImport(AppKit)
        textField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textField)
        inputTopToSelfConstraint = textField.topAnchor.constraint(equalTo: topAnchor)
        inputTopToLabelConstraint = textField.topAnchor.constraint(equalTo: labelView.bottomAnchor, constant: verticalSpacing)
        #endif

        labelTopConstraint = labelView.topAnchor.constraint(equalTo: topAnchor)
        labelLeadingConstraint = labelView.leadingAnchor.constraint(equalTo: leadingAnchor)

        #if canImport(UIKit)
        NSLayoutConstraint.activate([
            labelTopConstraint,
            labelLeadingConstraint,
            textView.leadingAnchor.constraint(equalTo: leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ].compactMap { $0 })
        #elseif canImport(AppKit)
        NSLayoutConstraint.activate([
            labelTopConstraint,
            labelLeadingConstraint,
            textField.leadingAnchor.constraint(equalTo: leadingAnchor),
            textField.trailingAnchor.constraint(equalTo: trailingAnchor),
        ].compactMap { $0 })
        #endif

        updateLabelLayout()
    }

    private func updateLabelLayout() {
        let labelSize = labelView.sizeThatFits(WuiProposalSize())
        let hasLabel = labelSize.height > 0

        labelView.isHidden = !hasLabel
        inputTopToLabelConstraint?.isActive = hasLabel
        inputTopToSelfConstraint?.isActive = !hasLabel
    }

    private func configureTextInput() {
        #if canImport(UIKit)
        textView.keyboardType = keyboard.uiKeyboardType
        textView.delegate = self
        textView.installWuiFocusTarget(focusTarget)
        textView.isScrollEnabled = false
        textView.textContainer.maximumNumberOfLines = 1
        textView.textContainer.lineBreakMode = .byTruncatingTail
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        textView.textContainer.lineFragmentPadding = 0
        textView.layer.cornerRadius = 10
        textView.layer.borderWidth = 1
        // Theme-driven chrome: border = `Border` slot, fill =
        // `SurfaceVariant` slot. `.separator` / `.secondarySystemBackground`
        // remain as legacy fallbacks when no slot is installed.
        if let borderPtr = waterui_theme_color(env.inner, WuiColorSlot_Border) {
            textView.layer.borderColor = WuiComputed<WuiResolvedColor>(borderPtr).value.toUIColor().cgColor
        } else {
            textView.layer.borderColor = UIColor.separator.cgColor
        }
        if let fillPtr = waterui_theme_color(env.inner, WuiColorSlot_SurfaceVariant) {
            textView.backgroundColor = WuiComputed<WuiResolvedColor>(fillPtr).value.toUIColor()
        } else {
            textView.backgroundColor = UIColor.secondarySystemBackground
        }

        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.numberOfLines = 1
        placeholderLabel.backgroundColor = .clear
        textView.addSubview(placeholderLabel)

        NSLayoutConstraint.activate([
            placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: textView.textContainerInset.left),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: textView.trailingAnchor, constant: -textView.textContainerInset.right),
            placeholderLabel.topAnchor.constraint(equalTo: textView.topAnchor, constant: textView.textContainerInset.top),
        ])
        #elseif canImport(AppKit)
        textField.isBordered = true
        textField.bezelStyle = .roundedBezel
        textField.isEditable = true
        textField.isSelectable = true
        textField.delegate = self
        textField.installWuiFocusTarget(focusTarget)
        #endif
    }

    private func applyBindingValue(_ styled: WuiStyledStr) {
        #if canImport(UIKit)
        let attributed = styled.toAttributedString(env: env)
        if textView.attributedText.isEqual(to: attributed) {
            updatePlaceholderVisibility()
            return
        }
        let selected = textView.selectedRange
        textView.attributedText = attributed
        let length = textView.attributedText.length
        textView.selectedRange = NSRange(location: min(selected.location, length), length: 0)
        updatePlaceholderVisibility()
        #elseif canImport(AppKit)
        textField.attributedStringValue = styled.toAttributedString(env: env)
        #endif
    }

    private func applyPrompt(_ styled: WuiStyledStr) {
        let attributed = styled.toAttributedString(env: env)
        let mutableAttributed = NSMutableAttributedString(attributedString: attributed)
        let range = NSRange(location: 0, length: mutableAttributed.length)

        var hasForegroundColor = false
        mutableAttributed.enumerateAttribute(.foregroundColor, in: range, options: []) { value, _, _ in
            if value != nil {
                hasForegroundColor = true
            }
        }

        if !hasForegroundColor {
            #if canImport(UIKit)
            mutableAttributed.addAttribute(.foregroundColor, value: UIColor.placeholderText, range: range)
            #elseif canImport(AppKit)
            mutableAttributed.addAttribute(.foregroundColor, value: NSColor.placeholderTextColor, range: range)
            #endif
        }

        #if canImport(UIKit)
        placeholderLabel.attributedText = mutableAttributed
        updatePlaceholderVisibility()
        #elseif canImport(AppKit)
        textField.placeholderAttributedString = mutableAttributed
        #endif
    }

    private func startBindingWatcher() {
        bindingWatcher = binding.watch { [weak self] newValue, _ in
            guard let self else { return }
            guard !isSyncingFromBinding else { return }
            isSyncingFromBinding = true
            applyBindingValue(newValue)
            isSyncingFromBinding = false
        }
    }

    private func startPromptWatcher() {
        promptWatcher = prompt.watch { [weak self] newValue, _ in
            self?.applyPrompt(newValue)
        }
    }

    private func startSelectionMenuWatcher() {
        guard let selectionMenu else { return }
        selectionMenuItems = buildSelectionMenuItems(from: selectionMenu.value)
        selectionMenuWatcher = selectionMenu.watch { [weak self] rawItems, _ in
            self?.selectionMenuItems = self?.buildSelectionMenuItems(from: rawItems) ?? []
        }
    }

    private func buildSelectionMenuItems(
        from rawItems: CWaterUI.WuiArray_WuiMenuItem
    ) -> [SelectionMenuItem] {
        let items = WuiArray<CWaterUI.WuiMenuItem>(rawItems).toArray()
        var result: [SelectionMenuItem] = []
        result.reserveCapacity(items.count)

        for item in items {
            guard let textPtr = item.label.content else { continue }
            let label = WuiStyledStr(waterui_read_computed_styled_str(textPtr)).toString()
            let actionPtr: OpaquePointer? = item.action.map { OpaquePointer(UnsafeRawPointer($0)) }
            result.append(SelectionMenuItem(label: label, actionPtr: actionPtr))
        }
        return result
    }

    #if canImport(UIKit)
    private func updatePlaceholderVisibility() {
        placeholderLabel.isHidden = !textView.text.isEmpty
    }
    #endif
}

private final class SelectionMenuItem {
    let label: String
    let actionPtr: OpaquePointer?

    init(label: String, actionPtr: OpaquePointer?) {
        self.label = label
        self.actionPtr = actionPtr
    }
}

#if canImport(UIKit)
extension WuiTextField: UITextViewDelegate {
    func textViewDidBeginEditing(_ textView: UITextView) {
        focusTarget.emitPlatformFocusChange(true)
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        focusTarget.emitPlatformFocusChange(false)
    }

    func textViewDidChange(_ textView: UITextView) {
        guard !isSyncingFromBinding else { return }
        if textView.markedTextRange != nil {
            updatePlaceholderVisibility()
            return
        }
        binding.setPlain(textView.text)
        updatePlaceholderVisibility()
    }

    func textView(
        _ textView: UITextView,
        shouldChangeTextIn range: NSRange,
        replacementText text: String
    ) -> Bool {
        if text.contains("\n") {
            // Keep single-line contract, but don't block IME composition updates.
            return textView.markedTextRange != nil
        }
        return true
    }

    @available(iOS 16.0, *)
    func textView(
        _ textView: UITextView,
        editMenuForTextIn range: NSRange,
        suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
        guard !selectionMenuItems.isEmpty else { return nil }

        let custom = selectionMenuItems.map { item in
            UIAction(title: item.label) { [weak self] _ in
                guard let self, let actionPtr = item.actionPtr else { return }
                waterui_call_shared_action(actionPtr, self.env.inner)
            }
        }

        return UIMenu(title: "", children: suggestedActions + custom)
    }
}
#endif

#if canImport(AppKit)
extension WuiTextField: NSTextFieldDelegate {
    private func editingString() -> String {
        guard let editor = textField.currentEditor() else {
            fatalError("WaterUI AppKit text field changed without an active field editor")
        }
        return editor.string
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        focusTarget.emitPlatformFocusChange(true)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard !isSyncingFromBinding else { return }
        binding.setPlain(editingString())
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        focusTarget.emitPlatformFocusChange(false)
    }
}
#endif
