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
    final class WuiGpuSurfaceInputResponder: UIView, UITextInput {
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
