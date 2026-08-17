import CWaterUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

@MainActor
private protocol WuiNativeToggleControl {
  var view: PlatformView { get }

  func installAction(target: AnyObject, action: Selector)
  func setOn(_ isOn: Bool, metadata: WuiWatcherMetadata?)
  func valueAfterUserInteraction() -> Bool
  func setEnabled(_ enabled: Bool)
}

#if canImport(UIKit)
  @MainActor
  private final class WuiNativeSwitchControl: WuiNativeToggleControl {
    let control = UISwitch()

    var view: PlatformView { control }

    init(isOn: Bool) {
      control.isOn = isOn
    }

    func installAction(target: AnyObject, action: Selector) {
      control.addTarget(target, action: action, for: .valueChanged)
    }

    func setOn(_ isOn: Bool, metadata: WuiWatcherMetadata?) {
      guard control.isOn != isOn else { return }
      guard let metadata else {
        control.isOn = isOn
        return
      }
      control.setOn(
        isOn,
        animated: shouldAnimate(parseAnimation(metadata.getAnimation()))
      )
    }

    func valueAfterUserInteraction() -> Bool {
      control.isOn
    }

    func setEnabled(_ enabled: Bool) {
      control.isEnabled = enabled
    }
  }

  @MainActor
  private final class WuiNativeCheckboxControl: WuiNativeToggleControl {
    let control: UIButton

    var view: PlatformView { control }

    init(isOn: Bool) {
      guard
        let uncheckedImage = UIImage(systemName: "square"),
        let checkedImage = UIImage(systemName: "checkmark.square.fill")
      else {
        fatalError("WaterUI checkbox requires the system square symbols")
      }
      let control = UIButton(type: .system)
      control.setPreferredSymbolConfiguration(
        UIImage.SymbolConfiguration(textStyle: .body),
        forImageIn: .normal
      )
      control.setImage(uncheckedImage, for: .normal)
      control.setImage(checkedImage, for: .selected)
      control.isSelected = isOn
      control.changesSelectionAsPrimaryAction = true
      control.adjustsImageSizeForAccessibilityContentSizeCategory = true
      self.control = control
    }

    func installAction(target: AnyObject, action: Selector) {
      control.addTarget(target, action: action, for: .primaryActionTriggered)
    }

    func setOn(_ isOn: Bool, metadata: WuiWatcherMetadata?) {
      guard control.isSelected != isOn else { return }
      if let metadata {
        withCrossDissolveAnimation(control, metadata) {
          self.control.isSelected = isOn
        }
      } else {
        control.isSelected = isOn
      }
    }

    func valueAfterUserInteraction() -> Bool {
      control.isSelected
    }

    func setEnabled(_ enabled: Bool) {
      control.isEnabled = enabled
    }
  }
#elseif canImport(AppKit)
  @MainActor
  private final class WuiSwitch: NSSwitch {
    override func mouseDown(with event: NSEvent) {
      // Keep the responder entry point on the composed control so AppKit enters
      // NSSwitch's native tracking loop after WaterUI wrapper hit testing.
      super.mouseDown(with: event)
    }
  }

  @MainActor
  private final class WuiNativeSwitchControl: WuiNativeToggleControl {
    let control = WuiSwitch()

    var view: PlatformView { control }

    init(isOn: Bool) {
      control.state = isOn ? .on : .off
    }

    func installAction(target: AnyObject, action: Selector) {
      control.target = target
      control.action = action
    }

    func setOn(_ isOn: Bool, metadata: WuiWatcherMetadata?) {
      let state: NSControl.StateValue = isOn ? .on : .off
      guard control.state != state else { return }
      if let metadata {
        withPlatformAnimation(metadata) {
          self.control.state = state
        }
      } else {
        control.state = state
      }
    }

    func valueAfterUserInteraction() -> Bool {
      control.state == .on
    }

    func setEnabled(_ enabled: Bool) {
      control.isEnabled = enabled
    }
  }

  @MainActor
  private final class WuiNativeCheckboxControl: WuiNativeToggleControl {
    let control: NSButton

    var view: PlatformView { control }

    init(isOn: Bool) {
      let control = NSButton(checkboxWithTitle: "", target: nil, action: nil)
      control.state = isOn ? .on : .off
      self.control = control
    }

    func installAction(target: AnyObject, action: Selector) {
      control.target = target
      control.action = action
    }

    func setOn(_ isOn: Bool, metadata: WuiWatcherMetadata?) {
      let state: NSControl.StateValue = isOn ? .on : .off
      guard control.state != state else { return }
      if let metadata {
        withPlatformAnimation(metadata) {
          self.control.state = state
        }
      } else {
        control.state = state
      }
    }

    func valueAfterUserInteraction() -> Bool {
      control.state == .on
    }

    func setEnabled(_ enabled: Bool) {
      control.isEnabled = enabled
    }
  }
