import CWaterUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Component for Metadata<GestureObserver>.
///
/// Attaches gesture recognizers to the wrapped content view.
@MainActor
final class WuiGesture: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_metadata_gesture_id() }

    private let contentView: any WuiComponent
    private let env: WuiEnvironment
    private let actionPtr: OpaquePointer

    var stretchAxis: WuiStretchAxis {
        contentView.stretchAxis
    }

    required init(anyview: OpaquePointer, env: WuiEnvironment) {
        let metadata = waterui_force_as_metadata_gesture(anyview)

        self.env = env
        self.actionPtr = metadata.value.action

        // Resolve the content
        self.contentView = WuiAnyView.resolve(anyview: metadata.content, env: env)

        super.init(frame: .zero)

        contentView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(contentView)

        // Attach gesture recognizer based on type
        attachGesture(metadata.value.gesture)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func attachGesture(_ gesture: CWaterUI.WuiGesture) {
        #if canImport(UIKit)
        switch gesture.tag {
        case WuiGesture_Tap:
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
            tap.numberOfTapsRequired = Int(gesture.tap.count)
            self.addGestureRecognizer(tap)
            self.isUserInteractionEnabled = true

        case WuiGesture_LongPress:
            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress))
            longPress.minimumPressDuration = TimeInterval(gesture.long_press.duration) / 1000.0
            self.addGestureRecognizer(longPress)
            self.isUserInteractionEnabled = true

        case WuiGesture_Drag:
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
            self.addGestureRecognizer(pan)
            self.isUserInteractionEnabled = true

        case WuiGesture_Magnification:
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch))
            self.addGestureRecognizer(pinch)
            self.isUserInteractionEnabled = true

        case WuiGesture_Rotation:
            let rotation = UIRotationGestureRecognizer(target: self, action: #selector(handleRotation))
            self.addGestureRecognizer(rotation)
            self.isUserInteractionEnabled = true

        case WuiGesture_Then:
            // For compound gestures, attach the first one
            // Full implementation would chain gesture states
            if let first = gesture.then.first {
                attachGesture(first.pointee)
            }

        default:
            break
        }
        #elseif canImport(AppKit)
        switch gesture.tag {
        case WuiGesture_Tap:
            let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
            click.numberOfClicksRequired = Int(gesture.tap.count)
            self.addGestureRecognizer(click)

        case WuiGesture_LongPress:
            let press = NSPressGestureRecognizer(target: self, action: #selector(handlePress))
            self.addGestureRecognizer(press)

        case WuiGesture_Drag:
            let pan = NSPanGestureRecognizer(target: self, action: #selector(handlePanMac))
            self.addGestureRecognizer(pan)

        case WuiGesture_Magnification:
            let magnify = NSMagnificationGestureRecognizer(target: self, action: #selector(handleMagnify))
            self.addGestureRecognizer(magnify)

        case WuiGesture_Rotation:
            let rotate = NSRotationGestureRecognizer(target: self, action: #selector(handleRotateMac))
            self.addGestureRecognizer(rotate)

        case WuiGesture_Then:
            // For compound gestures, attach the first one
            if let first = gesture.then.first {
                attachGesture(first.pointee)
            }

        default:
            break
        }
        #endif
    }

    private func callAction() {
        waterui_call_action(actionPtr, env.inner)
    }

    #if canImport(UIKit)
    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        if recognizer.state == .ended {
            callAction()
        }
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        if recognizer.state == .began {
            callAction()
        }
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        if recognizer.state == .ended {
            callAction()
        }
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        if recognizer.state == .ended {
            callAction()
        }
    }

    @objc private func handleRotation(_ recognizer: UIRotationGestureRecognizer) {
        if recognizer.state == .ended {
            callAction()
        }
    }
    #elseif canImport(AppKit)
    @objc private func handleClick(_ recognizer: NSClickGestureRecognizer) {
        if recognizer.state == .ended {
            callAction()
        }
    }

    @objc private func handlePress(_ recognizer: NSPressGestureRecognizer) {
        if recognizer.state == .began {
            callAction()
        }
    }

    @objc private func handlePanMac(_ recognizer: NSPanGestureRecognizer) {
        if recognizer.state == .ended {
            callAction()
        }
    }

    @objc private func handleMagnify(_ recognizer: NSMagnificationGestureRecognizer) {
        if recognizer.state == .ended {
            callAction()
        }
    }

    @objc private func handleRotateMac(_ recognizer: NSRotationGestureRecognizer) {
        if recognizer.state == .ended {
            callAction()
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
