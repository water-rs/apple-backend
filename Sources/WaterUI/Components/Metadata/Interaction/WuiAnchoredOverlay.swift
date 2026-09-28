@_exported import CWaterUI
import Foundation

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

/// The overlay's frame in top-left window space, per the shared placement
/// contract: `anchor` and `windowBounds` are in the same top-left coordinate
/// space, `overlaySize` is the content's ideal size already clamped to the
/// window. `env` resolves `Leading`/`Trailing` edges and `Start`/`End`
/// alignments from the environment's layout direction. Returns the frame
/// plus the logical edge it landed against — what `placed_edge` reports.
@MainActor
func wuiAnchoredOverlayFrame(
  anchor: CGRect,
  windowBounds: CGRect,
  overlaySize: CGSize,
  placement: WuiAnchorPlacement,
  env: WuiEnvironment
) -> (CGRect, WuiAnchorEdge) {
  let result = waterui_anchored_overlay_place(
    CWaterUI.WuiRect(
      origin: CWaterUI.WuiPoint(
        x: Float(anchor.minX), y: Float(anchor.minY)),
      size: CWaterUI.WuiSize(
        width: Float(anchor.width), height: Float(anchor.height))
    ),
    CWaterUI.WuiRect(
      origin: CWaterUI.WuiPoint(
        x: Float(windowBounds.minX), y: Float(windowBounds.minY)),
      size: CWaterUI.WuiSize(
        width: Float(windowBounds.width), height: Float(windowBounds.height))
    ),
    CWaterUI.WuiSize(
      width: Float(overlaySize.width), height: Float(overlaySize.height)),
    placement,
    WuiLayoutDirection_LeftToRight,
    env.inner
  )
  return (
    CGRect(
      x: CGFloat(result.frame.origin.x),
      y: CGFloat(result.frame.origin.y),
      width: CGFloat(result.frame.size.width),
      height: CGFloat(result.frame.size.height)
    ),
    result.logical_edge
  )
}

/// `AnchoredOverlay` metadata: a wrapper that presents the overlay content at
/// window level next to this view's anchor frame.
///
/// The system popovers (`NSPopover`, `UIPopoverPresentationController`) cannot
/// honour the contract exactly: neither offers edge alignment or an exact
/// `gap` once the arrow is suppressed, and neither clamps to an arbitrary
/// window margin. So the overlay is presented in a borderless window-level
/// surface positioned by `waterui_anchored_overlay_place` — an `NSPanel`
/// child window on macOS, a passthrough container in the host `UIWindow` on
/// iOS.
@MainActor
final class WuiAnchoredOverlay: PlatformView, WuiComponent {
  static var rawId: CWaterUI.WuiTypeId { waterui_metadata_anchored_overlay_id() }

  private let contentView: any WuiComponent
  private let env: WuiEnvironment
  private let overlayView: WuiAnyView
  private let isPresented: WuiBinding<Bool>
  private let placedEdge: WuiBinding<WuiAnchorEdge>
  private let placement: WuiAnchorPlacement
  private let dismissal: WuiDismissal
  private var presenceGuard: WatcherGuard?
  /// Bound `true` before the anchor had a window; presented on attach.
  private var pendingPresentation = false

  #if canImport(AppKit)
    /// The borderless child window holding the overlay while presented.
    private var panel: NSPanel?
    /// Observes clicks that land outside the panel; does not consume them.
    private var outsideMonitor: Any?
    /// Parent-window resize subscription; the overlay re-places on resize.
    private var resizeObserver: NSObjectProtocol?
    /// Anchor frame-move subscription; the overlay follows the anchor.
    private var frameObserver: NSObjectProtocol?
  #elseif canImport(UIKit)
    /// The window-covering passthrough container holding the overlay.
    private var overlayHost: WuiAnchoredOverlayHost?
  #endif

  var stretchAxis: WuiStretchAxis { contentView.stretchAxis }

