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
  case bezier(duration: TimeInterval, x1: CGFloat, y1: CGFloat, x2: CGFloat, y2: CGFloat)
  case spring(stiffness: CGFloat, damping: CGFloat)
}

/// Parses FFI animation tagged union to Swift enum.
func parseAnimation(_ ffiAnimation: CWaterUI.WuiAnimation) -> Animation {
  switch ffiAnimation.tag {
  case WuiAnimation_None:
    return .none
  case WuiAnimation_Bezier:
    return .bezier(
      duration: TimeInterval(ffiAnimation.bezier.duration_ms) / 1000.0,
      x1: CGFloat(ffiAnimation.bezier.x1),
      y1: CGFloat(ffiAnimation.bezier.y1),
      x2: CGFloat(ffiAnimation.bezier.x2),
      y2: CGFloat(ffiAnimation.bezier.y2)
    )
  case WuiAnimation_Spring:
    return .spring(
      stiffness: CGFloat(ffiAnimation.spring.stiffness),
      damping: CGFloat(ffiAnimation.spring.damping)
    )
  default:
    fatalError("Unsupported WaterUI animation tag: \(ffiAnimation.tag.rawValue)")
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
    case .bezier(let duration, let x1, let y1, let x2, let y2):
      let timing = UICubicTimingParameters(
        controlPoint1: CGPoint(x: x1, y: y1),
        controlPoint2: CGPoint(x: x2, y: y2)
      )
      let animator = UIViewPropertyAnimator(duration: duration, timingParameters: timing)
      animator.addAnimations(body)
      animator.startAnimation()
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
    case .bezier(let duration, _, _, _, _):
      UIView.transition(
        with: view,
        duration: duration,
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
    case .bezier(let duration, let x1, let y1, let x2, let y2):
      NSAnimationContext.runAnimationGroup { context in
        context.duration = duration
        context.allowsImplicitAnimation = true
        context.timingFunction = CAMediaTimingFunction(
          controlPoints: Float(x1),
          Float(y1),
          Float(x2),
          Float(y2)
        )
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
    case .bezier(let duration, _, _, _, _):
      // Use CATransition for actual cross-dissolve effect on AppKit
      view.wantsLayer = true
      let transition = CATransition()
      transition.type = .fade
      transition.duration = duration
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