#endif

@MainActor
final class WuiToggle: PlatformView, WuiComponent {
  static var rawId: CWaterUI.WuiTypeId { waterui_toggle_id() }

  private let toggleControl: any WuiNativeToggleControl
  private let binding: WuiBinding<Bool>
  private let labelView: WuiAnyView
  private let disabled: WuiComputed<Bool>
  private var bindingWatcher: WatcherGuard?
  private var disabledWatcher: WatcherGuard?
  private var accessibility: WuiControlAccessibility?
  private let horizontalSpacing: CGFloat = 8

  convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
    let ffiToggle = waterui_force_as_toggle(anyview)
    self.init(
      label: WuiAnyView(anyview: ffiToggle.label.view, env: env),
      binding: WuiBinding(ffiToggle.toggle),
      style: ffiToggle.style,
      disabled: env.disabled,
      semanticLabel: ffiToggle.label
    )
  }

  init(
    label: WuiAnyView,
    binding: WuiBinding<Bool>,
    style: WuiToggleStyle,
    disabled: WuiComputed<Bool>,
    semanticLabel: CWaterUI.WuiLabel
  ) {
    self.toggleControl = Self.makeToggleControl(style: style, isOn: binding.value)
    self.binding = binding
    self.labelView = label
    self.disabled = disabled

    super.init(frame: .zero)

    configureSubviews()
    toggleControl.installAction(target: self, action: #selector(valueChanged))
    startWatchingBinding()
    startWatchingDisabled()
    accessibility = WuiControlAccessibility(
      consuming: semanticLabel,
      target: toggleControl.view,
      visualLabel: label
    )
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private static func makeToggleControl(
    style: WuiToggleStyle,
    isOn: Bool
  ) -> any WuiNativeToggleControl {
    switch style {
    case WuiToggleStyle_Automatic:
      // What the platform itself reaches for. A Mac writes a boolean setting as
      // a checkbox beside its label — the switch is the phone's answer, and
      // measured against SwiftUI a `Toggle` in a macOS form is a checkbox. Both
      // remain available by asking for them.
      #if canImport(UIKit)
        return WuiNativeSwitchControl(isOn: isOn)
      #elseif canImport(AppKit)
        return WuiNativeCheckboxControl(isOn: isOn)
      #endif
    case WuiToggleStyle_Switch:
      return WuiNativeSwitchControl(isOn: isOn)
    case WuiToggleStyle_Checkbox:
      return WuiNativeCheckboxControl(isOn: isOn)
    default:
      fatalError("Unsupported WaterUI toggle style: \(style.rawValue)")
    }
  }

  func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
    let labelSize = labelView.sizeThatFits(WuiProposalSize())
    let controlSize = toggleControl.view.intrinsicContentSize
    let hasLabel = labelSize.width > 0 && labelSize.height > 0
    let intrinsicWidth = controlSize.width + (hasLabel ? horizontalSpacing + labelSize.width : 0)
    let width: CGFloat
    if hasLabel, let proposedWidth = proposal.width {
      width = max(CGFloat(proposedWidth), intrinsicWidth)
    } else {
      width = intrinsicWidth
    }
    return CGSize(width: width, height: max(controlSize.height, labelSize.height))
  }

  private func configureSubviews() {
    let controlView = toggleControl.view
    labelView.translatesAutoresizingMaskIntoConstraints = false
    controlView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(labelView)
    addSubview(controlView)

    labelView.setContentCompressionResistancePriority(.required, for: .horizontal)
    labelView.setContentHuggingPriority(.defaultHigh, for: .horizontal)

    NSLayoutConstraint.activate([
      labelView.leadingAnchor.constraint(equalTo: leadingAnchor),
      labelView.centerYAnchor.constraint(equalTo: centerYAnchor),
      controlView.trailingAnchor.constraint(equalTo: trailingAnchor),
      controlView.centerYAnchor.constraint(equalTo: centerYAnchor),
      labelView.trailingAnchor.constraint(
        lessThanOrEqualTo: controlView.leadingAnchor,
        constant: -horizontalSpacing
      ),
    ])
  }

  private func startWatchingBinding() {
    bindingWatcher = binding.watch { [weak self] isOn, metadata in
      self?.toggleControl.setOn(isOn, metadata: metadata)
    }
    toggleControl.setOn(binding.value, metadata: nil)
  }

  private func startWatchingDisabled() {
    disabledWatcher = disabled.watch { [weak self] isDisabled, _ in
      self?.toggleControl.setEnabled(!isDisabled)
    }
    toggleControl.setEnabled(!disabled.value)
  }

  @objc private func valueChanged() {
    binding.value = toggleControl.valueAfterUserInteraction()
  }
}
