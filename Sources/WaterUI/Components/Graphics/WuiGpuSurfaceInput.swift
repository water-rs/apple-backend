// Compiled out when the app disables WaterUI's `gpu` feature, exactly like the
// surface this responder drives.
#if !WATERUI_NO_GPU
  // WuiGpuSurfaceInput.swift
  // Keyboard, IME and scroll input for GPU surfaces that ask for it.
  //
  // A `GpuSurface` whose renderer reports `wants_input_events` draws its own
  // interactive content — a browser engine, a terminal, an editor — and needs
  // the events themselves rather than the per-frame pointer snapshot
  // `waterui_gpu_surface_set_input` carries. This file is the AppKit/UIKit half
  // of that: it translates native events into the backend-neutral
  // `WuiSurfaceInputEvent` vocabulary and hands them to
  // `waterui_gpu_surface_send_input_event`. Nothing here knows what the surface
  // renders, and no platform keycode crosses the ABI — keys travel as their W3C
  // `KeyboardEvent.key` / `.code` names.

  import CWaterUI
  import Foundation
  import OSLog

  #if canImport(UIKit)
    import UIKit
  #elseif canImport(AppKit)
    import AppKit
  #endif

  private let gpuSurfaceInputLogger = Logger(
    subsystem: "dev.waterui",
    category: "GpuSurfaceInput"
  )

  /// The absent-caret sentinel the carrier's `caret` field uses.
  private let wuiSurfaceCaretNone: Int64 = -1

  /// Builds one carrier event with the fields its kind ignores left neutral.
  ///
  /// Every string field is owned by the callee, so all three are always built —
  /// a zeroed `WuiStr` has no array vtable and would crash on release.
  func wuiSurfaceInputEvent(
    kind: CWaterUI.WuiSurfaceInputEventKind,
    focused: Bool = false,
    modifiers: UInt32 = 0,
    x: Double = 0,
    y: Double = 0,
    pressed: Bool = false,
    button: CWaterUI.WuiSurfacePointerButton = WuiSurfacePointerButton_Primary,
    deltaX: Double = 0,
    deltaY: Double = 0,
    scrollUnit: CWaterUI.WuiScrollUnit = WuiScrollUnit_Pixel,
    finished: Bool = false,
    key: String = "",
    code: String = "",
    text: String = "",
    isRepeat: Bool = false,
    caret: Int64 = wuiSurfaceCaretNone
  ) -> CWaterUI.WuiSurfaceInputEvent {
    CWaterUI.WuiSurfaceInputEvent(
      kind: kind,
      focused: focused,
      modifiers: modifiers,
      x: x,
      y: y,
      pressed: pressed,
      button: button,
      delta_x: deltaX,
      delta_y: deltaY,
      scroll_unit: scrollUnit,
      finished: finished,
      key: WuiStr(string: key).intoInner(),
      code: WuiStr(string: code).intoInner(),
      text: WuiStr(string: text).intoInner(),
      repeat: isRepeat,
      caret: caret
    )
  }

  /// The `GpuSurface` state a responder forwards its events to.
  ///
  /// The responder never owns the state — `WuiGpuSurfaceRenderState` does, and
  /// drops it — so this is a plain borrow that the surface invalidates when it
  /// shuts down.
  @MainActor
  final class WuiGpuSurfaceInputCarrier {
    private var gpuState: OpaquePointer?

    init(gpuState: OpaquePointer) {
      self.gpuState = gpuState
    }

    /// Whether the semantic GPU view takes its own keyboard, IME and scroll input.
    static func wantsInputEvents(gpuState: OpaquePointer) -> Bool {
      waterui_gpu_surface_wants_input_events(gpuState)
    }

    /// Stops forwarding: the surface is about to drop the state this borrows.
    func invalidate() {
      gpuState = nil
    }

    /// Delivers one event, and reports whether it reached the view.
    @discardableResult
    func send(_ event: CWaterUI.WuiSurfaceInputEvent) -> Bool {
      guard let gpuState else {
        // The event's strings are owned by this call whatever happens to it, so
        // they are reclaimed here rather than leaked: wrapping each one hands
        // it back to the array vtable that allocated it.
        _ = WuiStr(event.key)
        _ = WuiStr(event.code)
        _ = WuiStr(event.text)
        return false
      }
      return waterui_gpu_surface_send_input_event(gpuState, event)
    }

    /// The view's text caret in logical surface-local points, if it has one.
    func imeCaret() -> CGRect? {
      guard let gpuState else { return nil }
      var rect = CWaterUI.WuiRect()
      guard waterui_gpu_surface_ime_caret(gpuState, &rect) else { return nil }
      return CGRect(
        x: CGFloat(rect.origin.x),
        y: CGFloat(rect.origin.y),
        width: CGFloat(rect.size.width),
        height: CGFloat(rect.size.height)
      )
    }
  }

  // MARK: - W3C key identity

  /// The W3C `KeyboardEvent.code` for a physical key, by platform scancode.
  ///
  /// The table is the whole reason no platform keycode crosses the ABI: a
  /// `GpuView` asks where a key *sits*, and every backend answers in the same
  /// vocabulary. Codes absent here are keys the platform reports but the W3C
  /// model has no name for; they travel as `Unidentified`.
  private let wuiSurfaceUnidentifiedCode = "Unidentified"

  #if canImport(AppKit)

    /// macOS virtual keycodes (`kVK_*`) to W3C `KeyboardEvent.code` names.
    private let wuiMacVirtualKeyCodes: [UInt16: String] = [
      0x00: "KeyA", 0x01: "KeyS", 0x02: "KeyD", 0x03: "KeyF", 0x04: "KeyH",
      0x05: "KeyG", 0x06: "KeyZ", 0x07: "KeyX", 0x08: "KeyC", 0x09: "KeyV",
      0x0A: "IntlBackslash", 0x0B: "KeyB", 0x0C: "KeyQ", 0x0D: "KeyW",
      0x0E: "KeyE", 0x0F: "KeyR", 0x10: "KeyY", 0x11: "KeyT", 0x12: "Digit1",
      0x13: "Digit2", 0x14: "Digit3", 0x15: "Digit4", 0x16: "Digit6",
      0x17: "Digit5", 0x18: "Equal", 0x19: "Digit9", 0x1A: "Digit7",
      0x1B: "Minus", 0x1C: "Digit8", 0x1D: "Digit0", 0x1E: "BracketRight",
      0x1F: "KeyO", 0x20: "KeyU", 0x21: "BracketLeft", 0x22: "KeyI",
      0x23: "KeyP", 0x24: "Enter", 0x25: "KeyL", 0x26: "KeyJ", 0x27: "Quote",
      0x28: "KeyK", 0x29: "Semicolon", 0x2A: "Backslash", 0x2B: "Comma",
      0x2C: "Slash", 0x2D: "KeyN", 0x2E: "KeyM", 0x2F: "Period", 0x30: "Tab",
      0x31: "Space", 0x32: "Backquote", 0x33: "Backspace", 0x35: "Escape",
      0x36: "OSRight", 0x37: "OSLeft", 0x38: "ShiftLeft", 0x39: "CapsLock",
      0x3A: "AltLeft", 0x3B: "ControlLeft", 0x3C: "ShiftRight",
      0x3D: "AltRight", 0x3E: "ControlRight", 0x3F: "Fn", 0x40: "F17",
      0x41: "NumpadDecimal", 0x43: "NumpadMultiply", 0x45: "NumpadAdd",
      0x47: "NumLock", 0x48: "VolumeUp", 0x49: "VolumeDown", 0x4A: "VolumeMute",
      0x4B: "NumpadDivide", 0x4C: "NumpadEnter", 0x4E: "NumpadSubtract",
      0x4F: "F18", 0x50: "F19", 0x51: "NumpadEqual", 0x52: "Numpad0",
      0x53: "Numpad1", 0x54: "Numpad2", 0x55: "Numpad3", 0x56: "Numpad4",
      0x57: "Numpad5", 0x58: "Numpad6", 0x59: "Numpad7", 0x5A: "F20",
      0x5B: "Numpad8", 0x5C: "Numpad9", 0x5D: "IntlYen", 0x5E: "IntlRo",
      0x5F: "NumpadComma", 0x60: "F5", 0x61: "F6", 0x62: "F7", 0x63: "F3",
      0x64: "F8", 0x65: "F9", 0x66: "Lang2", 0x67: "F11", 0x68: "Lang1",
      0x69: "F13", 0x6A: "F16", 0x6B: "F14", 0x6D: "F10", 0x6E: "ContextMenu",
      0x6F: "F12", 0x71: "F15", 0x72: "Help", 0x73: "Home", 0x74: "PageUp",
      0x75: "Delete", 0x76: "F4", 0x77: "End", 0x78: "F2", 0x79: "PageDown",
      0x7A: "F1", 0x7B: "ArrowLeft", 0x7C: "ArrowRight", 0x7D: "ArrowDown",
      0x7E: "ArrowUp",
    ]

    /// AppKit's private-use function-key code points to W3C `key` names.
    ///
    /// `charactersIgnoringModifiers` reports these keys as characters in
    /// Unicode's private-use area, which is exactly the platform detail the
    /// neutral vocabulary exists to hide.
    private let wuiMacFunctionKeyNames: [Int: String] = [
      NSUpArrowFunctionKey: "ArrowUp",
      NSDownArrowFunctionKey: "ArrowDown",
      NSLeftArrowFunctionKey: "ArrowLeft",
      NSRightArrowFunctionKey: "ArrowRight",
      NSF1FunctionKey: "F1", NSF2FunctionKey: "F2", NSF3FunctionKey: "F3",
      NSF4FunctionKey: "F4", NSF5FunctionKey: "F5", NSF6FunctionKey: "F6",
      NSF7FunctionKey: "F7", NSF8FunctionKey: "F8", NSF9FunctionKey: "F9",
      NSF10FunctionKey: "F10", NSF11FunctionKey: "F11", NSF12FunctionKey: "F12",
      NSF13FunctionKey: "F13", NSF14FunctionKey: "F14", NSF15FunctionKey: "F15",
      NSF16FunctionKey: "F16", NSF17FunctionKey: "F17", NSF18FunctionKey: "F18",
      NSF19FunctionKey: "F19", NSF20FunctionKey: "F20",
      NSInsertFunctionKey: "Insert",
      NSDeleteFunctionKey: "Delete",
      NSHomeFunctionKey: "Home",
      NSEndFunctionKey: "End",
      NSPageUpFunctionKey: "PageUp",
      NSPageDownFunctionKey: "PageDown",
      NSPrintScreenFunctionKey: "PrintScreen",
      NSScrollLockFunctionKey: "ScrollLock",
      NSPauseFunctionKey: "Pause",
      NSMenuFunctionKey: "ContextMenu",
      NSHelpFunctionKey: "Help",
      NSClearLineFunctionKey: "Clear",
    ]

    /// Control characters AppKit delivers for keys the W3C model names.
    private let wuiMacControlKeyNames: [Int: String] = [
      0x0D: "Enter",
      0x03: "Enter",
      0x09: "Tab",
      0x19: "Tab",
      0x1B: "Escape",
      0x7F: "Backspace",
    ]

    /// The W3C `KeyboardEvent.code` of the physical key this event came from.
    func wuiSurfaceCode(_ event: NSEvent) -> String {
      guard let code = wuiMacVirtualKeyCodes[event.keyCode] else {
        gpuSurfaceInputLogger.debug(
          "no W3C code for macOS virtual keycode \(event.keyCode, privacy: .public)")
        return wuiSurfaceUnidentifiedCode
      }
      return code
    }

    /// The W3C `KeyboardEvent.key` — the value the layout and modifiers produce.
    ///
    /// Modifier keys report themselves by name, function and control keys map
    /// out of AppKit's private-use encoding, and everything else is the
    /// character the key types.
    func wuiSurfaceKey(_ event: NSEvent, code: String) -> String {
      if let modifierName = wuiSurfaceModifierKeyName(code) {
        return modifierName
      }
      guard let characters = event.charactersIgnoringModifiers,
        let scalar = characters.unicodeScalars.first
      else {
        return wuiSurfaceUnidentifiedCode
      }
      let value = Int(scalar.value)
      if let name = wuiMacFunctionKeyNames[value] {
        return name
      }
      if let name = wuiMacControlKeyNames[value] {
        return name
      }
      // A chord such as ⌃A yields the control character, not the letter; the
      // W3C `key` for it is still the letter the physical key types.
      if value < 0x20, let printable = wuiMacPrintableForControl(event) {
        return printable
      }
      return characters
    }

    /// The unmodified character of a key whose event carries a control code.
    private func wuiMacPrintableForControl(_ event: NSEvent) -> String? {
      guard let characters = event.characters(byApplyingModifiers: []),
        let scalar = characters.unicodeScalars.first,
        scalar.value >= 0x20
      else {
        return nil
      }
      return characters
    }

    /// The W3C `key` of a modifier key, which is named rather than typed.
    private func wuiSurfaceModifierKeyName(_ code: String) -> String? {
      switch code {
      case "ShiftLeft", "ShiftRight": return "Shift"
      case "ControlLeft", "ControlRight": return "Control"
      case "AltLeft", "AltRight": return "Alt"
      case "OSLeft", "OSRight": return "Meta"
      case "CapsLock": return "CapsLock"
      case "NumLock": return "NumLock"
      case "Fn": return "Fn"
      default: return nil
      }
    }

    /// The modifier chord, as `WUI_SURFACE_MODIFIER_*` bits.
    func wuiSurfaceModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
      var bits: UInt32 = 0
      if flags.contains(.shift) { bits |= UInt32(WUI_SURFACE_MODIFIER_SHIFT) }
      if flags.contains(.control) { bits |= UInt32(WUI_SURFACE_MODIFIER_CONTROL) }
      if flags.contains(.option) { bits |= UInt32(WUI_SURFACE_MODIFIER_ALT) }
      if flags.contains(.command) { bits |= UInt32(WUI_SURFACE_MODIFIER_META) }
      if flags.contains(.capsLock) { bits |= UInt32(WUI_SURFACE_MODIFIER_CAPS_LOCK) }
      if flags.contains(.numericPad) { bits |= UInt32(WUI_SURFACE_MODIFIER_NUM_LOCK) }
      return bits
    }

  #elseif canImport(UIKit)

    /// UIKit `UIKeyboardHIDUsage` values to W3C `KeyboardEvent.code` names.
    ///
    /// `UIKey.keyCode` is a USB HID usage, so this is the HID keyboard page
    /// mapped onto the same vocabulary AppKit's virtual keycodes map onto.
    private let wuiHidUsageCodes: [Int: String] = [
      0x04: "KeyA", 0x05: "KeyB", 0x06: "KeyC", 0x07: "KeyD", 0x08: "KeyE",
      0x09: "KeyF", 0x0A: "KeyG", 0x0B: "KeyH", 0x0C: "KeyI", 0x0D: "KeyJ",
      0x0E: "KeyK", 0x0F: "KeyL", 0x10: "KeyM", 0x11: "KeyN", 0x12: "KeyO",
      0x13: "KeyP", 0x14: "KeyQ", 0x15: "KeyR", 0x16: "KeyS", 0x17: "KeyT",
      0x18: "KeyU", 0x19: "KeyV", 0x1A: "KeyW", 0x1B: "KeyX", 0x1C: "KeyY",
      0x1D: "KeyZ", 0x1E: "Digit1", 0x1F: "Digit2", 0x20: "Digit3",
      0x21: "Digit4", 0x22: "Digit5", 0x23: "Digit6", 0x24: "Digit7",
      0x25: "Digit8", 0x26: "Digit9", 0x27: "Digit0", 0x28: "Enter",
      0x29: "Escape", 0x2A: "Backspace", 0x2B: "Tab", 0x2C: "Space",
      0x2D: "Minus", 0x2E: "Equal", 0x2F: "BracketLeft", 0x30: "BracketRight",
      0x31: "Backslash", 0x33: "Semicolon", 0x34: "Quote", 0x35: "Backquote",
      0x36: "Comma", 0x37: "Period", 0x38: "Slash", 0x39: "CapsLock",
      0x3A: "F1", 0x3B: "F2", 0x3C: "F3", 0x3D: "F4", 0x3E: "F5", 0x3F: "F6",
      0x40: "F7", 0x41: "F8", 0x42: "F9", 0x43: "F10", 0x44: "F11",
      0x45: "F12", 0x46: "PrintScreen", 0x47: "ScrollLock", 0x48: "Pause",
      0x49: "Insert", 0x4A: "Home", 0x4B: "PageUp", 0x4C: "Delete",
      0x4D: "End", 0x4E: "PageDown", 0x4F: "ArrowRight", 0x50: "ArrowLeft",
      0x51: "ArrowDown", 0x52: "ArrowUp", 0x53: "NumLock",
      0x54: "NumpadDivide", 0x55: "NumpadMultiply", 0x56: "NumpadSubtract",
      0x57: "NumpadAdd", 0x58: "NumpadEnter", 0x59: "Numpad1",
      0x5A: "Numpad2", 0x5B: "Numpad3", 0x5C: "Numpad4", 0x5D: "Numpad5",
      0x5E: "Numpad6", 0x5F: "Numpad7", 0x60: "Numpad8", 0x61: "Numpad9",
      0x62: "Numpad0", 0x63: "NumpadDecimal", 0x64: "IntlBackslash",
      0x65: "ContextMenu", 0x67: "NumpadEqual", 0x68: "F13", 0x69: "F14",
      0x6A: "F15", 0x6B: "F16", 0x6C: "F17", 0x6D: "F18", 0x6E: "F19",
      0x6F: "F20", 0x75: "Help", 0x85: "NumpadComma", 0x87: "IntlRo",
      0x88: "Lang1", 0x89: "IntlYen", 0x8A: "Lang2", 0xE0: "ControlLeft",
      0xE1: "ShiftLeft", 0xE2: "AltLeft", 0xE3: "OSLeft", 0xE4: "ControlRight",
      0xE5: "ShiftRight", 0xE6: "AltRight", 0xE7: "OSRight",
    ]

    /// The W3C `key` a HID usage names on its own, before the layout speaks.
    private let wuiHidUsageKeys: [Int: String] = [
      0x28: "Enter", 0x29: "Escape", 0x2A: "Backspace", 0x2B: "Tab",
      0x39: "CapsLock", 0x3A: "F1", 0x3B: "F2", 0x3C: "F3", 0x3D: "F4",
      0x3E: "F5", 0x3F: "F6", 0x40: "F7", 0x41: "F8", 0x42: "F9",
      0x43: "F10", 0x44: "F11", 0x45: "F12", 0x46: "PrintScreen",
      0x47: "ScrollLock", 0x48: "Pause", 0x49: "Insert", 0x4A: "Home",
      0x4B: "PageUp", 0x4C: "Delete", 0x4D: "End", 0x4E: "PageDown",
      0x4F: "ArrowRight", 0x50: "ArrowLeft", 0x51: "ArrowDown",
      0x52: "ArrowUp", 0x53: "NumLock", 0x58: "Enter", 0x65: "ContextMenu",
      0x68: "F13", 0x69: "F14", 0x6A: "F15", 0x6B: "F16", 0x6C: "F17",
      0x6D: "F18", 0x6E: "F19", 0x6F: "F20", 0x75: "Help",
      0xE0: "Control", 0xE1: "Shift", 0xE2: "Alt", 0xE3: "Meta",
      0xE4: "Control", 0xE5: "Shift", 0xE6: "Alt", 0xE7: "Meta",
    ]

    /// The W3C `KeyboardEvent.code` of the physical key this press came from.
    func wuiSurfaceCode(_ key: UIKey) -> String {
      guard let code = wuiHidUsageCodes[key.keyCode.rawValue] else {
        gpuSurfaceInputLogger.debug(
          "no W3C code for HID usage \(key.keyCode.rawValue, privacy: .public)")
        return wuiSurfaceUnidentifiedCode
      }
      return code
    }

    /// The W3C `KeyboardEvent.key` this press produces.
    func wuiSurfaceKey(_ key: UIKey) -> String {
      if let named = wuiHidUsageKeys[key.keyCode.rawValue] {
        return named
      }
      let characters = key.charactersIgnoringModifiers
      if characters.isEmpty {
        return wuiSurfaceUnidentifiedCode
      }
      return characters
    }

    /// The modifier chord, as `WUI_SURFACE_MODIFIER_*` bits.
    func wuiSurfaceModifiers(_ flags: UIKeyModifierFlags) -> UInt32 {
      var bits: UInt32 = 0
      if flags.contains(.shift) { bits |= UInt32(WUI_SURFACE_MODIFIER_SHIFT) }
      if flags.contains(.control) { bits |= UInt32(WUI_SURFACE_MODIFIER_CONTROL) }
      if flags.contains(.alternate) { bits |= UInt32(WUI_SURFACE_MODIFIER_ALT) }
      if flags.contains(.command) { bits |= UInt32(WUI_SURFACE_MODIFIER_META) }
      if flags.contains(.alphaShift) { bits |= UInt32(WUI_SURFACE_MODIFIER_CAPS_LOCK) }
      if flags.contains(.numericPad) { bits |= UInt32(WUI_SURFACE_MODIFIER_NUM_LOCK) }
      return bits
    }

  #endif

  // MARK: - The responder

  #if canImport(AppKit)

    /// The first responder for a GPU surface that takes its own input.
    ///
    /// It sits on top of the surface's own view, claims the pointer and the
    /// keyboard, and speaks `NSTextInputClient` so an input method composes
    /// against the surface's caret. The surface itself keeps rendering; this
    /// view draws nothing.
    @MainActor
    final class WuiGpuSurfaceInputResponder: NSView, @preconcurrency NSTextInputClient {
      private let carrier: WuiGpuSurfaceInputCarrier
      private var trackingAreaToken: NSTrackingArea?
      private lazy var surfaceInputContext = NSTextInputContext(client: self)
      /// The pre-edit text the input method is currently composing, if any.
      private var markedText = ""
      private var markedSelection = NSRange(location: NSNotFound, length: 0)
      /// AppKit reports composition through `NSTextInputClient` callbacks that
      /// run inside `keyDown`; the key event itself is only sent when the input
      /// method did not consume it.
      private var handlingKeyDown = false
      private var keyDownWasConsumed = false

      init(carrier: WuiGpuSurfaceInputCarrier) {
        self.carrier = carrier
        super.init(frame: .zero)
      }

      @available(*, unavailable)
      required init?(coder: NSCoder) {
        fatalError("GpuSurface input responders do not support NSCoder initialization")
      }

      override var acceptsFirstResponder: Bool { true }

      override var inputContext: NSTextInputContext? { surfaceInputContext }

      override func becomeFirstResponder() -> Bool {
        carrier.send(wuiSurfaceInputEvent(kind: WuiSurfaceInputEventKind_Focus, focused: true))
        return true
      }

      override func resignFirstResponder() -> Bool {
        carrier.send(wuiSurfaceInputEvent(kind: WuiSurfaceInputEventKind_Focus, focused: false))
        return true
      }

      override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

      override func updateTrackingAreas() {
        if let trackingAreaToken {
          removeTrackingArea(trackingAreaToken)
        }
        let trackingArea = NSTrackingArea(
          rect: .zero,
          options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
          owner: self,
          userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaToken = trackingArea
        super.updateTrackingAreas()
      }

      // MARK: Pointer

      /// The event position in logical, surface-local points with y growing down.
      private func localPoint(_ event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x, y: bounds.height - point.y)
      }

      private func sendPointerMove(_ event: NSEvent) {
        let point = localPoint(event)
        sendModifiers(event)
        carrier.send(
          wuiSurfaceInputEvent(
            kind: WuiSurfaceInputEventKind_PointerMove,
            x: Double(point.x),
            y: Double(point.y)
          ))
      }

      private func sendPointerButton(
        _ event: NSEvent,
        pressed: Bool,
        button: CWaterUI.WuiSurfacePointerButton
      ) {
        let point = localPoint(event)
        sendModifiers(event)
        carrier.send(
          wuiSurfaceInputEvent(
            kind: WuiSurfaceInputEventKind_PointerButton,
            x: Double(point.x),
            y: Double(point.y),
            pressed: pressed,
            button: button
          ))
      }

      /// Publishes the chord an event carries before the event itself.
      ///
      /// The neutral vocabulary reports modifiers when they change; AppKit
      /// reports them on every event, so this keeps the view's chord current
      /// without the view having to read it off each event.
      private func sendModifiers(_ event: NSEvent) {
        carrier.send(
          wuiSurfaceInputEvent(
            kind: WuiSurfaceInputEventKind_Modifiers,
            modifiers: wuiSurfaceModifiers(event.modifierFlags)
          ))
      }

      override func mouseMoved(with event: NSEvent) { sendPointerMove(event) }
      override func mouseDragged(with event: NSEvent) { sendPointerMove(event) }
      override func rightMouseDragged(with event: NSEvent) { sendPointerMove(event) }
      override func otherMouseDragged(with event: NSEvent) { sendPointerMove(event) }

      override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendPointerButton(event, pressed: true, button: WuiSurfacePointerButton_Primary)
      }

      override func mouseUp(with event: NSEvent) {
        sendPointerButton(event, pressed: false, button: WuiSurfacePointerButton_Primary)
      }

      override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendPointerButton(event, pressed: true, button: WuiSurfacePointerButton_Secondary)
      }

      override func rightMouseUp(with event: NSEvent) {
        sendPointerButton(event, pressed: false, button: WuiSurfacePointerButton_Secondary)
      }

      override func otherMouseDown(with event: NSEvent) {
        guard let button = wuiSurfaceButton(number: event.buttonNumber) else { return }
        window?.makeFirstResponder(self)
        sendPointerButton(event, pressed: true, button: button)
      }

      override func otherMouseUp(with event: NSEvent) {
        guard let button = wuiSurfaceButton(number: event.buttonNumber) else { return }
        sendPointerButton(event, pressed: false, button: button)
      }

      /// AppKit's button numbers past the primary/secondary pair.
      ///
      /// The W3C vocabulary names five buttons; anything past forward has no
      /// neutral meaning and is not delivered rather than being reported as a
      /// button a view would misread.
      private func wuiSurfaceButton(number: Int) -> CWaterUI.WuiSurfacePointerButton? {
        switch number {
        case 2: return WuiSurfacePointerButton_Middle
        case 3: return WuiSurfacePointerButton_Back
        case 4: return WuiSurfacePointerButton_Forward
        default: return nil
        }
      }

      override func scrollWheel(with event: NSEvent) {
        let point = localPoint(event)
        sendModifiers(event)
        // A trackpad glide reports precise deltas already in points; a wheel
        // notch reports lines, and each notch is complete on its own.
        let precise = event.hasPreciseScrollingDeltas
        let finished = precise ? event.phase == .ended || event.momentumPhase == .ended : true
        carrier.send(
          wuiSurfaceInputEvent(
            kind: WuiSurfaceInputEventKind_Scroll,
            x: Double(point.x),
            y: Double(point.y),
            deltaX: Double(event.scrollingDeltaX),
            deltaY: Double(event.scrollingDeltaY),
            scrollUnit: precise ? WuiScrollUnit_Pixel : WuiScrollUnit_Line,
            finished: finished
          ))
      }

      // MARK: Keyboard

      override func flagsChanged(with event: NSEvent) {
        sendModifiers(event)
        // A modifier key is also a key: its own press and release cross as key
        // events so a view can see, say, a bare Command tap.
        let code = wuiSurfaceCode(event)
        guard code != wuiSurfaceUnidentifiedCode else { return }
        sendKey(event, pressed: modifierIsPressed(event, code: code), code: code)
      }

      /// Whether the modifier this `flagsChanged` reports went down or up.
      private func modifierIsPressed(_ event: NSEvent, code: String) -> Bool {
        let flags = event.modifierFlags
        switch code {
        case "ShiftLeft", "ShiftRight": return flags.contains(.shift)
        case "ControlLeft", "ControlRight": return flags.contains(.control)
        case "AltLeft", "AltRight": return flags.contains(.option)
        case "OSLeft", "OSRight": return flags.contains(.command)
        case "CapsLock": return flags.contains(.capsLock)
        case "Fn": return flags.contains(.function)
        default: return false
        }
      }

      private func sendKey(_ event: NSEvent, pressed: Bool, code: String) {
        carrier.send(
          wuiSurfaceInputEvent(
            kind: WuiSurfaceInputEventKind_Key,
            modifiers: wuiSurfaceModifiers(event.modifierFlags),
            pressed: pressed,
            key: wuiSurfaceKey(event, code: code),
            code: code,
            isRepeat: pressed && event.isARepeat
          ))
      }

      override func keyDown(with event: NSEvent) {
        // The input method sees the key first: a composing keystroke belongs to
        // the composition session, not to the view as a key event.
        handlingKeyDown = true
        keyDownWasConsumed = false
        let hadMarkedText = hasMarkedText()
        _ = inputContext?.handleEvent(event)
        handlingKeyDown = false
        if !keyDownWasConsumed && !hadMarkedText && !hasMarkedText() {
          sendKey(event, pressed: true, code: wuiSurfaceCode(event))
        }
      }

      override func keyUp(with event: NSEvent) {
        sendKey(event, pressed: false, code: wuiSurfaceCode(event))
      }

      // MARK: NSTextInputClient

      func insertText(_ string: Any, replacementRange: NSRange) {
        let text = plainText(string)
        let wasComposing = hasMarkedText()
        clearMarkedText()
        guard !text.isEmpty else {
          if wasComposing {
            carrier.send(
              wuiSurfaceInputEvent(
                kind: WuiSurfaceInputEventKind_CompositionCommit,
                text: ""
              ))
          }
          return
        }
        if handlingKeyDown {
          keyDownWasConsumed = true
        }
        // Text that ends a composition is that session's commit; text typed
        // outside one is a plain insertion.
        carrier.send(
          wuiSurfaceInputEvent(
            kind: wasComposing
              ? WuiSurfaceInputEventKind_CompositionCommit
              : WuiSurfaceInputEventKind_TextInput,
            text: text
          ))
      }

      override func doCommand(by selector: Selector) {
        guard selector == #selector(NSResponder.cancelOperation(_:)), hasMarkedText() else {
          return
        }
        clearMarkedText()
        keyDownWasConsumed = true
        carrier.send(wuiSurfaceInputEvent(kind: WuiSurfaceInputEventKind_CompositionCancel))
      }

      func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text = plainText(string)
        let wasComposing = hasMarkedText()
        if handlingKeyDown {
          keyDownWasConsumed = true
        }
        guard !text.isEmpty else {
          // AppKit clears the pre-edit with empty marked text; that abandons the
          // session rather than committing it.
          clearMarkedText()
          if wasComposing {
            carrier.send(wuiSurfaceInputEvent(kind: WuiSurfaceInputEventKind_CompositionCancel))
          }
          return
        }
        if !wasComposing {
          carrier.send(wuiSurfaceInputEvent(kind: WuiSurfaceInputEventKind_CompositionStart))
        }
        markedText = text
        markedSelection = selectedRange
        carrier.send(
          wuiSurfaceInputEvent(
            kind: WuiSurfaceInputEventKind_CompositionUpdate,
            text: text,
            caret: compositionCaret(text: text, selectedRange: selectedRange)
          ))
      }

      /// The caret's byte offset into the pre-edit text.
      ///
      /// AppKit counts UTF-16 code units and the neutral vocabulary counts
      /// bytes, so the prefix is re-measured rather than scaled.
      private func compositionCaret(text: String, selectedRange: NSRange) -> Int64 {
        guard selectedRange.location != NSNotFound,
          let index = Range(
            NSRange(location: 0, length: selectedRange.location), in: text)?.upperBound
        else {
          return wuiSurfaceCaretNone
        }
        return Int64(text.utf8.distance(from: text.startIndex, to: index))
      }

      func unmarkText() {
        guard hasMarkedText() else { return }
        let text = markedText
        clearMarkedText()
        // AppKit's `unmarkText` confirms the pre-edit as typed.
        carrier.send(
          wuiSurfaceInputEvent(
            kind: WuiSurfaceInputEventKind_CompositionCommit,
            text: text
          ))
      }

      private func clearMarkedText() {
        markedText = ""
        markedSelection = NSRange(location: NSNotFound, length: 0)
      }

      func selectedRange() -> NSRange { markedSelection }

      func markedRange() -> NSRange {
        markedText.isEmpty
          ? NSRange(location: NSNotFound, length: 0)
          : NSRange(location: 0, length: markedText.utf16.count)
      }

      func hasMarkedText() -> Bool { !markedText.isEmpty }

      func attributedSubstring(
        forProposedRange range: NSRange,
        actualRange: NSRangePointer?
      ) -> NSAttributedString? {
        // The surface owns its document and the neutral vocabulary is one-way:
        // the host mirrors no text and therefore has none to hand back.
        nil
      }

      func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        [.underlineStyle, .underlineColor, .markedClauseSegment]
      }

      func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = range
        guard let window else { return .zero }
        // The view reports its caret in logical surface-local points with y
        // growing down; AppKit wants screen coordinates with y growing up.
        let caret = carrier.imeCaret() ?? CGRect(origin: .zero, size: bounds.size)
        let flipped = CGRect(
          x: caret.origin.x,
          y: bounds.height - caret.origin.y - caret.height,
          width: caret.width,
          height: caret.height
        )
        return window.convertToScreen(convert(flipped, to: nil))
      }

      func characterIndex(for point: NSPoint) -> Int { NSNotFound }

      private func plainText(_ value: Any) -> String {
        if let value = value as? NSAttributedString {
          return value.string
        }
        guard let value = value as? String else {
          fatalError("AppKit supplied unsupported GpuSurface text input \(type(of: value))")
        }
        return value
      }
    }

  #elseif canImport(UIKit)

    /// The first responder for a GPU surface that takes its own input.
    ///
    /// UIKit drives composition through `UITextInput`, whose document model is
    /// the pre-edit buffer and nothing else: the neutral surface vocabulary is
    /// one-way plus a caret rect, so the surface owns the real document and the
    /// host deliberately mirrors none of it. Every position below is an offset
    /// into the text currently being composed.
    @MainActor
    final class WuiGpuSurfaceInputResponder: UIView, @preconcurrency UITextInput {
      private let carrier: WuiGpuSurfaceInputCarrier
      /// The pre-edit text the input method is currently composing.
      private var markedText = ""
      private var markedSelection = 0

      init(carrier: WuiGpuSurfaceInputCarrier) {
        self.carrier = carrier
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
      }

      @available(*, unavailable)
      required init?(coder: NSCoder) {
        fatalError("GpuSurface input responders do not support NSCoder initialization")
      }

      override var canBecomeFirstResponder: Bool { true }

      override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
          carrier.send(wuiSurfaceInputEvent(kind: WuiSurfaceInputEventKind_Focus, focused: true))
        }
        return became
      }

      override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
          carrier.send(wuiSurfaceInputEvent(kind: WuiSurfaceInputEventKind_Focus, focused: false))
        }
        return resigned
      }

      // MARK: Pointer

      private func sendPointer(_ touches: Set<UITouch>, pressed: Bool?) {
        guard let touch = touches.first else { return }
        let point = touch.location(in: self)
        if let pressed {
          carrier.send(
            wuiSurfaceInputEvent(
              kind: WuiSurfaceInputEventKind_PointerButton,
              x: Double(point.x),
              y: Double(point.y),
              pressed: pressed,
              button: WuiSurfacePointerButton_Primary
            ))
        } else {
          carrier.send(
            wuiSurfaceInputEvent(
              kind: WuiSurfaceInputEventKind_PointerMove,
              x: Double(point.x),
              y: Double(point.y)
            ))
        }
      }

      override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if !isFirstResponder {
          _ = becomeFirstResponder()
        }
        sendPointer(touches, pressed: nil)
        sendPointer(touches, pressed: true)
      }

      override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        sendPointer(touches, pressed: nil)
      }

      override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        sendPointer(touches, pressed: false)
      }

      override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        sendPointer(touches, pressed: false)
      }

      // MARK: Hardware keyboard

      override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !sendPresses(presses, pressed: true) {
          super.pressesBegan(presses, with: event)
        }
      }

      override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !sendPresses(presses, pressed: false) {
          super.pressesEnded(presses, with: event)
        }
      }

      override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !sendPresses(presses, pressed: false) {
          super.pressesCancelled(presses, with: event)
        }
      }

      private func sendPresses(_ presses: Set<UIPress>, pressed: Bool) -> Bool {
        var delivered = false
        for press in presses {
          guard let key = press.key else { continue }
          carrier.send(
            wuiSurfaceInputEvent(
              kind: WuiSurfaceInputEventKind_Modifiers,
              modifiers: wuiSurfaceModifiers(key.modifierFlags)
            ))
          carrier.send(
            wuiSurfaceInputEvent(
              kind: WuiSurfaceInputEventKind_Key,
              modifiers: wuiSurfaceModifiers(key.modifierFlags),
              pressed: pressed,
              key: wuiSurfaceKey(key),
              code: wuiSurfaceCode(key)
            ))
          delivered = true
        }
        return delivered
      }

      // MARK: UIKeyInput

      var hasText: Bool { !markedText.isEmpty }

      func insertText(_ text: String) {
        let wasComposing = hasMarkedTextSession
        clearMarkedText()
        carrier.send(
          wuiSurfaceInputEvent(
            kind: wasComposing
              ? WuiSurfaceInputEventKind_CompositionCommit
              : WuiSurfaceInputEventKind_TextInput,
            text: text
          ))
      }

      func deleteBackward() {
        // The software keyboard's delete key is a key press, not an edit the
        // host can perform: the surface owns the document.
        for pressed in [true, false] {
          carrier.send(
            wuiSurfaceInputEvent(
              kind: WuiSurfaceInputEventKind_Key,
              pressed: pressed,
              key: "Backspace",
              code: "Backspace"
            ))
        }
      }

      // MARK: UITextInput — composition

      private var hasMarkedTextSession: Bool { !markedText.isEmpty }

      var markedTextRange: UITextRange? {
        hasMarkedTextSession
          ? WuiSurfaceTextRange(start: 0, end: markedText.utf16.count)
          : nil
      }

      var markedTextStyle: [NSAttributedString.Key: Any]?

      func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        let text = markedText ?? ""
        let wasComposing = hasMarkedTextSession
        guard !text.isEmpty else {
          clearMarkedText()
          if wasComposing {
            carrier.send(wuiSurfaceInputEvent(kind: WuiSurfaceInputEventKind_CompositionCancel))
          }
          return
        }
        if !wasComposing {
          carrier.send(wuiSurfaceInputEvent(kind: WuiSurfaceInputEventKind_CompositionStart))
        }
        self.markedText = text
        markedSelection = selectedRange.location == NSNotFound ? 0 : selectedRange.location
        carrier.send(
          wuiSurfaceInputEvent(
            kind: WuiSurfaceInputEventKind_CompositionUpdate,
            text: text,
            caret: compositionCaret(text: text, utf16Offset: markedSelection)
          ))
      }

      /// The caret's byte offset into the pre-edit text.
      private func compositionCaret(text: String, utf16Offset: Int) -> Int64 {
        guard
          let index = Range(NSRange(location: 0, length: utf16Offset), in: text)?.upperBound
        else {
          return wuiSurfaceCaretNone
        }
        return Int64(text.utf8.distance(from: text.startIndex, to: index))
      }

      func unmarkText() {
        guard hasMarkedTextSession else { return }
        let text = markedText
        clearMarkedText()
        carrier.send(
          wuiSurfaceInputEvent(
            kind: WuiSurfaceInputEventKind_CompositionCommit,
            text: text
          ))
      }

      private func clearMarkedText() {
        markedText = ""
        markedSelection = 0
      }

      // MARK: UITextInput — the pre-edit document
      //
      // Every method below describes the composition buffer, which is the only
      // text this host knows. Outside a composition the document is empty, and
      // UIKit asks nothing else of it.

      var selectedTextRange: UITextRange? {
        get { WuiSurfaceTextRange(start: markedSelection, end: markedSelection) }
        set {
          guard let range = newValue as? WuiSurfaceTextRange else { return }
          markedSelection = range.startOffset
        }
      }

      var beginningOfDocument: UITextPosition { WuiSurfaceTextPosition(offset: 0) }

      var endOfDocument: UITextPosition {
        WuiSurfaceTextPosition(offset: markedText.utf16.count)
      }

      weak var inputDelegate: UITextInputDelegate?

      lazy var tokenizer: UITextInputTokenizer = UITextInputStringTokenizer(textInput: self)

      func text(in range: UITextRange) -> String? {
        guard let range = range as? WuiSurfaceTextRange,
          let start = Range(
            NSRange(
              location: range.startOffset,
              length: range.endOffset - range.startOffset
            ), in: markedText)
        else {
          return nil
        }
        return String(markedText[start])
      }

      func replace(_ range: UITextRange, withText text: String) {
        // The host holds no document to edit; a replacement is the input method
        // rewriting its own pre-edit, which arrives as `setMarkedText` instead.
        insertText(text)
      }

      func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition)
        -> UITextRange?
      {
        guard let from = fromPosition as? WuiSurfaceTextPosition,
          let to = toPosition as? WuiSurfaceTextPosition
        else { return nil }
        return WuiSurfaceTextRange(
          start: min(from.offset, to.offset),
          end: max(from.offset, to.offset)
        )
      }

      func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        guard let position = position as? WuiSurfaceTextPosition else { return nil }
        let moved = position.offset + offset
        guard moved >= 0, moved <= markedText.utf16.count else { return nil }
        return WuiSurfaceTextPosition(offset: moved)
      }

      func position(
        from position: UITextPosition,
        in direction: UITextLayoutDirection,
        offset: Int
      ) -> UITextPosition? {
        let signed = direction == .left || direction == .up ? -offset : offset
        return self.position(from: position, offset: signed)
      }

      func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        guard let position = position as? WuiSurfaceTextPosition,
          let other = other as? WuiSurfaceTextPosition
        else { return .orderedSame }
        if position.offset < other.offset { return .orderedAscending }
        if position.offset > other.offset { return .orderedDescending }
        return .orderedSame
      }

      func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        guard let from = from as? WuiSurfaceTextPosition,
          let to = toPosition as? WuiSurfaceTextPosition
        else { return 0 }
        return to.offset - from.offset
      }

      func position(
        within range: UITextRange,
        farthestIn direction: UITextLayoutDirection
      ) -> UITextPosition? {
        guard let range = range as? WuiSurfaceTextRange else { return nil }
        let towardsStart = direction == .left || direction == .up
        return WuiSurfaceTextPosition(offset: towardsStart ? range.startOffset : range.endOffset)
      }

      func characterRange(
        byExtending position: UITextPosition,
        in direction: UITextLayoutDirection
      ) -> UITextRange? {
        guard let position = position as? WuiSurfaceTextPosition else { return nil }
        let towardsStart = direction == .left || direction == .up
        let other = towardsStart ? position.offset - 1 : position.offset + 1
        guard other >= 0, other <= markedText.utf16.count else { return nil }
        return WuiSurfaceTextRange(
          start: min(position.offset, other),
          end: max(position.offset, other)
        )
      }

      func baseWritingDirection(
        for position: UITextPosition,
        in direction: UITextStorageDirection
      ) -> NSWritingDirection {
        .natural
      }

      func setBaseWritingDirection(
        _ writingDirection: NSWritingDirection,
        for range: UITextRange
      ) {
        // The surface lays out its own text and owns its writing direction.
      }

      func firstRect(for range: UITextRange) -> CGRect {
        carrier.imeCaret() ?? .zero
      }

      func caretRect(for position: UITextPosition) -> CGRect {
        carrier.imeCaret() ?? .zero
      }

      func selectionRects(for range: UITextRange) -> [UITextSelectionRect] { [] }

      func closestPosition(to point: CGPoint) -> UITextPosition? {
        WuiSurfaceTextPosition(offset: markedSelection)
      }

      func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? {
        closestPosition(to: point)
      }

      func characterRange(at point: CGPoint) -> UITextRange? { nil }
    }

    /// A position in the pre-edit buffer, counted in UTF-16 code units.
    private final class WuiSurfaceTextPosition: UITextPosition {
      let offset: Int

      init(offset: Int) {
        self.offset = offset
        super.init()
      }
    }

    /// A range of the pre-edit buffer, counted in UTF-16 code units.
    private final class WuiSurfaceTextRange: UITextRange {
      let startOffset: Int
      let endOffset: Int

      init(start: Int, end: Int) {
        self.startOffset = start
        self.endOffset = end
        super.init()
      }

      override var start: UITextPosition { WuiSurfaceTextPosition(offset: startOffset) }
      override var end: UITextPosition { WuiSurfaceTextPosition(offset: endOffset) }
      override var isEmpty: Bool { startOffset == endOffset }
    }

  #endif
#endif  // !WATERUI_NO_GPU
