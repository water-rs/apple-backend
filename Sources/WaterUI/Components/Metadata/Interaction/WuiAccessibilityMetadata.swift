import CWaterUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

@MainActor
class WuiAccessibilityMetadataView: PlatformView {
  let contentView: any WuiComponent

  var accessibilityTarget: PlatformView {
    var target: PlatformView = contentView
    while let metadata = target as? WuiAccessibilityMetadataView {
      target = metadata.contentView
    }
    return target
  }

  init(contentView: any WuiComponent) {
    self.contentView = contentView
    super.init(frame: .zero)
    contentView.translatesAutoresizingMaskIntoConstraints = true
    addSubview(contentView)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  var stretchAxis: WuiStretchAxis { contentView.stretchAxis }
  func layoutPriority() -> Int32 { contentView.layoutPriority() }
  func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize { contentView.sizeThatFits(proposal) }

  #if canImport(UIKit)
    override func layoutSubviews() {
      super.layoutSubviews()
      contentView.frame = bounds
    }
  #elseif canImport(AppKit)
    nonisolated override var isFlipped: Bool { true }

    override func layout() {
      super.layout()
      contentView.frame = bounds
    }
  #endif
}

@MainActor
final class WuiAccessibilityLabel: WuiAccessibilityMetadataView, WuiComponent {
  static var rawId: WuiTypeId { waterui_ignorable_metadata_accessibility_label_id() }
  private var observation: WuiComputedObservation<WuiStyledStr>?

  required init(anyview: OpaquePointer, env: WuiEnvironment) {
    let metadata = waterui_force_as_ignorable_metadata_accessibility_label(anyview)
    super.init(contentView: WuiAnyView.resolve(anyview: metadata.content, env: env))
    guard let label = metadata.label else { fatalError("accessibility label signal is null") }
    let observation = WuiComputedObservation(WuiComputed<WuiStyledStr>(label)) {
      [weak self] value, _ in self?.apply(label: value.toString())
    }
    self.observation = observation
    apply(label: observation.value.toString())
  }

  private func apply(label: String) {
    #if canImport(UIKit)
      accessibilityTarget.isAccessibilityElement = true
      accessibilityTarget.accessibilityLabel = label
    #elseif canImport(AppKit)
      accessibilityTarget.setAccessibilityElement(true)
      accessibilityTarget.setAccessibilityLabel(label)
    #endif
  }
}

@MainActor
final class WuiAccessibilityRole: WuiAccessibilityMetadataView, WuiComponent {
  static var rawId: WuiTypeId { waterui_ignorable_metadata_accessibility_role_id() }

  required init(anyview: OpaquePointer, env: WuiEnvironment) {
    let metadata = waterui_force_as_ignorable_metadata_accessibility_role(anyview)
    super.init(contentView: WuiAnyView.resolve(anyview: metadata.content, env: env))
    apply(role: metadata.value)
  }

  private func apply(role: Int32) {
    #if canImport(UIKit)
      accessibilityTarget.isAccessibilityElement = true
      let roleTraits: UIAccessibilityTraits = switch role {
      case 0, 13, 14, 15, 18, 22, 24, 25, 26: .button
      case 1: .link
      case 2: .image
      case 3, 5, 9, 12: .staticText
      case 4: .header
      case 8: .searchField
      case 16: .adjustable
      case 17: .updatesFrequently
      case 6, 7, 10, 11, 19, 20, 21, 23, 27, 28: []
      default: fatalError("unknown WaterUI accessibility role: \(role)")
      }
      var traits = accessibilityTarget.accessibilityTraits
      traits.remove([.button, .link, .image, .staticText, .header, .searchField, .adjustable,
                     .updatesFrequently])
      traits.formUnion(roleTraits)
      accessibilityTarget.accessibilityTraits = traits
    #elseif canImport(AppKit)
      accessibilityTarget.setAccessibilityElement(true)
      let accessibilityRole: NSAccessibility.Role = switch role {
      case 0: .button
      case 1: .link
      case 2: .image
      case 3: .staticText
      case 4: .group
      case 11: .list
      case 13, 24: .checkBox
      case 14, 25: .radioButton
      case 16: .slider
      case 17: .progressIndicator
      case 18: .button
      case 19: .tabGroup
      case 21: .menu
      case 22: .menuItem
      case 23: .menuBar
      case 26: .comboBox
      case 5...10, 12, 15, 20, 27, 28: .group
      default: fatalError("unknown WaterUI accessibility role: \(role)")
      }
      accessibilityTarget.setAccessibilityRole(accessibilityRole)
    #endif
  }
}

@MainActor
final class WuiAccessibilityHidden: WuiAccessibilityMetadataView, WuiComponent {
  static var rawId: WuiTypeId { waterui_ignorable_metadata_accessibility_hidden_id() }

