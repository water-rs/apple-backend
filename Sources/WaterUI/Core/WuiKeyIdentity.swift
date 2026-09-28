// WuiKeyIdentity.swift
// W3C `KeyboardEvent.key` / `.code` / modifier mapping for native key events.
//
// No platform keycode crosses the WaterUI ABI: both GPU surface input and
// `OnKeyPress` metadata translate native events into the same W3C vocabulary.
// Codes absent from these tables are keys the platform reports but the W3C
// model has no name for; they travel as `Unidentified`.

import CWaterUI
import OSLog

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

private let keyInputLogger = Logger(
  subsystem: "dev.waterui",
  category: "KeyInput"
)

  // MARK: - W3C key identity

  /// The W3C `KeyboardEvent.code` for a physical key, by platform scancode.
  ///
  /// The table is the whole reason no platform keycode crosses the ABI: a
  /// `GpuView` asks where a key *sits*, and every backend answers in the same
  /// vocabulary. Codes absent here are keys the platform reports but the W3C
  /// model has no name for; they travel as `Unidentified`.
  let wuiSurfaceUnidentifiedCode = "Unidentified"

  #if canImport(AppKit)

    /// macOS virtual keycodes (`kVK_*`) to W3C `KeyboardEvent.code` names.
    let wuiMacVirtualKeyCodes: [UInt16: String] = [
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
    let wuiMacFunctionKeyNames: [Int: String] = [
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
    let wuiMacControlKeyNames: [Int: String] = [
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
        keyInputLogger.debug(
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
    func wuiMacPrintableForControl(_ event: NSEvent) -> String? {
      guard let characters = event.characters(byApplyingModifiers: []),
        let scalar = characters.unicodeScalars.first,
        scalar.value >= 0x20
      else {
        return nil
      }
      return characters
    }

    /// The W3C `key` of a modifier key, which is named rather than typed.
    func wuiSurfaceModifierKeyName(_ code: String) -> String? {
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
    let wuiHidUsageCodes: [Int: String] = [
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
    let wuiHidUsageKeys: [Int: String] = [
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
    @MainActor
    func wuiSurfaceCode(_ key: UIKey) -> String {
      guard let code = wuiHidUsageCodes[key.keyCode.rawValue] else {
        keyInputLogger.debug(
          "no W3C code for HID usage \(key.keyCode.rawValue, privacy: .public)")
        return wuiSurfaceUnidentifiedCode
      }
      return code
    }

    /// The W3C `KeyboardEvent.key` this press produces.
    @MainActor
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
