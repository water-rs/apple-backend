import CWaterUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
import QuartzCore
#endif

/// Component for Metadata<Scale>.
///
/// Applies a scale transform to the wrapped view around the specified anchor point.
/// Scales are purely visual and do not affect layout.
@MainActor
final class WuiScale: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_metadata_scale_id() }

    private let contentView: any WuiComponent
    private var scaleXWatcher: WatcherGuard?
    private var scaleYWatcher: WatcherGuard?

    // Current transform values
    private var currentScaleX: CGFloat = 1.0
    private var currentScaleY: CGFloat = 1.0
    private let anchor: CGPoint
    private var lastBoundsSize: CGSize = .zero

    var stretchAxis: WuiStretchAxis {
        contentView.stretchAxis
    }

    required init(anyview: OpaquePointer, env: WuiEnvironment) {
        let metadata = waterui_force_as_metadata_scale(anyview)

        // Convert anchor from normalized (0-1) to CGPoint
        self.anchor = CGPoint(
            x: CGFloat(metadata.value.anchor.x),
            y: CGFloat(metadata.value.anchor.y)
        )

        // Resolve the content
        self.contentView = WuiAnyView.resolve(anyview: metadata.content, env: env)

        super.init(frame: .zero)

        // Enable layer for transforms
        #if canImport(AppKit)
        wantsLayer = true
        contentView.wantsLayer = true
        #endif

        contentView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(contentView)

        // Setup watchers for reactive transform properties
        setupWatchers(metadata.value)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupWatchers(_ scale: WuiScale_Struct) {
        let scaleX = WuiComputed<Float>(scale.x)
        let scaleY = WuiComputed<Float>(scale.y)

        // Initial values
        currentScaleX = CGFloat(scaleX.value)
        currentScaleY = CGFloat(scaleY.value)
        applyTransform()

        // Watch for changes
        scaleXWatcher = scaleX.watch { [weak self] value, metadata in
            guard let self else { return }
            self.currentScaleX = CGFloat(value)
            #if canImport(UIKit)
            withPlatformAnimation(metadata) {
                self.applyTransform()
            }
            #elseif canImport(AppKit)
            let animation = parseAnimation(metadata.getAnimation())
            self.applyTransform(animation: animation)
            #endif
        }

        scaleYWatcher = scaleY.watch { [weak self] value, metadata in
            guard let self else { return }
            self.currentScaleY = CGFloat(value)
            #if canImport(UIKit)
            withPlatformAnimation(metadata) {
                self.applyTransform()
            }
            #elseif canImport(AppKit)
            let animation = parseAnimation(metadata.getAnimation())
            self.applyTransform(animation: animation)
            #endif
        }
    }

    private func applyTransform() {
        #if canImport(UIKit)
        let transform = CGAffineTransform(scaleX: currentScaleX, y: currentScaleY)
        contentView.transform = transform
        #elseif canImport(AppKit)
        guard let layer = contentView.layer else { return }
        updateAnchorPointIfNeeded()
        let transform = CATransform3DMakeScale(currentScaleX, currentScaleY, 1.0)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = transform
        CATransaction.commit()
        #endif
    }

    #if canImport(AppKit)
    private func applyTransform(animation: Animation) {
        guard let layer = contentView.layer else { return }
        updateAnchorPointIfNeeded()
        let toTransform = CATransform3DMakeScale(currentScaleX, currentScaleY, 1.0)

        let resolvedAnimation = animation
        guard shouldAnimate(resolvedAnimation) else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.transform = toTransform
            CATransaction.commit()
            return
        }

        let fromTransform = layer.presentation()?.transform ?? layer.transform
        let animationKey = "wuiScale"
        layer.removeAnimation(forKey: animationKey)

        let caAnimation: CABasicAnimation
        switch resolvedAnimation {
        case .linear(let duration):
            let basic = CABasicAnimation(keyPath: "transform")
            basic.duration = duration
            basic.timingFunction = CAMediaTimingFunction(name: .linear)
            caAnimation = basic
        case .easeIn(let duration):
            let basic = CABasicAnimation(keyPath: "transform")
            basic.duration = duration
            basic.timingFunction = CAMediaTimingFunction(name: .easeIn)
            caAnimation = basic
        case .easeOut(let duration):
            let basic = CABasicAnimation(keyPath: "transform")
            basic.duration = duration
            basic.timingFunction = CAMediaTimingFunction(name: .easeOut)
            caAnimation = basic
        case .easeInOut(let duration):
            let basic = CABasicAnimation(keyPath: "transform")
            basic.duration = duration
            basic.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            caAnimation = basic
        case .spring(let stiffness, let damping):
            let spring = CASpringAnimation(keyPath: "transform")
            spring.mass = 1.0
            spring.stiffness = stiffness
            spring.damping = damping
            spring.initialVelocity = 0.0
            spring.duration = spring.settlingDuration
            caAnimation = spring
        case .none:
            let basic = CABasicAnimation(keyPath: "transform")
            basic.duration = 0.0
            caAnimation = basic
        }

        caAnimation.fromValue = NSValue(caTransform3D: fromTransform)
        caAnimation.toValue = NSValue(caTransform3D: toTransform)
        caAnimation.isRemovedOnCompletion = true
        caAnimation.fillMode = .both

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = toTransform
        CATransaction.commit()
        layer.add(caAnimation, forKey: animationKey)
    }

    private func updateAnchorPointIfNeeded() {
        guard let layer = contentView.layer else { return }
        let size = contentView.bounds.size
        let expectedAnchor = anchor
        let expectedPosition = CGPoint(
            x: contentView.frame.origin.x + size.width * anchor.x,
            y: contentView.frame.origin.y + size.height * anchor.y
        )
        let needsUpdate = size != lastBoundsSize || layer.anchorPoint != expectedAnchor
            || layer.position != expectedPosition
        guard needsUpdate else { return }
        lastBoundsSize = size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.anchorPoint = expectedAnchor
        layer.position = expectedPosition
        CATransaction.commit()
    }
    #endif

    func layoutPriority() -> Int32 {
        contentView.layoutPriority()
    }

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        // Transform doesn't affect layout size
        contentView.sizeThatFits(proposal)
    }

    #if canImport(UIKit)
    override func layoutSubviews() {
        super.layoutSubviews()
        // Set anchorPoint and position for proper scale pivot
        contentView.layer.anchorPoint = anchor
        contentView.bounds = CGRect(origin: .zero, size: bounds.size)
        contentView.center = CGPoint(
            x: bounds.width * anchor.x,
            y: bounds.height * anchor.y
        )
    }
    #elseif canImport(AppKit)
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()

        // First set frame to trigger contentView's internal layout
        if contentView.frame != bounds {
            contentView.frame = bounds
        }
        if bounds.size != lastBoundsSize {
            applyTransform()
        }
    }
    #endif
}

// Type alias for the FFI scale struct
private typealias WuiScale_Struct = CWaterUI.WuiScale
