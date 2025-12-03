// WuiSecureField.swift
// Secure field component - merged UIKit and AppKit implementation
//
// # Layout Behavior
// SecureField expands horizontally to fill available width, but has fixed intrinsic height.
// Includes optional label at top. Input is automatically masked for security.
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

@MainActor
final class WuiSecureField: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_secure_field_id() }

    private(set) var stretchAxis: WuiStretchAxis

    #if canImport(UIKit)
    private let textField = UITextField()
    #elseif canImport(AppKit)
    private let textField = NSSecureTextField()
    #endif
    private var bindingWatcher: WatcherGuard?
    private var isSyncingFromBinding = false

    private var labelView: WuiAnyView
    private var binding: WuiBinding<WuiStr>
    private var env: WuiEnvironment

    // Layout constants
    private let verticalSpacing: CGFloat = 4.0

    // MARK: - WuiComponent Init

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
        let stretchAxis = WuiStretchAxis(waterui_view_stretch_axis(anyview))
        let ffiSecureField: CWaterUI.WuiSecureField = waterui_force_as_secure_field(anyview)
        let labelView = WuiAnyView(anyview: ffiSecureField.label, env: env)
        let binding = WuiBinding<WuiStr>(ffiSecureField.value)
        self.init(
            stretchAxis: stretchAxis,
            label: labelView,
            binding: binding,
            env: env
        )
    }

    // MARK: - Designated Init

    init(
        stretchAxis: WuiStretchAxis,
        label: WuiAnyView,
        binding: WuiBinding<WuiStr>,
        env: WuiEnvironment
    ) {
        self.stretchAxis = stretchAxis
        self.labelView = label
        self.binding = binding
        self.env = env
        super.init(frame: .zero)
        configureSubviews()
        configureTextField()
        // Note: We don't set initial text value from binding for security
        // SecureField should always start empty on the UI side
        startBindingWatcher()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - WuiComponent

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        // SecureField is axis-expanding on width per LAYOUT_SPEC.md
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
        let boundsWidth = bounds.width

        // Calculate sizes
        let labelSize = labelView.sizeThatFits(WuiProposalSize())
        let textFieldHeight = textField.intrinsicContentSize.height

        // Layout label at top
        labelView.frame = CGRect(
            x: 0,
            y: 0,
            width: labelSize.width,
            height: labelSize.height
        )

        // Layout text field below label
        let textFieldY = labelSize.height + verticalSpacing
        textField.frame = CGRect(
            x: 0,
            y: textFieldY,
            width: boundsWidth,
            height: textFieldHeight
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

    func updateBinding(_ newBinding: WuiBinding<WuiStr>) {
        guard newBinding !== binding else { return }
        bindingWatcher = nil
        binding = newBinding
        // For security, we don't update the text field from binding
        // User must re-enter the secure value
        startBindingWatcher()
    }

    // MARK: - Configuration

    private func configureSubviews() {
        // Manual frame layout - just add subviews, performLayout() will position them
        addSubview(labelView)
        addSubview(textField)
    }

    private func configureTextField() {
        #if canImport(UIKit)
        textField.borderStyle = .roundedRect
        textField.isSecureTextEntry = true
        textField.textContentType = .password
        textField.autocorrectionType = .no
        textField.autocapitalizationType = .none
        textField.addTarget(self, action: #selector(valueChanged), for: .editingChanged)
        #elseif canImport(AppKit)
        textField.isBordered = true
        textField.bezelStyle = .roundedBezel
        textField.isEditable = true
        textField.isSelectable = true
        textField.delegate = self
        #endif
    }

    private func setNeedsLayoutCompat() {
        #if canImport(UIKit)
        setNeedsLayout()
        #elseif canImport(AppKit)
        needsLayout = true
        #endif
    }

    private func startBindingWatcher() {
        // We intentionally don't watch the binding to update the text field
        // For security reasons, secure fields should not display their values
        // The binding only flows from the text field TO the binding, not vice versa
    }

    #if canImport(UIKit)
    @objc private func valueChanged() {
        guard !isSyncingFromBinding else { return }
        let text = textField.text ?? ""
        binding.value = WuiStr(string: text)
    }
    #endif
}

#if canImport(AppKit)
extension WuiSecureField: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard !isSyncingFromBinding else { return }
        let text = textField.stringValue
        binding.value = WuiStr(string: text)
    }
}
#endif