  required init(anyview: OpaquePointer, env: WuiEnvironment) {
    let metadata = waterui_force_as_ignorable_metadata_accessibility_hidden(anyview)
    super.init(contentView: WuiAnyView.resolve(anyview: metadata.content, env: env))
    #if canImport(UIKit)
      accessibilityTarget.accessibilityElementsHidden = metadata.value != 0
    #elseif canImport(AppKit)
      accessibilityTarget.setAccessibilityElement(metadata.value == 0)
    #endif
  }
}

@MainActor
final class WuiAccessibilityChildren: WuiAccessibilityMetadataView, WuiComponent {
  static var rawId: WuiTypeId { waterui_ignorable_metadata_accessibility_children_id() }

  required init(anyview: OpaquePointer, env: WuiEnvironment) {
    let metadata = waterui_force_as_ignorable_metadata_accessibility_children(anyview)
    super.init(contentView: WuiAnyView.resolve(anyview: metadata.content, env: env))
    guard metadata.value != 0 else { return }
    #if canImport(UIKit)
      accessibilityTarget.isAccessibilityElement = true
      accessibilityTarget.accessibilityElementsHidden = true
    #elseif canImport(AppKit)
      accessibilityTarget.setAccessibilityElement(true)
      accessibilityTarget.setAccessibilityChildren([])
    #endif
  }
}

@MainActor
class WuiAccessibilityStateView: WuiAccessibilityMetadataView {
  private var observations: [AnyObject] = []
  private var disabled = false
  private var selected = false
  private var checked: Int32 = -1
  private var expanded: Int32 = -1
  private var busy = false
  #if canImport(UIKit)
    private lazy var originalAccessibilityValue = accessibilityTarget.accessibilityValue
    private lazy var originalAccessibilityHint = accessibilityTarget.accessibilityHint
    private lazy var originalAccessibilityElementsHidden = accessibilityTarget.accessibilityElementsHidden
  #elseif canImport(AppKit)
    private lazy var originalIsAccessibilityElement = accessibilityTarget.isAccessibilityElement()
  #endif

  func bind(_ state: CWaterUI.WuiAccessibilityState) {
    bind(state.disabled) { [weak self] in self?.disabled = $0 }
    bind(state.selected) { [weak self] in self?.selected = $0 }
    bind(state.checked) { [weak self] in self?.checked = $0 }
    bind(state.expanded) { [weak self] in self?.expanded = $0 }
    bind(state.busy) { [weak self] in self?.busy = $0 }
    bind(state.hidden) { [weak self] value in self?.apply(hidden: value) }
  }

  private func bind(_ pointer: OpaquePointer?, apply: @escaping (Bool) -> Void) {
    guard let pointer else { fatalError("accessibility state signal is null") }
    let observation = WuiComputedObservation(WuiComputed<Bool>(pointer)) { [weak self] value, _ in
      apply(value)
      self?.applyState()
    }
    observations.append(observation)
    apply(observation.value)
    applyState()
  }

  private func bind(_ pointer: OpaquePointer?, apply: @escaping (Int32) -> Void) {
    guard let pointer else { fatalError("accessibility state signal is null") }
    let observation = WuiComputedObservation(WuiComputed<Int32>(pointer)) { [weak self] value, _ in
      apply(value)
      self?.applyState()
    }
    observations.append(observation)
    apply(observation.value)
    applyState()
  }

