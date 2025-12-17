//
//  Animation.swift
//  waterui-swift
//
//  Created by Lexo Liu on 10/6/25.
//

import CWaterUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Swift-native animation type parsed from FFI tagged union.
enum Animation {
    case none
    case linear(duration: TimeInterval)
    case easeIn(duration: TimeInterval)
    case easeOut(duration: TimeInterval)
    case easeInOut(duration: TimeInterval)
    case spring(stiffness: CGFloat, damping: CGFloat)
}

/// Parses FFI animation tagged union to Swift enum.
func parseAnimation(_ ffiAnimation: CWaterUI.WuiAnimation) -> Animation {
    switch ffiAnimation.tag {
    case WuiAnimation_None:
        return .none
    case WuiAnimation_Default:
        return .easeInOut(duration: 0.25)
    case WuiAnimation_Linear:
        return .linear(duration: TimeInterval(ffiAnimation.linear.duration_ms) / 1000.0)
    case WuiAnimation_EaseIn:
        return .easeIn(duration: TimeInterval(ffiAnimation.ease_in.duration_ms) / 1000.0)
    case WuiAnimation_EaseOut:
        return .easeOut(duration: TimeInterval(ffiAnimation.ease_out.duration_ms) / 1000.0)
    case WuiAnimation_EaseInOut:
        return .easeInOut(duration: TimeInterval(ffiAnimation.ease_in_out.duration_ms) / 1000.0)
    case WuiAnimation_Spring:
        return .spring(
            stiffness: CGFloat(ffiAnimation.spring.stiffness),
            damping: CGFloat(ffiAnimation.spring.damping)
        )
    default:
        return .none
    }
}

/// Checks if the animation should be applied (not none).
@MainActor
func shouldAnimate(_ animation: Animation) -> Bool {
    if case .none = animation {
        return false
    }
    return true
}

#if canImport(UIKit)
/// Performs a UIView animation with the specified animation parameters.
@MainActor
func withPlatformAnimation(_ metadata: WuiWatcherMetadata, _ body: @escaping () -> Void) {
    let animation = parseAnimation(metadata.getAnimation())

    switch animation {
    case .none:
        body()
    case .linear(let duration):
        UIView.animate(withDuration: duration, delay: 0, options: .curveLinear, animations: body)
    case .easeIn(let duration):
        UIView.animate(withDuration: duration, delay: 0, options: .curveEaseIn, animations: body)
    case .easeOut(let duration):
        UIView.animate(withDuration: duration, delay: 0, options: .curveEaseOut, animations: body)
    case .easeInOut(let duration):
        UIView.animate(withDuration: duration, delay: 0, options: .curveEaseInOut, animations: body)
    case .spring(let stiffness, let damping):
        let timing = UISpringTimingParameters(
            mass: 1.0,
            stiffness: stiffness,
            damping: damping,
            initialVelocity: .zero
        )
        let animator = UIViewPropertyAnimator(duration: 0, timingParameters: timing)
        animator.addAnimations(body)
        animator.startAnimation()
    }
}

/// Performs a cross-dissolve transition animation on a view if needed.
@MainActor
func withCrossDissolveAnimation(
    _ view: UIView,
    _ metadata: WuiWatcherMetadata,
    _ body: @escaping () -> Void
) {
    let animation = parseAnimation(metadata.getAnimation())

    switch animation {
    case .none:
        body()
    case .linear(let duration), .easeIn(let duration), .easeOut(let duration), .easeInOut(let duration):
        UIView.transition(
            with: view,
            duration: min(duration, 0.15),
            options: .transitionCrossDissolve,
            animations: body
        )
    case .spring:
        // Cross-dissolve doesn't support spring, use default timing
        UIView.transition(
            with: view,
            duration: 0.15,
            options: .transitionCrossDissolve,
            animations: body
        )
    }
}
#elseif canImport(AppKit)
/// Performs an AppKit animation with the specified animation parameters.
@MainActor
func withPlatformAnimation(_ metadata: WuiWatcherMetadata, _ body: @escaping () -> Void) {
    let animation = parseAnimation(metadata.getAnimation())

    switch animation {
    case .none:
        body()
    case .linear(let duration), .easeIn(let duration), .easeOut(let duration), .easeInOut(let duration):
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.allowsImplicitAnimation = true
            // Note: AppKit doesn't support custom timing curves via NSAnimationContext
            // For full curve support, use CABasicAnimation or CASpringAnimation
            body()
        }
    case .spring(let stiffness, let damping):
        // AppKit spring animation using CASpringAnimation timing
        NSAnimationContext.runAnimationGroup { context in
            // Estimate duration from spring parameters
            let estimatedDuration = 2.0 * sqrt(1.0 / Double(stiffness)) * Double(damping)
            context.duration = max(0.1, min(estimatedDuration, 2.0))
            context.allowsImplicitAnimation = true
            body()
        }
    }
}

/// Performs a cross-dissolve transition animation on a view if needed.
@MainActor
func withCrossDissolveAnimation(
    _ view: NSView,
    _ metadata: WuiWatcherMetadata,
    _ body: @escaping () -> Void
) {
    let animation = parseAnimation(metadata.getAnimation())

    switch animation {
    case .none:
        body()
    case .linear(let duration), .easeIn(let duration), .easeOut(let duration), .easeInOut(let duration):
        // Use CATransition for actual cross-dissolve effect on AppKit
        view.wantsLayer = true
        let transition = CATransition()
        transition.type = .fade
        transition.duration = min(duration, 0.15)
        view.layer?.add(transition, forKey: "crossDissolve")
        body()
    case .spring:
        // Cross-dissolve doesn't support spring, use default timing
        view.wantsLayer = true
        let transition = CATransition()
        transition.type = .fade
        transition.duration = 0.15
        view.layer?.add(transition, forKey: "crossDissolve")
        body()
    }
}
#endif
