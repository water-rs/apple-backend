// WuiTextField.swift
// Text field component - merged UIKit and AppKit implementation
//
// # Layout Behavior
// TextField expands horizontally to fill available width, but has fixed intrinsic height.
// Includes optional label at top and placeholder text support.
// Use frame modifiers to constrain width if needed.
//
// // INTERNAL: Layout Contract for Backend Implementers
// // - stretchAxis: .horizontal (expands width, intrinsic height)
// // - sizeThatFits: Returns proposed width (min 100pt), intrinsic height
// // - Priority: 0 (default)

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
    private let textField = UITextField()
    #elseif canImport(AppKit)
    private let textField = NSTextField()
    #endif
    private var bindingWatcher: WatcherGuard?
    private var promptWatcher: WatcherGuard?
    private var isSyncingFromBinding = false

    private var labelView: WuiAnyView
    private var binding: WuiBinding<WuiStr>
    private var prompt: WuiComputed<WuiStyledStr>
    #if canImport(UIKit)
    private var keyboard: CWaterUI.WuiKeyboardType
    #endif
    private var env: WuiEnvironment

    // Layout constants
    private let verticalSpacing: CGFloat = 4.0

    // MARK: - WuiComponent Init

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
        let stretchAxis = WuiStretchAxis(waterui_view_stretch_axis(anyview))
        let ffiTextField: CWaterUI.WuiTextField = waterui_force_as_text_field(anyview)
        let labelView = WuiAnyView(anyview: ffiTextField.label, env: env)
        let binding = WuiBinding<WuiStr>(ffiTextField.value)
        let prompt = WuiComputed<WuiStyledStr>(ffiTextField.prompt.content)
        #if canImport(UIKit)
        self.init(
            stretchAxis: stretchAxis,
            label: labelView,
            binding: binding,
            prompt: prompt,
            keyboard: ffiTextField.keyboard,
            env: env
        )
        #elseif canImport(AppKit)
        self.init(
            stretchAxis: stretchAxis,
            label: labelView,
            binding: binding,
            prompt: prompt,
            env: env
        )
        #endif
    }

    // MARK: - Designated Init

    #if canImport(UIKit)
    init(
        stretchAxis: WuiStretchAxis,
        label: WuiAnyView,
        binding: WuiBinding<WuiStr>,
        prompt: WuiComputed<WuiStyledStr>,
        keyboard: CWaterUI.WuiKeyboardType,
        env: WuiEnvironment
    ) {
        self.stretchAxis = stretchAxis
        self.labelView = label
        self.binding = binding
        self.prompt = prompt
        self.keyboard = keyboard
        self.env = env
        // Initialize with a default frame to prevent constraint conflicts.
        super.init(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        configureSubviews()
        configureTextField()
        applyPrompt(prompt.value)
        textField.text = binding.value.toString()
        startBindingWatcher()
        startPromptWatcher()
    }
    #elseif canImport(AppKit)
    init(
        stretchAxis: WuiStretchAxis,
        label: WuiAnyView,
        binding: WuiBinding<WuiStr>,
        prompt: WuiComputed<WuiStyledStr>,
        env: WuiEnvironment
    ) {
        self.stretchAxis = stretchAxis
        self.labelView = label
        self.binding = binding
        self.prompt = prompt
        self.env = env
        // Initialize with a default frame to prevent constraint conflicts.
        super.init(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        configureSubviews()
        configureTextField()
        applyPrompt(prompt.value)
        textField.stringValue = binding.value.toString()
        startBindingWatcher()
        startPromptWatcher()
    }
    #endif

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - WuiComponent

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        // TextField is axis-expanding on width per LAYOUT_SPEC.md
        // It uses isStretch: true to expand, so here we report MINIMUM usable size
        let labelSize = labelView.sizeThatFits(WuiProposalSize())
        let textFieldHeight = textField.intrinsicContentSize.height

        // Intrinsic height: label height + spacing + text field height
        let intrinsicHeight = labelSize.height + verticalSpacing + textFieldHeight

        // For width: report MINIMUM usable size
        // The minimum width ensures label fits and text field has reasonable input space
        let minTextFieldWidth: CGFloat = 100.0
        let minWidth = max(labelSize.width, minTextFieldWidth)

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

    // MARK: - Update Methods

    func updateLabel(_ newLabel: WuiAnyView) {
        guard newLabel !== labelView else { return }
        labelView.removeFromSuperview()

        labelView = newLabel
        labelView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(labelView)

        // Re-establish constraints for new label
        NSLayoutConstraint.activate([
            labelView.topAnchor.constraint(equalTo: topAnchor),
            labelView.leadingAnchor.constraint(equalTo: leadingAnchor),
        ])
    }

    func updateBinding(_ newBinding: WuiBinding<WuiStr>) {
        guard newBinding !== binding else { return }
        bindingWatcher = nil
        binding = newBinding
        #if canImport(UIKit)
        textField.text = binding.value.toString()
        #elseif canImport(AppKit)
        textField.stringValue = binding.value.toString()
        #endif
        startBindingWatcher()
    }

    func updatePrompt(_ newPrompt: WuiComputed<WuiStyledStr>) {
        guard newPrompt !== prompt else { return }
        promptWatcher = nil
        prompt = newPrompt
        applyPrompt(newPrompt.value)
        startPromptWatcher()
    }

    #if canImport(UIKit)
    func updateKeyboard(_ newKeyboard: CWaterUI.WuiKeyboardType) {
        keyboard = newKeyboard
        textField.keyboardType = newKeyboard.uiKeyboardType
    }
    #endif

    // MARK: - Configuration

    private func configureSubviews() {
        // Use AutoLayout for internal component layout
        labelView.translatesAutoresizingMaskIntoConstraints = false
        textField.translatesAutoresizingMaskIntoConstraints = false

        addSubview(labelView)
        addSubview(textField)

        // Layout: label at top-leading, text field below spanning full width
        NSLayoutConstraint.activate([
            // Label: top-leading
            labelView.topAnchor.constraint(equalTo: topAnchor),
            labelView.leadingAnchor.constraint(equalTo: leadingAnchor),

            // Text field: below label, full width
            textField.topAnchor.constraint(equalTo: labelView.bottomAnchor, constant: verticalSpacing),
            textField.leadingAnchor.constraint(equalTo: leadingAnchor),
            textField.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    private func configureTextField() {
        #if canImport(UIKit)
        textField.borderStyle = .roundedRect
        textField.keyboardType = keyboard.uiKeyboardType
        textField.addTarget(self, action: #selector(valueChanged), for: .editingChanged)
        #elseif canImport(AppKit)
        textField.isBordered = true
        textField.bezelStyle = .roundedBezel
        textField.isEditable = true
        textField.isSelectable = true
        textField.delegate = self
        #endif
    }

    private func applyPrompt(_ styled: WuiStyledStr) {
        let attributed = styled.toAttributedString(env: env)
        // Apply secondary/placeholder color if no foreground color was specified
        let mutableAttributed = NSMutableAttributedString(attributedString: attributed)
        let range = NSRange(location: 0, length: mutableAttributed.length)

        // Check if foreground color is already set
        var hasForegroundColor = false
        mutableAttributed.enumerateAttribute(.foregroundColor, in: range, options: []) { value, _, _ in
            if value != nil {
                hasForegroundColor = true
            }
        }

        // If no foreground color specified, use the standard placeholder color
        if !hasForegroundColor {
            #if canImport(UIKit)
            mutableAttributed.addAttribute(.foregroundColor, value: UIColor.placeholderText, range: range)
            #elseif canImport(AppKit)
            mutableAttributed.addAttribute(.foregroundColor, value: NSColor.placeholderTextColor, range: range)
            #endif
        }

        #if canImport(UIKit)
        textField.attributedPlaceholder = mutableAttributed
        #elseif canImport(AppKit)
        textField.placeholderAttributedString = mutableAttributed
        #endif
    }

    private func startBindingWatcher() {
        bindingWatcher = binding.watch { [weak self] newValue, _ in
            guard let self else { return }
            let newText = newValue.toString()
            #if canImport(UIKit)
            if textField.text == newText { return }
            #elseif canImport(AppKit)
            if textField.stringValue == newText { return }
            #endif
            isSyncingFromBinding = true
            #if canImport(UIKit)
            textField.text = newText
            #elseif canImport(AppKit)
            textField.stringValue = newText
            #endif
            isSyncingFromBinding = false
        }
    }

    private func startPromptWatcher() {
        promptWatcher = prompt.watch { [weak self] newValue, _ in
            self?.applyPrompt(newValue)
        }
    }

    #if canImport(UIKit)
    @objc private func valueChanged() {
        guard !isSyncingFromBinding else { return }
        binding.value = WuiStr(string: textField.text ?? "")
    }
    #endif
}

#if canImport(AppKit)
extension WuiTextField: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard !isSyncingFromBinding else { return }
        binding.value = WuiStr(string: textField.stringValue)
    }
}
#endif
