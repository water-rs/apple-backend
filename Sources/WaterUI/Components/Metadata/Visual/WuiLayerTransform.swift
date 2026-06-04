import CWaterUI

#if canImport(AppKit)
import AppKit
import QuartzCore

@MainActor
func wuiSetLayerTransformWithoutImplicitAnimation(_ layer: CALayer, _ transform: CATransform3D) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.transform = transform
    CATransaction.commit()
}

@MainActor
func wuiApplyLayerTransform(
    _ layer: CALayer,
    to transform: CATransform3D,
    animation: Animation,
    key: String
) {
    guard shouldAnimate(animation) else {
        wuiSetLayerTransformWithoutImplicitAnimation(layer, transform)
        return
    }

    let fromTransform = layer.presentation()?.transform ?? layer.transform
    layer.removeAnimation(forKey: key)
    let caAnimation = wuiTransformAnimation(animation)
    caAnimation.fromValue = NSValue(caTransform3D: fromTransform)
    caAnimation.toValue = NSValue(caTransform3D: transform)
    caAnimation.isRemovedOnCompletion = true
    caAnimation.fillMode = .both

    wuiSetLayerTransformWithoutImplicitAnimation(layer, transform)
    layer.add(caAnimation, forKey: key)
}

@MainActor
private func wuiTransformAnimation(_ animation: Animation) -> CABasicAnimation {
    switch animation {
    case .bezier(let duration, let x1, let y1, let x2, let y2):
        let basic = CABasicAnimation(keyPath: "transform")
        basic.duration = duration
        basic.timingFunction = CAMediaTimingFunction(
            controlPoints: Float(x1),
            Float(y1),
            Float(x2),
            Float(y2)
        )
        return basic
    case .spring(let stiffness, let damping):
        let spring = CASpringAnimation(keyPath: "transform")
        spring.mass = 1.0
        spring.stiffness = stiffness
        spring.damping = damping
        spring.initialVelocity = 0.0
        spring.duration = spring.settlingDuration
        return spring
    case .none:
        let basic = CABasicAnimation(keyPath: "transform")
        basic.duration = 0.0
        return basic
    }
}

@MainActor
@discardableResult
func wuiLayoutTransformedContent(
    _ contentView: any WuiComponent,
    in containerBounds: CGRect,
    anchor: CGPoint,
    lastBoundsSize: inout CGSize
) -> Bool {
    contentView.wantsLayer = true
    guard let layer = contentView.layer else {
        fatalError("Transformed AppKit content must be layer-backed")
    }

    let contentBounds = CGRect(origin: .zero, size: containerBounds.size)
    let expectedPosition = CGPoint(
        x: containerBounds.minX + containerBounds.width * anchor.x,
        y: containerBounds.minY + containerBounds.height * anchor.y
    )
    let needsUpdate = lastBoundsSize != containerBounds.size
        || contentView.bounds != contentBounds
        || layer.bounds != contentBounds
        || layer.anchorPoint != anchor
        || layer.position != expectedPosition

    guard needsUpdate else { return false }

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    contentView.bounds = contentBounds
    layer.bounds = contentBounds
    layer.anchorPoint = anchor
    layer.position = expectedPosition
    CATransaction.commit()

    lastBoundsSize = containerBounds.size
    contentView.needsLayout = true
    return true
}
#endif