  required init(anyview: OpaquePointer, env: WuiEnvironment) {
    let metadata = waterui_force_as_metadata_anchored_overlay(anyview)
    guard let overlayRaw = metadata.value.content else {
      fatalError("AnchoredOverlay.content is null")
    }
    guard let presentedRaw = metadata.value.is_presented else {
      fatalError("AnchoredOverlay.is_presented is null")
    }
    guard let placedEdgeRaw = metadata.value.placed_edge else {
      fatalError("AnchoredOverlay.placed_edge is null")
    }

    self.env = env
    self.overlayView = WuiAnyView(anyview: overlayRaw, env: env)
    self.isPresented = WuiBinding<Bool>(presentedRaw)
    self.placedEdge = WuiBinding<WuiAnchorEdge>(placedEdgeRaw)
    self.placement = metadata.value.placement
    self.dismissal = metadata.value.dismissal
    self.contentView = WuiAnyView.resolve(anyview: metadata.content, env: env)

    super.init(frame: .zero)

    contentView.translatesAutoresizingMaskIntoConstraints = true
    addSubview(contentView)

    presenceGuard = isPresented.watch { [weak self] presented, _ in
      guard let self else { return }
      if presented {
        self.presentOverlay()
      } else {
        self.dismissOverlay()
      }
    }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  @MainActor deinit {
    dismissOverlay()
  }

  func layoutPriority() -> Int32 { contentView.layoutPriority() }

  func setPlacementProposal(_ proposal: WuiProposalSize) {
    contentView.setPlacementProposal(proposal)
  }

  func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
    contentView.sizeThatFits(proposal)
  }

  func measure(_ proposal: WuiProposalSize) -> WuiViewDimensions {
    contentView.measure(proposal)
  }

  /// The overlay's ideal size bounded by the window it presents in.
  private func measureOverlay(in containerSize: CGSize) -> CGSize {
    let ideal = overlayView.sizeThatFits(
      WuiProposalSize(size: containerSize))
    return CGSize(
      width: min(ideal.width, containerSize.width),
      height: min(ideal.height, containerSize.height)
    )
  }

  /// Present or dismiss per the binding once the anchor is on a window, and
  /// close the overlay when the anchor leaves the tree.
  private func attachmentChanged() {
    #if canImport(UIKit)
      if window != nil {
        if isPresented.value || pendingPresentation {
          pendingPresentation = false
          presentOverlay()
        }
      } else {
        // The anchor left the tree: the overlay closes with it.
        pendingPresentation = false
        if isPresented.value { isPresented.set(false) }
        dismissOverlay()
      }
    #elseif canImport(AppKit)
      if window != nil {
        if isPresented.value || pendingPresentation {
          pendingPresentation = false
          presentOverlay()
        }
        observeWindowAndFrame()
      } else {
        pendingPresentation = false
        if isPresented.value { isPresented.set(false) }
        dismissOverlay()
      }
    #endif
  }

