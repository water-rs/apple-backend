import Foundation

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

@MainActor
protocol WuiFocusTarget: AnyObject {
  var view: PlatformView { get }
  var hasPlatformFocus: Bool { get }

  func requestPlatformFocus()
  func clearPlatformFocus()
  func observePlatformFocusChanges(_ onChange: @escaping (Bool) -> Void) -> WuiFocusObservation
}

final class WuiFocusObservation: NSObject {
  private let cancelImpl: () -> Void

  init(cancel: @escaping () -> Void) {
    self.cancelImpl = cancel
  }

  deinit {
    cancelImpl()
  }
}

@MainActor
class WuiFocusTargetBase: NSObject {
  private var observers: [Int: (Bool) -> Void] = [:]
  private var nextObserverId = 0

  final func observePlatformFocusChanges(_ onChange: @escaping (Bool) -> Void)
    -> WuiFocusObservation
  {
    let observerId = nextObserverId
    nextObserverId += 1
    observers[observerId] = onChange

    return WuiFocusObservation { [weak self] in
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        guard self.observers.removeValue(forKey: observerId) != nil else {
          fatalError("Focus observer was released more than once")
        }
      }
    }
  }

  final func emitPlatformFocusChange(_ hasFocus: Bool) {
    for observer in observers.values {
      observer(hasFocus)
    }
  }
}

#if canImport(UIKit)
  @MainActor
  final class WuiUIKitFocusTarget<Control: UIView>: WuiFocusTargetBase, WuiFocusTarget {
    private unowned let control: Control

    init(control: Control) {
      self.control = control
    }

    var view: PlatformView { control }

    var hasPlatformFocus: Bool {
      control.isFirstResponder
    }

    func requestPlatformFocus() {
      guard control.window != nil else {
        fatalError(
          "Metadata<Focused> tried to focus a TextField/SecureField anchor before it was attached to a window."
        )
      }
      guard control.becomeFirstResponder() else {
        fatalError("Metadata<Focused> failed to focus its resolved TextField/SecureField anchor.")
      }
    }

    func clearPlatformFocus() {
      guard control.resignFirstResponder() else {
        fatalError("Metadata<Focused> failed to blur its resolved TextField/SecureField anchor.")
      }
    }
  }
#elseif canImport(AppKit)
  @MainActor
  final class WuiAppKitTextFieldFocusTarget<Control: NSTextField>: WuiFocusTargetBase,
    WuiFocusTarget
  {
    private unowned let control: Control

    init(control: Control) {
      self.control = control
    }

    var view: PlatformView { control }

    var hasPlatformFocus: Bool {
      control.currentEditor() != nil || control.window?.firstResponder === control
    }

    func requestPlatformFocus() {
      guard let window = control.window else {
        fatalError(
          "Metadata<Focused> tried to focus a TextField/SecureField anchor before it was attached to a window."
        )
      }
      guard window.makeFirstResponder(control) else {
        fatalError("Metadata<Focused> failed to focus its resolved TextField/SecureField anchor.")
      }
    }

    func clearPlatformFocus() {
      guard let window = control.window else {
        fatalError(
          "Metadata<Focused> lost its window while clearing a TextField/SecureField anchor.")
      }
      guard window.makeFirstResponder(nil) else {
        fatalError("Metadata<Focused> failed to blur its resolved TextField/SecureField anchor.")
      }
    }
  }
#endif

@MainActor
private final class WuiFocusTargetBox: NSObject {
  let target: any WuiFocusTarget

  init(_ target: any WuiFocusTarget) {
    self.target = target
  }
}

@MainActor
extension PlatformView {
  func installWuiFocusTarget(_ target: any WuiFocusTarget) {
    objc_setAssociatedObject(
      self,
      "dev.waterui.focusTarget",
      WuiFocusTargetBox(target),
      .OBJC_ASSOCIATION_RETAIN_NONATOMIC
    )
  }

  func requireSingleWuiFocusTarget() -> any WuiFocusTarget {
    var targets: [any WuiFocusTarget] = []
    collectWuiFocusTargets(into: &targets)

    switch targets.count {
    case 1:
      return targets[0]
    case 0:
      fatalError(
        "Metadata<Focused> requires exactly one TextField or SecureField focus anchor in its subtree, found 0."
      )
    default:
      fatalError(
        "Metadata<Focused> requires exactly one TextField or SecureField focus anchor in its subtree, found \(targets.count)."
      )
    }
  }

  private func collectWuiFocusTargets(into targets: inout [any WuiFocusTarget]) {
    if let box = objc_getAssociatedObject(self, "dev.waterui.focusTarget") as? WuiFocusTargetBox {
      targets.append(box.target)
    }

    for subview in subviews {
      subview.collectWuiFocusTargets(into: &targets)
    }
  }
}

@MainActor
final class WuiFocusedBindingController: NSObject {
  private weak var container: PlatformView?
  private let focusTarget: any WuiFocusTarget
  private let binding: WuiBinding<Bool>
  private var bindingWatcher: WatcherGuard?
  private var nativeFocusObserver: WuiFocusObservation?
  private var hasScheduledSync = false

  init(container: PlatformView, focusTarget: any WuiFocusTarget, binding: WuiBinding<Bool>) {
    self.container = container
    self.focusTarget = focusTarget
    self.binding = binding
    super.init()

    nativeFocusObserver = focusTarget.observePlatformFocusChanges { [weak self] hasFocus in
      guard let self else { return }
      if self.binding.value != hasFocus {
        self.binding.set(hasFocus)
      }
    }

    bindingWatcher = binding.watch { [weak self] _, _ in
      self?.syncRequestedFocusState()
    }

    syncRequestedFocusState()
  }

  func syncRequestedFocusState() {
    guard !hasScheduledSync else { return }
    hasScheduledSync = true

    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.hasScheduledSync = false
      self.performScheduledSync()
    }
  }

  private func performScheduledSync() {
    guard let container, container.window != nil, focusTarget.view.window != nil else { return }

    if binding.value {
      if !focusTarget.hasPlatformFocus {
        focusTarget.requestPlatformFocus()
      }
      return
    }

    if focusTarget.hasPlatformFocus {
      focusTarget.clearPlatformFocus()
    }
  }
}
