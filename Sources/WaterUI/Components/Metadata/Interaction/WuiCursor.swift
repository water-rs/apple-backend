import CWaterUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

/// Component for Metadata<Cursor>.
///
/// Sets the cursor style when the pointer is over the wrapped view.
/// The cursor automatically resets when the pointer exits the view bounds.
@MainActor
final class WuiCursor: PlatformView, WuiComponent {
  static var rawId: CWaterUI.WuiTypeId { waterui_metadata_cursor_id() }

  private let contentView: any WuiComponent
  private var styleObservation: WuiComputedObservation<WuiCursorStyle>?
  private var currentStyle: WuiCursorStyle = WuiCursorStyle_Arrow

  #if canImport(AppKit)
    private var trackingArea: NSTrackingArea?
    private var isMouseInside = false
  #endif

  var stretchAxis: WuiStretchAxis {
    contentView.stretchAxis
  }

  required init(anyview: OpaquePointer, env: WuiEnvironment) {
    let metadata = waterui_force_as_metadata_cursor(anyview)

    // Resolve the content
    self.contentView = WuiAnyView.resolve(anyview: metadata.content, env: env)

    super.init(frame: .zero)

    contentView.translatesAutoresizingMaskIntoConstraints = true
    addSubview(contentView)

    // Setup watcher for reactive cursor style
    setupWatcher(metadata.value)

    #if canImport(AppKit)
      setupTrackingAreaIfNeeded()
    #elseif canImport(UIKit)
      addInteraction(UIPointerInteraction(delegate: self))
    #endif
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupWatcher(_ cursor: CWaterUI.WuiCursor) {
    let observation = WuiComputedObservation(WuiComputed<WuiCursorStyle>(cursor.style)) {
      [weak self] value, _ in
      guard let self else { return }
      self.currentStyle = value
      #if canImport(AppKit)
        if self.isMouseInside {
          self.applyCursor()
        }
      #endif
    }
    styleObservation = observation
    currentStyle = observation.value
  }

  #if canImport(AppKit)
    private func setupTrackingAreaIfNeeded() {
      guard trackingArea == nil else { return }
      let options: NSTrackingArea.Options = [
        .mouseEnteredAndExited,
        .cursorUpdate,
        .activeInKeyWindow,
        .inVisibleRect,
      ]
      let area = NSTrackingArea(
        rect: .zero,
        options: options,
        owner: self,
        userInfo: nil
      )
      trackingArea = area
      addTrackingArea(area)
    }

    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      setupTrackingAreaIfNeeded()
    }

    override func mouseEntered(with event: NSEvent) {
      super.mouseEntered(with: event)
      guard !isMouseInside else { return }
      isMouseInside = true
      applyCursor()
    }

    override func mouseExited(with event: NSEvent) {
      super.mouseExited(with: event)
      guard isMouseInside else { return }
      isMouseInside = false
      NSCursor.arrow.set()
    }

    override func cursorUpdate(with event: NSEvent) {
      super.cursorUpdate(with: event)
      applyCursor()
    }

    private func applyCursor() {
      let cursor = nsCursor(for: currentStyle)
      cursor.set()
    }

    private func nsCursor(for style: WuiCursorStyle) -> NSCursor {
      switch style {
      case WuiCursorStyle_Arrow:
        return .arrow
      case WuiCursorStyle_PointingHand:
        return .pointingHand
      case WuiCursorStyle_IBeam:
        return .iBeam
      case WuiCursorStyle_Crosshair:
        return .crosshair
      case WuiCursorStyle_OpenHand:
        return .openHand
      case WuiCursorStyle_ClosedHand:
        return .closedHand
      case WuiCursorStyle_NotAllowed:
        return .operationNotAllowed
      case WuiCursorStyle_ResizeLeft:
        return .resizeLeft
      case WuiCursorStyle_ResizeRight:
        return .resizeRight
      case WuiCursorStyle_ResizeUp:
        return .resizeUp
      case WuiCursorStyle_ResizeDown:
        return .resizeDown
      case WuiCursorStyle_ResizeLeftRight:
        return .resizeLeftRight
      case WuiCursorStyle_ResizeUpDown:
        return .resizeUpDown
      case WuiCursorStyle_Move:
        // macOS doesn't have a dedicated move cursor, use openHand
        return .openHand
      case WuiCursorStyle_Wait:
        guard let image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: nil)
        else {
          fatalError("The system hourglass cursor image is unavailable")
        }
        return NSCursor(
          image: image,
          hotSpot: NSPoint(x: image.size.width / 2, y: image.size.height / 2)
        )
      case WuiCursorStyle_Copy:
        return .dragCopy
      default:
        fatalError("Unsupported WaterUI cursor style: \(style.rawValue)")
      }
    }
  #endif

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

#if canImport(UIKit)
  extension WuiCursor: UIPointerInteractionDelegate {
    func pointerInteraction(
      _ interaction: UIPointerInteraction,
      styleFor region: UIPointerRegion
    ) -> UIPointerStyle? {
      let shape = UIPointerShape.roundedRect(bounds)
      return UIPointerStyle(shape: shape)
    }
  }
#endif
