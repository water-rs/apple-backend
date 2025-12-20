import CWaterUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Component for Metadata<OnEvent>.
///
/// Handles interaction events (hover enter/exit) for the wrapped view.
/// The handler can be called multiple times (repeatable handler).
@MainActor
final class WuiOnEvent: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_metadata_on_event_id() }

    private let contentView: any WuiComponent
    private let env: WuiEnvironment
    private let event: WuiEvent
    private var handlerPtr: OpaquePointer?

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
        self.handlerPtr = metadata.value.handler

        // Resolve the content
        self.contentView = WuiAnyView.resolve(anyview: metadata.content, env: env)

        super.init(frame: .zero)

        contentView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(contentView)

        #if canImport(AppKit)
        setupTrackingArea()
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
            .activeInKeyWindow,
            .inVisibleRect
        ]
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: options,
            owner: self,
            userInfo: nil
        )
        if let trackingArea = trackingArea {
            addTrackingArea(trackingArea)
        }
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

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        handleHoverExit()
    }
    #endif

    #if canImport(UIKit)
    // iOS doesn't have native hover support without external trackpad
    // iPadOS 13.4+ has pointer interaction support
    override func didMoveToSuperview() {
        super.didMoveToSuperview()

        if #available(iOS 13.4, *) {
            // Add pointer interaction for iPadOS trackpad support
            let hoverGesture = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
            addGestureRecognizer(hoverGesture)
        }
    }

    @available(iOS 13.4, *)
    @objc private func handleHover(_ gesture: UIHoverGestureRecognizer) {
        switch gesture.state {
        case .began:
            handleHoverEnter()
        case .ended, .cancelled:
            handleHoverExit()
        default:
            break
        }
    }
    #endif

    private func handleHoverEnter() {
        if event == WuiEvent_HoverEnter, let handler = handlerPtr {
            waterui_call_on_event(handler, env.inner)
        }
    }

    private func handleHoverExit() {
        if event == WuiEvent_HoverExit, let handler = handlerPtr {
            waterui_call_on_event(handler, env.inner)
        }
    }

    @MainActor deinit {
        // Drop the handler to avoid memory leak
        if let handler = handlerPtr {
            waterui_drop_on_event(handler)
        }
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
