@preconcurrency import AppKit
import CWaterUI
import QuartzCore
import WaterUI

private let cefWheelDelta: CGFloat = 120
private let cefRangeNotFound = UInt32.max

private struct CefReplacementRange {
  let start: UInt32
  let end: UInt32
}

private struct CefPendingComposition {
  let text: String
  let selectionStart: UInt32
  let selectionEnd: UInt32
  let replacement: CefReplacementRange
}

/// Installs CEF's AppKit integration before `NSApplication.shared` is accessed.
@MainActor
public func prepareWaterUICEFApplication() {
  waterui_cef_prepare_macos_application()
}

/// Shared AppKit host for WaterUI's CEF-backed Chromium and WebView components.
@MainActor
open class CefSurfaceView: NSView, @preconcurrency NSTextInputClient {
  public let stretchAxis: WaterUI.WuiStretchAxis = .both

  private let cefState: OpaquePointer
  private var trackingAreaToken: NSTrackingArea?
  private var primaryButton = false
  private var middleButton = false
  private var secondaryButton = false
  private var wheelRemainder = CGPoint.zero
  private var markedText = ""
  private var markedSelection = NSRange(location: NSNotFound, length: 0)
  private lazy var cefInputContext = NSTextInputContext(client: self)
  private var handlingKeyDown = false
  private var hadMarkedTextBeforeKeyDown = false
  private var pendingInsertedText = ""
  private var pendingComposition: CefPendingComposition?
  private var pendingUnmark = false
  private var displayLink: CADisplayLink?
  private var screenChangeObserver: NSObjectProtocol?

  public init(surface: CWaterUI.WuiCefSurface, env: WuiEnvironment) {
    guard let state = surface.state else {
      fatalError("CEF surface was created without input state")
    }
    self.cefState = state
    let gpuView = makeWaterUIGpuSurface(
      stretchAxis: .both,
      ffiSurface: surface.gpu_surface,
      env: env
    )
    super.init(frame: .zero)
    gpuView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(gpuView)
    NSLayoutConstraint.activate([
      gpuView.leadingAnchor.constraint(equalTo: leadingAnchor),
      gpuView.trailingAnchor.constraint(equalTo: trailingAnchor),
      gpuView.topAnchor.constraint(equalTo: topAnchor),
      gpuView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  @available(*, unavailable)
  public required init?(coder: NSCoder) {
    fatalError("CEF surfaces do not support NSCoder initialization")
  }

  @MainActor deinit {
    if let screenChangeObserver {
      NotificationCenter.default.removeObserver(screenChangeObserver)
    }
    displayLink?.invalidate()
    waterui_cef_surface_drop(cefState)
  }

  open override var acceptsFirstResponder: Bool { true }

  open override var inputContext: NSTextInputContext? {
    cefInputContext
  }

  open override func becomeFirstResponder() -> Bool {
    waterui_cef_surface_set_focus(cefState, true)
    return true
  }

  open override func resignFirstResponder() -> Bool {
    waterui_cef_surface_set_focus(cefState, false)
    return true
  }

  open override func hitTest(_ point: NSPoint) -> NSView? {
    bounds.contains(point) ? self : nil
  }

  open override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updateViewport()
    if let screenChangeObserver {
      NotificationCenter.default.removeObserver(screenChangeObserver)
      self.screenChangeObserver = nil
    }
    if window == nil {
      displayLink?.invalidate()
      displayLink = nil
    } else {
      installDisplayLink()
    }
  }

  open override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    updateViewport()
  }

  open override func layout() {
    super.layout()
    updateViewport()
  }

  open override func updateTrackingAreas() {
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

  open func layoutPriority() -> Int32 { 0 }

  open func sizeThatFits(_ proposal: WaterUI.WuiProposalSize) -> CGSize {
    CGSize(
      width: CGFloat(proposal.width ?? 0),
      height: CGFloat(proposal.height ?? 0)
    )
  }

  open override func mouseMoved(with event: NSEvent) {
    sendPointerMove(event)
  }

  open override func mouseDragged(with event: NSEvent) {
    sendPointerMove(event)
  }

  open override func rightMouseDragged(with event: NSEvent) {
    sendPointerMove(event)
  }

  open override func otherMouseDragged(with event: NSEvent) {
    sendPointerMove(event)
  }

  open override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    primaryButton = true
    sendPointerButton(event, pressed: true, button: WuiCefPointerButton_Primary)
  }

  open override func mouseUp(with event: NSEvent) {
    primaryButton = false
    sendPointerButton(event, pressed: false, button: WuiCefPointerButton_Primary)
  }

  open override func rightMouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    secondaryButton = true
    sendPointerButton(event, pressed: true, button: WuiCefPointerButton_Secondary)
  }

