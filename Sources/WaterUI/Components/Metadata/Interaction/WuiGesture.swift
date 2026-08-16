import CWaterUI

#if canImport(UIKit)
import UIKit
private typealias PlatformGestureRecognizer = UIGestureRecognizer
#elseif canImport(AppKit)
import AppKit
private typealias PlatformGestureRecognizer = NSGestureRecognizer
#endif

@MainActor
private final class GestureTarget: NSObject {
    private let handler: (PlatformGestureRecognizer) -> Void

    init(_ handler: @escaping (PlatformGestureRecognizer) -> Void) {
        self.handler = handler
        super.init()
    }

    @objc
    func invoke(_ recognizer: PlatformGestureRecognizer) {
        handler(recognizer)
    }
}

/// Component for Metadata<GestureObserver>.
///
/// Attaches gesture recognizers to the wrapped content view.
@MainActor
final class WuiGesture: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_metadata_gesture_id() }

    private let contentView: any WuiComponent
    private let env: WuiEnvironment
    private let actionPtr: OpaquePointer
    private let gesture: CWaterUI.WuiGesture
    private var gestureTargets: [GestureTarget] = []

    var stretchAxis: WuiStretchAxis {
        contentView.stretchAxis
    }

    required init(anyview: OpaquePointer, env: WuiEnvironment) {
        let metadata = waterui_force_as_metadata_gesture(anyview)

        self.env = env
        self.actionPtr = metadata.value.action
        self.gesture = metadata.value.gesture

        self.contentView = WuiAnyView.resolve(anyview: metadata.content, env: env)

        super.init(frame: .zero)

        contentView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(contentView)

        #if canImport(UIKit)
        isUserInteractionEnabled = true
        #endif

        attachGesture(gesture) { [weak self] in
            self?.callAction()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func registerGestureRecognizer(
        _ recognizer: PlatformGestureRecognizer,
        handler: @escaping (PlatformGestureRecognizer) -> Void
    ) {
        let target = GestureTarget(handler)
        gestureTargets.append(target)
        #if canImport(UIKit)
        recognizer.addTarget(target, action: #selector(GestureTarget.invoke(_:)))
        #elseif canImport(AppKit)
        recognizer.target = target
        recognizer.action = #selector(GestureTarget.invoke(_:))
        #endif
        addGestureRecognizer(recognizer)
    }

    private func attachGesture(_ gesture: CWaterUI.WuiGesture, onRecognized: @escaping () -> Void) {
        switch gesture.tag {
        case WuiGesture_Tap:
            let taps = Int(gesture.tap.count)
            #if canImport(UIKit)
            let recognizer = UITapGestureRecognizer()
            recognizer.numberOfTapsRequired = max(taps, 1)
            registerGestureRecognizer(recognizer) { recognizer in
                guard recognizer.state == .ended else { return }
                onRecognized()
            }
            #elseif canImport(AppKit)
            let recognizer = NSClickGestureRecognizer()
            recognizer.numberOfClicksRequired = max(taps, 1)
            registerGestureRecognizer(recognizer) { recognizer in
                guard recognizer.state == .ended else { return }
                onRecognized()
            }
            #endif

        case WuiGesture_LongPress:
            #if canImport(UIKit)
            let recognizer = UILongPressGestureRecognizer()
            recognizer.minimumPressDuration = TimeInterval(gesture.long_press.duration) / 1000.0
            registerGestureRecognizer(recognizer) { recognizer in
                guard recognizer.state == .began else { return }
                onRecognized()
            }
            #elseif canImport(AppKit)
            let recognizer = NSPressGestureRecognizer()
            recognizer.minimumPressDuration = TimeInterval(gesture.long_press.duration) / 1000.0
            registerGestureRecognizer(recognizer) { recognizer in
                guard recognizer.state == .began else { return }
                onRecognized()
            }
            #endif

        case WuiGesture_Drag:
            #if canImport(UIKit)
            let recognizer = UIPanGestureRecognizer()
            registerGestureRecognizer(recognizer) { recognizer in
                guard recognizer.state == .ended else { return }
                onRecognized()
            }
            #elseif canImport(AppKit)
            let recognizer = NSPanGestureRecognizer()
            registerGestureRecognizer(recognizer) { recognizer in
                guard recognizer.state == .ended else { return }
                onRecognized()
            }
            #endif

        case WuiGesture_Magnification:
            #if canImport(UIKit)
            let recognizer = UIPinchGestureRecognizer()
            registerGestureRecognizer(recognizer) { recognizer in
                guard recognizer.state == .ended else { return }
                onRecognized()
            }
            #elseif canImport(AppKit)
            let recognizer = NSMagnificationGestureRecognizer()
            registerGestureRecognizer(recognizer) { recognizer in
                guard recognizer.state == .ended else { return }
                onRecognized()
            }
            #endif

        case WuiGesture_Rotation:
            #if canImport(UIKit)
            let recognizer = UIRotationGestureRecognizer()
            registerGestureRecognizer(recognizer) { recognizer in
                guard recognizer.state == .ended else { return }
                onRecognized()
            }
            #elseif canImport(AppKit)
            let recognizer = NSRotationGestureRecognizer()
            registerGestureRecognizer(recognizer) { recognizer in
                guard recognizer.state == .ended else { return }
                onRecognized()
            }
            #endif

        case WuiGesture_Then:
            guard
                let firstPtr = gesture.then.first,
                let secondPtr = gesture.then.then
            else {
                return
            }

            var armed = false
            attachGesture(firstPtr.pointee) {
                armed = true
            }
            attachGesture(secondPtr.pointee) {
                guard armed else { return }
                armed = false
                onRecognized()
            }

        case WuiGesture_Simultaneous:
            guard
                let firstPtr = gesture.simultaneous.first,
                let secondPtr = gesture.simultaneous.second
            else {
                return
            }

            attachGesture(firstPtr.pointee, onRecognized: onRecognized)
            attachGesture(secondPtr.pointee, onRecognized: onRecognized)

        case WuiGesture_Exclusive:
            guard
                let firstPtr = gesture.exclusive.first,
                let secondPtr = gesture.exclusive.second
            else {
                return
            }

            var lastResolvedAt = 0.0
            let suppressWindow = 0.05
            let resolveOncePerWindow = {
                let now = Date().timeIntervalSinceReferenceDate
                guard now - lastResolvedAt > suppressWindow else { return }
                lastResolvedAt = now
                onRecognized()
            }

            attachGesture(firstPtr.pointee) {
                resolveOncePerWindow()
            }
            attachGesture(secondPtr.pointee) {
                resolveOncePerWindow()
            }

        default:
            break
        }
    }

    private func releaseCompositePointers(in gesture: CWaterUI.WuiGesture) {
        switch gesture.tag {
        case WuiGesture_Then:
            if let firstPtr = gesture.then.first {
                waterui_drop_gesture(firstPtr)
            }
            if let secondPtr = gesture.then.then {
                waterui_drop_gesture(secondPtr)
            }
        case WuiGesture_Simultaneous:
            if let firstPtr = gesture.simultaneous.first {
                waterui_drop_gesture(firstPtr)
            }
            if let secondPtr = gesture.simultaneous.second {
                waterui_drop_gesture(secondPtr)
            }
        case WuiGesture_Exclusive:
            if let firstPtr = gesture.exclusive.first {
                waterui_drop_gesture(firstPtr)
            }
            if let secondPtr = gesture.exclusive.second {
                waterui_drop_gesture(secondPtr)
            }
        default:
            return
        }
    }

    private func callAction() {
        waterui_call_action(actionPtr, env.inner)
    }

    @MainActor deinit {
        waterui_drop_action(actionPtr)
        releaseCompositePointers(in: gesture)
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
    nonisolated override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        contentView.frame = bounds
    }
    #endif
}
