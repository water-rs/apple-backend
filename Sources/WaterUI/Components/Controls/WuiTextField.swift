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
      default: fatalError("Unsupported WaterUI keyboard type: \(rawValue)")
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
  private var isSyncingFromBinding = false
  private var bindingRenderer: WuiStyledStrRenderer?
  private var promptRenderer: WuiStyledStrRenderer?
  private var borderColorObservation: WuiComputedObservation<WuiResolvedColor>?
  private var fillColorObservation: WuiComputedObservation<WuiResolvedColor>?
  private var promptAlignmentObservation: WuiComputedObservation<WuiHorizontalAlignment>?
  private var accessibility: WuiControlAccessibility?

  private let labelView: WuiAnyView
  private let binding: WuiBinding<WuiStyledStr>
  private let prompt: WuiComputed<WuiStyledStr>
  private var selectionMenuTree: WuiMenuTree?
  #if canImport(UIKit)
    private let keyboard: CWaterUI.WuiKeyboardType
  #endif
  private let env: WuiEnvironment

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
    let promptAlignment = WuiComputed<WuiHorizontalAlignment>(
      ffiTextField.prompt.paragraph_alignment
    )
    let selectionMenu = ffiTextField.selection_menu
    #if canImport(UIKit)
      self.init(
        stretchAxis: stretchAxis,
        label: labelView,
        binding: binding,
        prompt: prompt,
        promptAlignment: promptAlignment,
        semanticLabel: ffiTextField.label,
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
        promptAlignment: promptAlignment,
        semanticLabel: ffiTextField.label,
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
      promptAlignment: WuiComputed<WuiHorizontalAlignment>,
      semanticLabel: CWaterUI.WuiLabel,
      selectionMenu: OpaquePointer?,
      keyboard: CWaterUI.WuiKeyboardType,
      env: WuiEnvironment
    ) {
      self.stretchAxis = stretchAxis
      self.labelView = label
      self.binding = binding
      self.prompt = prompt
      self.keyboard = keyboard
      self.env = env
      super.init(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
      configureSubviews()
      configureTextInput()
      startPromptWatcher()
      applyPrompt(prompt.value)
      installPromptAlignment(promptAlignment)
      startBindingWatcher()
      applyBindingValue(binding.value)
      accessibility = WuiControlAccessibility(
        consuming: semanticLabel,
        target: textView,
        visualLabel: label
      )
      installSelectionMenu(selectionMenu)
    }
  #elseif canImport(AppKit)
    init(
      stretchAxis: WuiStretchAxis,
      label: WuiAnyView,
      binding: WuiBinding<WuiStyledStr>,
      prompt: WuiComputed<WuiStyledStr>,
      promptAlignment: WuiComputed<WuiHorizontalAlignment>,
      semanticLabel: CWaterUI.WuiLabel,
      selectionMenu: OpaquePointer?,
      env: WuiEnvironment
    ) {
      self.stretchAxis = stretchAxis
      self.labelView = label
      self.binding = binding
      self.prompt = prompt
      self.env = env
      super.init(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
      configureSubviews()
      configureTextInput()
      startPromptWatcher()
      applyPrompt(prompt.value)
      installPromptAlignment(promptAlignment)
      startBindingWatcher()
      applyBindingValue(binding.value)
      accessibility = WuiControlAccessibility(
        consuming: semanticLabel,
        target: textField,
        visualLabel: label
      )
      installSelectionMenu(selectionMenu)
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
      let textHeight = max(
        36.0,
        textView.sizeThatFits(CGSize(width: targetWidth, height: .greatestFiniteMagnitude)).height)
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

  private func configureSubviews() {
    labelView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(labelView)

    #if canImport(UIKit)
      textView.translatesAutoresizingMaskIntoConstraints = false
      addSubview(textView)
      inputTopToSelfConstraint = textView.topAnchor.constraint(equalTo: topAnchor)
      inputTopToLabelConstraint = textView.topAnchor.constraint(
        equalTo: labelView.bottomAnchor, constant: verticalSpacing)
    #elseif canImport(AppKit)
      textField.translatesAutoresizingMaskIntoConstraints = false
      addSubview(textField)
      inputTopToSelfConstraint = textField.topAnchor.constraint(equalTo: topAnchor)
      inputTopToLabelConstraint = textField.topAnchor.constraint(
        equalTo: labelView.bottomAnchor, constant: verticalSpacing)
    #endif

    labelTopConstraint = labelView.topAnchor.constraint(equalTo: topAnchor)
    labelLeadingConstraint = labelView.leadingAnchor.constraint(equalTo: leadingAnchor)

    #if canImport(UIKit)
      NSLayoutConstraint.activate(
        [
          labelTopConstraint,
          labelLeadingConstraint,
          textView.leadingAnchor.constraint(equalTo: leadingAnchor),
          textView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ].compactMap { $0 })
    #elseif canImport(AppKit)
      NSLayoutConstraint.activate(
        [
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
      borderColorObservation = WuiComputedObservation(
        themeColor: WuiColorSlot_Border,
        env: env
      ) { [weak self] color, _ in
        self?.textView.layer.borderColor = color.toUIColor().cgColor
      }
      textView.layer.borderColor = borderColorObservation?.value.toUIColor().cgColor
      fillColorObservation = WuiComputedObservation(
        themeColor: WuiColorSlot_SurfaceVariant,
        env: env
      ) { [weak self] color, _ in
        self?.textView.backgroundColor = color.toUIColor()
      }
      textView.backgroundColor = fillColorObservation?.value.toUIColor()

      placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
      placeholderLabel.numberOfLines = 1
      placeholderLabel.backgroundColor = .clear
      textView.addSubview(placeholderLabel)

      NSLayoutConstraint.activate([
        placeholderLabel.leadingAnchor.constraint(
          equalTo: textView.leadingAnchor, constant: textView.textContainerInset.left),
        placeholderLabel.trailingAnchor.constraint(
          lessThanOrEqualTo: textView.trailingAnchor, constant: -textView.textContainerInset.right),
        placeholderLabel.topAnchor.constraint(
          equalTo: textView.topAnchor, constant: textView.textContainerInset.top),
      ])
    #elseif canImport(AppKit)
      textField.isBordered = false
      textField.wantsLayer = true
      textField.layer?.cornerRadius = 6
      textField.layer?.borderWidth = 1
      textField.isEditable = true
      textField.isSelectable = true
      textField.delegate = self
      textField.installWuiFocusTarget(focusTarget)
      borderColorObservation = WuiComputedObservation(
        themeColor: WuiColorSlot_Border,
        env: env
      ) { [weak self] color, _ in
        self?.textField.layer?.borderColor = color.toNSColor().cgColor
      }
      textField.layer?.borderColor = borderColorObservation?.value.toNSColor().cgColor
      fillColorObservation = WuiComputedObservation(
        themeColor: WuiColorSlot_SurfaceVariant,
        env: env
      ) { [weak self] color, _ in
        self?.textField.backgroundColor = color.toNSColor()
      }
      textField.backgroundColor = fillColorObservation?.value.toNSColor()
    #endif
  }

  private func applyBindingValue(_ styled: WuiStyledStr) {
    bindingRenderer = WuiStyledStrRenderer(styled: styled, env: env) { [weak self] in
      self?.applyResolvedBindingValue()
    }
    applyResolvedBindingValue()
  }

  private func applyResolvedBindingValue() {
    guard let bindingRenderer else { return }
    let attributed = bindingRenderer.attributedString()
    #if canImport(UIKit)
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
      textField.attributedStringValue = attributed
    #endif
    invalidateLayoutHierarchy()
  }

  private func applyPrompt(_ styled: WuiStyledStr) {
    promptRenderer = WuiStyledStrRenderer(
      styled: styled,
      env: env,
      defaultForegroundSlot: WuiColorSlot_MutedForeground
    ) { [weak self] in
      self?.applyResolvedPrompt()
    }
    applyResolvedPrompt()
  }

  private func applyResolvedPrompt() {
    guard let promptRenderer else { return }
    let attributed = promptRenderer.attributedString()
    #if canImport(UIKit)
      placeholderLabel.attributedText = attributed
      updatePlaceholderVisibility()
    #elseif canImport(AppKit)
      textField.placeholderAttributedString = attributed
    #endif
    invalidateCapturedRendering()
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

  private func installPromptAlignment(_ alignment: WuiComputed<WuiHorizontalAlignment>) {
    let observation = WuiComputedObservation(alignment) { [weak self] alignment, _ in
      self?.applyPromptAlignment(alignment)
    }
    promptAlignmentObservation = observation
    applyPromptAlignment(observation.value)
  }

  private func applyPromptAlignment(_ alignment: WuiHorizontalAlignment) {
    #if canImport(UIKit)
      let direction = UIView.userInterfaceLayoutDirection(for: semanticContentAttribute)
      switch alignment {
      case WuiHorizontalAlignment_Leading:
        textView.textAlignment = .natural
        placeholderLabel.textAlignment = .natural
      case WuiHorizontalAlignment_Trailing:
        let nativeAlignment: NSTextAlignment = direction == .rightToLeft ? .left : .right
        textView.textAlignment = nativeAlignment
        placeholderLabel.textAlignment = nativeAlignment
      case WuiHorizontalAlignment_Center:
        textView.textAlignment = .center
        placeholderLabel.textAlignment = .center
      default:
        fatalError("Unsupported WaterUI prompt alignment: \(alignment.rawValue)")
      }
    #elseif canImport(AppKit)
      let direction = userInterfaceLayoutDirection
      switch alignment {
      case WuiHorizontalAlignment_Leading:
        textField.alignment = .natural
      case WuiHorizontalAlignment_Trailing:
        textField.alignment = direction == .rightToLeft ? .left : .right
      case WuiHorizontalAlignment_Center:
        textField.alignment = .center
      default:
        fatalError("Unsupported WaterUI prompt alignment: \(alignment.rawValue)")
      }
    #endif
    invalidateCapturedRendering()
  }

  private func installSelectionMenu(_ source: OpaquePointer?) {
    selectionMenuTree = source.map { source in
      WuiMenuTree(consuming: source) { [weak self] _ in
        self?.invalidateCapturedRendering()
      }
    }
  }

  #if canImport(UIKit)
    private func updatePlaceholderVisibility() {
      placeholderLabel.isHidden = !textView.text.isEmpty
    }
  #endif
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

    func textView(
      _ textView: UITextView,
      editMenuForTextIn range: NSRange,
      suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
      guard let selectionMenuTree, !selectionMenuTree.nodes.isEmpty else { return nil }
      let custom = buildUIKitMenuElements(from: selectionMenuTree.nodes) { [weak self] command in
        guard let self else { return }
        waterui_call_shared_action(command.action, self.env.inner)
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

    func textView(
      _ view: NSTextView,
      menu: NSMenu,
      for event: NSEvent,
      at charIndex: Int
    ) -> NSMenu? {
      guard let selectionMenuTree, !selectionMenuTree.nodes.isEmpty else { return menu }
      if !menu.items.isEmpty {
        menu.addItem(.separator())
      }
      appendAppKitMenuItems(
        selectionMenuTree.nodes,
        to: menu,
        target: self,
        action: #selector(performSelectionMenuAction(_:))
      )
      return menu
    }

    @objc private func performSelectionMenuAction(_ sender: NSMenuItem) {
      guard let action = sender.representedObject as? MenuActionRef else {
        fatalError("WaterUI selection menu item has no semantic action")
      }
      waterui_call_shared_action(action.command.action, env.inner)
    }
  }
#endif