  open override func rightMouseUp(with event: NSEvent) {
    secondaryButton = false
    sendPointerButton(event, pressed: false, button: WuiCefPointerButton_Secondary)
  }

  open override func otherMouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    switch event.buttonNumber {
    case 2:
      middleButton = true
      sendPointerButton(event, pressed: true, button: WuiCefPointerButton_Middle)
    case 3:
      waterui_cef_surface_go_back(cefState)
    case 4:
      waterui_cef_surface_go_forward(cefState)
    default:
      fatalError("CEF received unsupported AppKit pointer button \(event.buttonNumber)")
    }
  }

  open override func otherMouseUp(with event: NSEvent) {
    switch event.buttonNumber {
    case 2:
      middleButton = false
      sendPointerButton(event, pressed: false, button: WuiCefPointerButton_Middle)
    case 3, 4:
      break
    default:
      fatalError("CEF received unsupported AppKit pointer button \(event.buttonNumber)")
    }
  }

  open override func scrollWheel(with event: NSEvent) {
    let point = localPoint(event)
    let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : cefWheelDelta
    let delta = CGPoint(
      x: event.scrollingDeltaX * multiplier + wheelRemainder.x,
      y: event.scrollingDeltaY * multiplier + wheelRemainder.y
    )
    let integral = CGPoint(x: delta.x.rounded(), y: delta.y.rounded())
    wheelRemainder = CGPoint(x: delta.x - integral.x, y: delta.y - integral.y)
    waterui_cef_surface_scroll(
      cefState,
      point.x,
      point.y,
      integral.x,
      integral.y,
      modifiers(event)
    )
  }

  open override func keyDown(with event: NSEvent) {
    if let command = editCommand(event) {
      sendKey(event, pressed: true, text: nil)
      waterui_cef_surface_edit(cefState, command)
      return
    }
    beginKeyDown()
    _ = inputContext?.handleEvent(event)
    finishKeyDown(event)
  }

  open override func keyUp(with event: NSEvent) {
    sendKey(event, pressed: false, text: event.characters)
  }

  open override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard let command = editCommand(event) else {
      return super.performKeyEquivalent(with: event)
    }
    sendKey(event, pressed: true, text: nil)
    waterui_cef_surface_edit(cefState, command)
    return true
  }

  public func insertText(_ string: Any, replacementRange: NSRange) {
    let text = plainText(string)
    if handlingKeyDown {
      pendingInsertedText.append(text)
    } else {
      let replacement = cefReplacementRange(replacementRange)
      waterui_cef_surface_commit_text(
        cefState,
        WuiStr(string: text).intoInner(),
        replacement.start,
        replacement.end
      )
    }
    markedText = ""
    markedSelection = NSRange(location: NSNotFound, length: 0)
  }

  open override func doCommand(by selector: Selector) {
    switch selector {
    case #selector(NSResponder.cancelOperation(_:)):
      if hasMarkedText() {
        waterui_cef_surface_cancel_composition(cefState)
        markedText = ""
        markedSelection = NSRange(location: NSNotFound, length: 0)
      }
    default:
      break
    }
  }

  public func setMarkedText(
    _ string: Any,
    selectedRange: NSRange,
    replacementRange: NSRange
  ) {
    let text = plainText(string)
    let utf16Length = text.utf16.count
    precondition(
      selectedRange.location != NSNotFound
        && selectedRange.location + selectedRange.length <= utf16Length,
      "AppKit supplied an invalid CEF marked-text selection"
    )
    markedText = text
    markedSelection = selectedRange
    let replacement = cefReplacementRange(replacementRange)
    let composition = CefPendingComposition(
      text: text,
      selectionStart: UInt32(selectedRange.location),
      selectionEnd: UInt32(selectedRange.location + selectedRange.length),
      replacement: replacement
    )
    if handlingKeyDown {
      pendingComposition = composition
    } else {
      sendComposition(composition)
    }
  }

  public func unmarkText() {
    if handlingKeyDown {
      pendingUnmark = true
    } else {
      waterui_cef_surface_finish_composition(cefState, false)
    }
    markedText = ""
    markedSelection = NSRange(location: NSNotFound, length: 0)
  }

  public func selectedRange() -> NSRange {
    markedSelection
  }

  public func markedRange() -> NSRange {
    guard !markedText.isEmpty else {
      return NSRange(location: NSNotFound, length: 0)
    }
    return NSRange(location: 0, length: markedText.utf16.count)
  }

  public func hasMarkedText() -> Bool {
    !markedText.isEmpty
  }

  public func attributedSubstring(
    forProposedRange range: NSRange,
    actualRange: NSRangePointer?
  ) -> NSAttributedString? {
    nil
  }

  public func validAttributesForMarkedText() -> [NSAttributedString.Key] {
    [.underlineStyle, .underlineColor, .markedClauseSegment]
  }

  public func firstRect(
    forCharacterRange range: NSRange,
    actualRange: NSRangePointer?
  ) -> NSRect {
    actualRange?.pointee = range
    guard let window else {
      return .zero
    }
    let windowRect = convert(bounds, to: nil)
    return window.convertToScreen(windowRect)
  }

  public func characterIndex(for point: NSPoint) -> Int {
    NSNotFound
  }

  private func updateViewport() {
    guard bounds.width > 0, bounds.height > 0 else {
      return
    }
    let width =
      UInt32(exactly: Int(bounds.width.rounded(.up)))
      ?? { fatalError("CEF viewport width exceeds UInt32") }()
    let height =
      UInt32(exactly: Int(bounds.height.rounded(.up)))
      ?? { fatalError("CEF viewport height exceeds UInt32") }()
    waterui_cef_surface_set_viewport(
      cefState,
      width,
      height,
      Double(window?.backingScaleFactor ?? 1)
    )
  }

  private func installDisplayLink() {
    guard displayLink == nil else { return }
    guard let window else {
      fatalError("CEF display link requires an attached AppKit window")
    }
    let link = window.displayLink(target: self, selector: #selector(requestCefFrame))
    Self.applyFrameRatePreference(link: link, screen: window.screen)
    link.add(to: .main, forMode: .common)
    displayLink = link
    // A window can attach before it lands on a display, and it can migrate
    // between displays with different refresh ceilings; re-derive the range
    // whenever the screen changes instead of crashing or freezing at the
    // first screen's rate.
    screenChangeObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didChangeScreenNotification,
      object: window,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, let link = self.displayLink else { return }
        Self.applyFrameRatePreference(link: link, screen: self.window?.screen)
      }
    }
  }

  private static func applyFrameRatePreference(link: CADisplayLink, screen: NSScreen?) {
    // A window between displays reports no screen; 60 is the floor every
    // display provides, and the screen-change observer raises the range once
    // the window lands on a high-refresh display.
    let maximumFramesPerSecond = Float(screen?.maximumFramesPerSecond ?? 60)
    link.preferredFrameRateRange = CAFrameRateRange(
      minimum: min(60, maximumFramesPerSecond),
      maximum: maximumFramesPerSecond,
      preferred: maximumFramesPerSecond
    )
  }

  @objc private func requestCefFrame() {
    waterui_cef_surface_request_frame(cefState)
  }

  private func localPoint(_ event: NSEvent) -> CGPoint {
    let point = convert(event.locationInWindow, from: nil)
    return CGPoint(x: point.x, y: bounds.height - point.y)
  }

  private func modifiers(_ event: NSEvent) -> CWaterUI.WuiCefInputModifiers {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    return CWaterUI.WuiCefInputModifiers(
      shift: flags.contains(.shift),
      control: flags.contains(.control),
      alt: flags.contains(.option),
      command: flags.contains(.command),
      primary_button: primaryButton,
      middle_button: middleButton,
      secondary_button: secondaryButton
    )
  }

  private func sendPointerMove(_ event: NSEvent) {
    let point = localPoint(event)
    waterui_cef_surface_pointer_move(cefState, point.x, point.y, modifiers(event))
  }

  private func sendPointerButton(
    _ event: NSEvent,
    pressed: Bool,
    button: CWaterUI.WuiCefPointerButton
  ) {
    let point = localPoint(event)
    waterui_cef_surface_pointer_button(
      cefState,
      pressed,
      button,
      point.x,
      point.y,
      modifiers(event)
    )
  }

  private func sendKey(_ event: NSEvent, pressed: Bool, text: String?) {
    waterui_cef_surface_key(
      cefState,
      pressed,
      UInt32(event.keyCode),
      0,
      cefCharacter(text),
      modifiers(event)
    )
  }

  private func beginKeyDown() {
    precondition(!handlingKeyDown, "CEF text input recursively entered keyDown")
    handlingKeyDown = true
    hadMarkedTextBeforeKeyDown = hasMarkedText()
    pendingInsertedText = ""
    pendingComposition = nil
    pendingUnmark = false
  }

  private func finishKeyDown(_ event: NSEvent) {
    precondition(handlingKeyDown, "CEF text input finished without an active keyDown")
    handlingKeyDown = false

    let insertedLength = pendingInsertedText.utf16.count
    if !hasMarkedText() && !hadMarkedTextBeforeKeyDown && insertedLength <= 1 {
      sendKey(event, pressed: true, text: pendingInsertedText)
    }

    let directCharacterLimit = hasMarkedText() || hadMarkedTextBeforeKeyDown ? 0 : 1
    if insertedLength > directCharacterLimit {
      waterui_cef_surface_commit_text(
        cefState,
        WuiStr(string: pendingInsertedText).intoInner(),
        cefRangeNotFound,
        cefRangeNotFound
      )
    }

    if let pendingComposition {
      sendComposition(pendingComposition)
    } else if hadMarkedTextBeforeKeyDown && !hasMarkedText() && pendingInsertedText.isEmpty {
      if pendingUnmark {
        waterui_cef_surface_finish_composition(cefState, false)
      } else {
        waterui_cef_surface_cancel_composition(cefState)
      }
    }
  }

  private func sendComposition(_ composition: CefPendingComposition) {
    waterui_cef_surface_set_composition(
      cefState,
      WuiStr(string: composition.text).intoInner(),
      composition.selectionStart,
      composition.selectionEnd,
      composition.replacement.start,
      composition.replacement.end
    )
  }

  private func cefReplacementRange(_ range: NSRange) -> CefReplacementRange {
    guard range.location != NSNotFound else {
      precondition(range.length == 0, "CEF absent replacement range has non-zero length")
      return CefReplacementRange(start: cefRangeNotFound, end: cefRangeNotFound)
    }
    let end = range.location.addingReportingOverflow(range.length)
    precondition(!end.overflow, "CEF replacement range overflowed NSUInteger")
    return CefReplacementRange(
      start: UInt32(exactly: range.location)
        ?? { fatalError("CEF replacement start exceeds UInt32") }(),
      end: UInt32(exactly: end.partialValue)
        ?? { fatalError("CEF replacement end exceeds UInt32") }()
    )
  }

  private func cefCharacter(_ text: String?) -> UInt32 {
    guard let text, text.utf16.count == 1, let codeUnit = text.utf16.first else {
      return 0
    }
    return UInt32(codeUnit)
  }

  private func editCommand(_ event: NSEvent) -> CWaterUI.WuiCefEditCommand? {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard flags.contains(.command), !flags.contains(.control), !flags.contains(.option),
      let characters = event.charactersIgnoringModifiers?.lowercased()
    else {
      return nil
    }
    switch (characters, flags.contains(.shift)) {
    case ("z", false): return WuiCefEditCommand_Undo
    case ("z", true): return WuiCefEditCommand_Redo
    case ("x", false): return WuiCefEditCommand_Cut
    case ("c", false): return WuiCefEditCommand_Copy
    case ("v", false): return WuiCefEditCommand_Paste
    case ("a", false): return WuiCefEditCommand_SelectAll
    default: return nil
    }
  }

  private func plainText(_ value: Any) -> String {
    if let value = value as? NSAttributedString {
      return value.string
    }
    guard let value = value as? String else {
      fatalError("AppKit supplied unsupported CEF text input \(type(of: value))")
    }
    return value
  }
}
