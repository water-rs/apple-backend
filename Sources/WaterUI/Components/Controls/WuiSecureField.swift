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
    private lazy var focusTarget = WuiUIKitFocusTarget(control: textField)
  #elseif canImport(AppKit)
    private let textField = NSSecureTextField()
    private lazy var focusTarget = WuiAppKitTextFieldFocusTarget(control: textField)
  #endif
  private var isSyncingFromBinding = false

  private var labelView: WuiAnyView
  private var binding: WuiBinding<WuiStr>
  private var bindingWatcher: WatcherGuard?
  private var bodyFontObservation: WuiComputedObservation<WuiResolvedFontValue>?
  private var accessibility: WuiControlAccessibility?
  private let env: WuiEnvironment

  // Layout constants
  private let verticalSpacing: CGFloat = 4.0
  private var labelConstraints: [NSLayoutConstraint] = []

  // MARK: - WuiComponent Init

  convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
    let stretchAxis = WuiStretchAxis(waterui_view_stretch_axis(anyview))
    let ffiSecureField: CWaterUI.WuiSecureField = waterui_force_as_secure_field(anyview)
    let labelView = WuiAnyView(anyview: ffiSecureField.label.view, env: env)
    let binding = WuiBinding<WuiStr>(secure: ffiSecureField.value)
    self.init(
      stretchAxis: stretchAxis,
      label: labelView,
      binding: binding,
      semanticLabel: ffiSecureField.label,
      env: env
    )
  }

  // MARK: - Designated Init

  init(
    stretchAxis: WuiStretchAxis,
    label: WuiAnyView,
    binding: WuiBinding<WuiStr>,
    semanticLabel: CWaterUI.WuiLabel,
    env: WuiEnvironment
  ) {
    self.stretchAxis = stretchAxis
    self.labelView = label
    self.binding = binding
    self.env = env
    super.init(frame: .zero)
    configureSubviews()
    configureTextField()
    updateLabel(label, force: true)
    updateBinding(binding, force: true)
    accessibility = WuiControlAccessibility(
      consuming: semanticLabel,
      target: textField,
      visualLabel: label
    )
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

  #if canImport(AppKit)
    nonisolated override var isFlipped: Bool { true }
  #endif

  // MARK: - Update Methods

  func updateLabel(_ newLabel: WuiAnyView, force: Bool = false) {
    guard force || newLabel !== labelView else { return }
    labelView.removeFromSuperview()
    labelView = newLabel
    addSubview(labelView)
    setupLabelConstraints()
  }

  func updateBinding(_ newBinding: WuiBinding<WuiStr>, force: Bool = false) {
    guard force || newBinding !== binding else { return }
    bindingWatcher = nil
    binding = newBinding
    bindingWatcher = binding.watch { [weak self] value, _ in
      guard let self, !isSyncingFromBinding else { return }
      applyBindingValue(value)
    }
    applyBindingValue(binding.value)
  }

  private func applyBindingValue(_ value: WuiStr) {
    let text = value.toString()
    isSyncingFromBinding = true
    #if canImport(UIKit)
      textField.text = text
    #elseif canImport(AppKit)
      textField.stringValue = text
    #endif
    isSyncingFromBinding = false
  }

  // MARK: - Configuration

  private func setupLabelConstraints() {
    NSLayoutConstraint.deactivate(labelConstraints)
    labelView.translatesAutoresizingMaskIntoConstraints = false
    textField.translatesAutoresizingMaskIntoConstraints = false
    labelConstraints = [
      labelView.topAnchor.constraint(equalTo: topAnchor),
      labelView.leadingAnchor.constraint(equalTo: leadingAnchor),
      textField.topAnchor.constraint(equalTo: labelView.bottomAnchor, constant: verticalSpacing),
      textField.leadingAnchor.constraint(equalTo: leadingAnchor),
      textField.trailingAnchor.constraint(equalTo: trailingAnchor),
    ]
    NSLayoutConstraint.activate(labelConstraints)
  }

  private func configureSubviews() {
    // Use AutoLayout for internal component layout
    labelView.translatesAutoresizingMaskIntoConstraints = false
    textField.translatesAutoresizingMaskIntoConstraints = false

    addSubview(labelView)
    addSubview(textField)
    setupLabelConstraints()
  }

  private func configureTextField() {
    #if canImport(UIKit)
      textField.borderStyle = .roundedRect
      textField.isSecureTextEntry = true
      textField.textContentType = .password
      textField.autocorrectionType = .no
      textField.autocapitalizationType = .none
      textField.installWuiFocusTarget(focusTarget)
      textField.addTarget(self, action: #selector(editingDidBegin), for: .editingDidBegin)
      textField.addTarget(self, action: #selector(valueChanged), for: .editingChanged)
      textField.addTarget(self, action: #selector(editingDidEnd), for: .editingDidEnd)
    #elseif canImport(AppKit)
      textField.isBordered = true
      textField.bezelStyle = .roundedBezel
      textField.isEditable = true
      textField.isSelectable = true
      textField.delegate = self
      textField.installWuiFocusTarget(focusTarget)
    #endif
    bodyFontObservation = .bodyFont(env: env) { [weak self] font in
      guard let self else { return }
      textField.font = font.toPlatformFont()
      invalidateLayoutHierarchy()
    }
  }

  #if canImport(UIKit)
    @objc private func editingDidBegin() {
      focusTarget.emitPlatformFocusChange(true)
    }

    @objc private func valueChanged() {
      guard !isSyncingFromBinding else { return }
      let text = textField.text ?? ""
      isSyncingFromBinding = true
      binding.set(WuiStr(string: text))
      isSyncingFromBinding = false
    }

    @objc private func editingDidEnd() {
      focusTarget.emitPlatformFocusChange(false)
    }
  #endif
}

#if canImport(AppKit)
  extension WuiSecureField: NSTextFieldDelegate {
    func controlTextDidBeginEditing(_ obj: Notification) {
      focusTarget.emitPlatformFocusChange(true)
    }

    func controlTextDidChange(_ obj: Notification) {
      guard !isSyncingFromBinding else { return }
      let text = textField.stringValue
      isSyncingFromBinding = true
      binding.set(WuiStr(string: text))
      isSyncingFromBinding = false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
      focusTarget.emitPlatformFocusChange(false)
    }
  }
#endif