  private func applyState() {
    #if canImport(UIKit)
      accessibilityTarget.isAccessibilityElement = true
      accessibilityTarget.accessibilityTraits.setValue(disabled, for: .notEnabled)
      accessibilityTarget.accessibilityTraits.setValue(selected, for: .selected)
      accessibilityTarget.accessibilityValue = switch checked {
      case 0: NSLocalizedString("Unchecked", comment: "Accessibility unchecked state")
      case 1: NSLocalizedString("Checked", comment: "Accessibility checked state")
      case 2: NSLocalizedString("Mixed", comment: "Accessibility mixed state")
      case -1: originalAccessibilityValue
      default: fatalError("unknown WaterUI accessibility checked state: \(checked)")
      }
      accessibilityTarget.accessibilityHint = busy
        ? NSLocalizedString("Busy", comment: "Accessibility busy state")
        : originalAccessibilityHint
    #elseif canImport(AppKit)
      accessibilityTarget.setAccessibilityElement(true)
      accessibilityTarget.setAccessibilityEnabled(!disabled)
      accessibilityTarget.setAccessibilitySelected(selected)
      if checked >= 0 {
        let platformValue: Int32 = switch checked {
        case 0: 0
        case 1: 1
        case 2: -1
        default: fatalError("unknown WaterUI accessibility checked state: \(checked)")
        }
        accessibilityTarget.setAccessibilityValue(platformValue)
        let valueDescription: String? = switch checked {
        case 0: NSLocalizedString("Unchecked", comment: "Accessibility unchecked state")
        case 1: NSLocalizedString("Checked", comment: "Accessibility checked state")
        case 2: NSLocalizedString("Mixed", comment: "Accessibility mixed state")
        default: nil
        }
        accessibilityTarget.setAccessibilityValueDescription(valueDescription)
      }
      switch expanded {
      case -1: break
      case 0: accessibilityTarget.setAccessibilityExpanded(false)
      case 1: accessibilityTarget.setAccessibilityExpanded(true)
      default: fatalError("unknown WaterUI accessibility expanded state: \(expanded)")
      }
      accessibilityTarget.setAccessibilityHelp(
        busy ? NSLocalizedString("Busy", comment: "Accessibility busy state") : nil
      )
    #endif
  }

  private func apply(hidden: Bool) {
    #if canImport(UIKit)
      accessibilityTarget.accessibilityElementsHidden = hidden
        ? true
        : originalAccessibilityElementsHidden
    #elseif canImport(AppKit)
      accessibilityTarget.setAccessibilityElement(hidden ? false : originalIsAccessibilityElement)
    #endif
  }
}

@MainActor
final class WuiAccessibilityState: WuiAccessibilityStateView, WuiComponent {
  static var rawId: WuiTypeId { waterui_ignorable_metadata_accessibility_state_id() }

  required init(anyview: OpaquePointer, env: WuiEnvironment) {
    let metadata = waterui_force_as_ignorable_metadata_accessibility_state(anyview)
    super.init(contentView: WuiAnyView.resolve(anyview: metadata.content, env: env))
    bind(metadata.state)
  }
}

@MainActor
final class WuiAccessibilityStateSignal: WuiAccessibilityStateView, WuiComponent {
  static var rawId: WuiTypeId { waterui_ignorable_metadata_accessibility_state_signal_id() }

  required init(anyview: OpaquePointer, env: WuiEnvironment) {
    let metadata = waterui_force_as_ignorable_metadata_accessibility_state_signal(anyview)
    super.init(contentView: WuiAnyView.resolve(anyview: metadata.content, env: env))
    bind(metadata.state)
  }
}

#if canImport(UIKit)
  private extension UIAccessibilityTraits {
    mutating func setValue(_ enabled: Bool, for trait: UIAccessibilityTraits) {
      if enabled { insert(trait) } else { remove(trait) }
    }
  }
#endif
