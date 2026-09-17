import CWaterUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

@MainActor
final class WuiControlAccessibility {
  private let label: WuiComputedObservation<WuiStyledStr>

  convenience init(
    consuming label: CWaterUI.WuiLabel,
    target: PlatformView,
    additionalTargets: [PlatformView] = [],
    visualLabel: PlatformView
  ) {
    guard let accessibilityLabel = label.accessibility_label else {
      fatalError("WaterUI control label has no accessibility signal")
    }
    self.init(
      label: WuiComputed<WuiStyledStr>(accessibilityLabel),
      target: target,
      additionalTargets: additionalTargets,
      visualLabel: visualLabel
    )
  }

  init(
    label: WuiComputed<WuiStyledStr>,
    target: PlatformView,
    additionalTargets: [PlatformView] = [],
    visualLabel: PlatformView
  ) {
    var targets: [PlatformView] = []
    targets.reserveCapacity(additionalTargets.count + 1)
    targets.append(target)
    targets.append(contentsOf: additionalTargets)
    let observation = WuiComputedObservation(label) { value, _ in
      Self.apply(value.toString(), to: targets)
    }
    self.label = observation

    Self.hideVisualLabelFromAccessibility(visualLabel)
    Self.apply(observation.value.toString(), to: targets)
  }

  private static func apply(_ label: String, to targets: [PlatformView]) {
    // Labels speak and appear in tooltips; the bidi isolates interpolation
    // inserts for layout are formatting marks and do not belong in either.
    let label = label.removingBidiControlCharacters
    for target in targets {
      #if canImport(UIKit)
        target.isAccessibilityElement = true
        target.accessibilityLabel = label
      #elseif canImport(AppKit)
        target.setAccessibilityElement(true)
        target.setAccessibilityLabel(label)
        target.toolTip = label
      #endif
    }
  }

  private static func hideVisualLabelFromAccessibility(_ visualLabel: PlatformView) {
    #if canImport(UIKit)
      visualLabel.accessibilityElementsHidden = true
    #elseif canImport(AppKit)
      visualLabel.setAccessibilityElement(false)
      visualLabel.setAccessibilityChildren([])
    #endif
  }
}