  #if canImport(UIKit)
    override func didMoveToWindow() {
      super.didMoveToWindow()
      attachmentChanged()
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      contentView.frame = bounds
      repositionOverlay()
    }
  #elseif canImport(AppKit)
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      attachmentChanged()
    }

    override func layout() {
      super.layout()
      contentView.frame = bounds
      repositionOverlay()
    }
  #endif

  // MARK: - iOS presentation

  #if canImport(UIKit)
    /// A full-window container that shows the overlay at its placed frame and
    /// forwards every hit that is not on the overlay to the content below —
    /// the same touch that dismisses the overlay still reaches its target.
    private final class WuiAnchoredOverlayHost: UIView {
      /// The overlay's frame in container space, for outside detection.
      var overlayFrame: CGRect = .zero
      /// Called on a touch down outside `overlayFrame`; nil consumes nothing.
      var onOutsideTouch: (() -> Void)?

      override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        if let hit, hit !== self {
          return hit
        }
        if !overlayFrame.contains(point) {
          onOutsideTouch?()
        }
        return nil
      }
    }

    private func presentOverlay() {
      guard let window else {
        pendingPresentation = true
        return
      }
      let host = overlayHost ?? WuiAnchoredOverlayHost(
        frame: window.bounds)
      host.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      host.backgroundColor = .clear
      host.isUserInteractionEnabled = true
      host.onOutsideTouch = { [weak self] in
        guard let self, self.dismissal == WuiDismissal_OutsideInteraction
        else { return }
        self.isPresented.set(false)
      }
      if host.superview == nil {
        window.addSubview(host)
      }
      if overlayView.superview !== host {
        host.addSubview(overlayView)
      }
      overlayHost = host
      repositionOverlay()
    }

    private func repositionOverlay() {
      guard let host = overlayHost, let window else { return }
      let container = window.bounds
      let size = measureOverlay(in: container.size)
      let (frame, logicalEdge) = wuiAnchoredOverlayFrame(
        anchor: convert(bounds, to: nil),
        windowBounds: container,
        overlaySize: size,
        placement: placement,
        env: env
      )
      host.overlayFrame = frame
      overlayView.frame = frame
      if placedEdge.value != logicalEdge {
        placedEdge.set(logicalEdge)
      }
    }

    private func dismissOverlay() {
      overlayView.removeFromSuperview()
      overlayHost?.removeFromSuperview()
      overlayHost = nil
    }
  #endif

  // MARK: - macOS presentation

  #if canImport(AppKit)
    /// AppKit runs in bottom-left space; the placement contract is written
    /// for a top-left space, so rects are mirrored about the container's
    /// height on the way in and out.
    private func mirror(_ rect: CGRect, in container: CGRect) -> CGRect {
      CGRect(
        x: rect.minX,
        y: container.minY + container.maxY - rect.maxY,
        width: rect.width,
        height: rect.height
      )
    }

    private func presentOverlay() {
      guard let parentWindow = window else {
        pendingPresentation = true
        return
      }
      if panel == nil {
        let panel = NSPanel(
          contentRect: .zero,
          styleMask: [.borderless, .nonactivatingPanel],
          backing: .buffered,
          defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        self.panel = panel
        outsideMonitor = NSEvent.addLocalMonitorForEvents(
          matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self, weak panel] event in
          guard let self, self.dismissal == WuiDismissal_OutsideInteraction
          else { return event }
          if event.window !== panel {
            self.isPresented.set(false)
          }
          return event
        }
      }
      if panel?.parent == nil {
        parentWindow.addChildWindow(panel!, ordered: .above)
      }
      if panel?.contentView !== overlayView {
        overlayView.autoresizingMask = [.width, .height]
        panel?.contentView = overlayView
      }
      repositionOverlay()
    }

    private func repositionOverlay() {
      guard let panel, let parentWindow = window,
        let container = parentWindow.contentView?.bounds
      else { return }
      let size = measureOverlay(in: container.size)
      let topLeftContainer = CGRect(
        origin: container.origin, size: container.size)
      let anchorTopLeft = mirror(convert(bounds, to: nil), in: container)
      let (frameTopLeft, logicalEdge) = wuiAnchoredOverlayFrame(
        anchor: anchorTopLeft,
        windowBounds: topLeftContainer,
        overlaySize: size,
        placement: placement,
        env: env
      )
      let frameWindow = mirror(frameTopLeft, in: container)
      panel.setFrame(parentWindow.convertToScreen(frameWindow), display: true)
      if placedEdge.value != logicalEdge {
        placedEdge.set(logicalEdge)
      }
    }

    private func observeWindowAndFrame() {
      if resizeObserver == nil, let parentWindow = window {
        resizeObserver = NotificationCenter.default.addObserver(
          forName: NSWindow.didResizeNotification,
          object: parentWindow,
          queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated { self?.repositionOverlay() }
        }
      }
      if frameObserver == nil {
        postsFrameChangedNotifications = true
        frameObserver = NotificationCenter.default.addObserver(
          forName: NSView.frameDidChangeNotification,
          object: self,
          queue: .main
        ) { [weak self] _ in
          MainActor.assumeIsolated { self?.repositionOverlay() }
        }
      }
    }

    private func dismissOverlay() {
      panel?.parent?.removeChildWindow(panel!)
      panel?.orderOut(nil)
      panel?.contentView = nil
      panel = nil
      if let outsideMonitor {
        NSEvent.removeMonitor(outsideMonitor)
        self.outsideMonitor = nil
      }
      if let resizeObserver {
        NotificationCenter.default.removeObserver(resizeObserver)
        self.resizeObserver = nil
      }
      if let frameObserver {
        NotificationCenter.default.removeObserver(frameObserver)
        self.frameObserver = nil
      }
    }
  #endif
}
