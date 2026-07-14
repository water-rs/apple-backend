import CWaterUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

/// Component for Metadata<OnEvent>.
///
/// Handles interaction events (hover enter/move/exit) for the wrapped view.
/// The handler can be called multiple times (repeatable handler).
@MainActor
final class WuiOnEvent: PlatformView, WuiComponent {
  static var rawId: CWaterUI.WuiTypeId { waterui_metadata_on_event_id() }

  private let contentView: any WuiComponent
  private let env: WuiEnvironment
  private let event: WuiEvent
  private let handlerPtr: OpaquePointer

  #if canImport(AppKit)
    private var trackingArea: NSTrackingArea?
  #endif

  var stretchAxis: WuiStretchAxis {
    contentView.stretchAxis
  }

  required init(anyview: OpaquePointer, env: WuiEnvironment) {
    let metadata = waterui_force_as_metadata_on_event(anyview)

    self.env = env
    self.event = metadata.value.event
    guard let handler = metadata.value.handler else {
      fatalError("OnEvent metadata is missing its handler")
    }
    self.handlerPtr = handler

    // Resolve the content
    self.contentView = WuiAnyView.resolve(anyview: metadata.content, env: env)

    super.init(frame: .zero)

    contentView.translatesAutoresizingMaskIntoConstraints = true
    addSubview(contentView)

    #if canImport(AppKit)
      setupTrackingArea()
    #elseif canImport(UIKit)
      addGestureRecognizer(
        UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:))))
    #endif
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  #if canImport(AppKit)
    private func setupTrackingArea() {
      let options: NSTrackingArea.Options = [
        .mouseEnteredAndExited,
        .mouseMoved,
        .activeInKeyWindow,
        .inVisibleRect,
      ]
      let area = NSTrackingArea(
        rect: bounds,
        options: options,
        owner: self,
        userInfo: nil
      )
      trackingArea = area
      addTrackingArea(area)
    }

    override func updateTrackingAreas() {
      super.updateTrackingAreas()

      if let oldTrackingArea = trackingArea {
        removeTrackingArea(oldTrackingArea)
      }

      setupTrackingArea()
    }

    override func mouseEntered(with event: NSEvent) {
      super.mouseEntered(with: event)
      handleHoverEnter()
    }

    override func mouseMoved(with event: NSEvent) {
      super.mouseMoved(with: event)
      let localPoint = convert(event.locationInWindow, from: nil)
      handleHoverMove(x: Float(localPoint.x), y: Float(localPoint.y))
    }

    override func mouseExited(with event: NSEvent) {
      super.mouseExited(with: event)
      handleHoverExit()
    }
  #endif

  #if canImport(UIKit)
    @objc private func handleHover(_ gesture: UIHoverGestureRecognizer) {
      switch gesture.state {
      case .began:
        handleHoverEnter()
      case .changed:
        let localPoint = gesture.location(in: self)
        handleHoverMove(x: Float(localPoint.x), y: Float(localPoint.y))
      case .ended, .cancelled:
        handleHoverExit()
      default:
        break
      }
    }
  #endif

  private func handleHoverEnter() {
    if event == WuiEvent_HoverEnter {
      waterui_call_on_event(handlerPtr, env.inner)
    }
  }

  private func handleHoverExit() {
    if event == WuiEvent_HoverExit {
      waterui_call_on_event(handlerPtr, env.inner)
    }
  }

  private func handleHoverMove(x: Float, y: Float) {
    if event == WuiEvent_HoverMove {
      waterui_call_on_hover_event(handlerPtr, env.inner, x, y)
    }
  }

  @MainActor deinit {
    waterui_drop_on_event(handlerPtr)
  }

  func layoutPriority() -> Int32 {
    contentView.layoutPriority()
  }

  func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
    contentView.sizeThatFits(proposal)
  }

  #if canImport(UIKit)
    override func layoutSubviews() {
      super.layoutSubviews()
      contentView.frame = bounds
    }
  #elseif canImport(AppKit)
    override var isFlipped: Bool { true }

    override func layout() {
      super.layout()
      contentView.frame = bounds
    }
  #endif
}
