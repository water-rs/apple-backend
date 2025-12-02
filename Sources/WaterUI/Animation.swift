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

/// Checks if the metadata indicates an animation should be applied.
@MainActor
func shouldAnimate(_ metadata: WuiWatcherMetadata) -> Bool {
    let animation = metadata.getAnimation()
    return animation == WuiAnimation_Default
}

/// Returns the default animation duration based on the animation type.
func animationDuration(for animation: WuiAnimation) -> TimeInterval {
    switch animation {
    case WuiAnimation_Default:
        return 0.25
    case WuiAnimation_None:
        return 0
    default:
        return 0
    }
}

#if canImport(UIKit)
/// Performs a UIView animation if the metadata indicates animation should be used.
@MainActor
func withPlatformAnimation(_ metadata: WuiWatcherMetadata, _ body: @escaping () -> Void) {
    if shouldAnimate(metadata) {
        UIView.animate(withDuration: 0.25, animations: body)
    } else {
        body()
    }
}

/// Performs a cross-dissolve transition animation on a view if needed.
@MainActor
func withCrossDissolveAnimation(_ view: UIView, _ metadata: WuiWatcherMetadata, _ body: @escaping () -> Void) {
    if shouldAnimate(metadata) {
        UIView.transition(
            with: view,
            duration: 0.15,
            options: .transitionCrossDissolve,
            animations: body
        )
    } else {
        body()
    }
}
#elseif canImport(AppKit)
/// Performs an AppKit animation if the metadata indicates animation should be used.
@MainActor
func withPlatformAnimation(_ metadata: WuiWatcherMetadata, _ body: @escaping () -> Void) {
    if shouldAnimate(metadata) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.allowsImplicitAnimation = true
            body()
        }
    } else {
        body()
    }
}

/// Performs a cross-dissolve transition animation on a view if needed.
@MainActor
func withCrossDissolveAnimation(_ view: NSView, _ metadata: WuiWatcherMetadata, _ body: @escaping () -> Void) {
    if shouldAnimate(metadata) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.allowsImplicitAnimation = true
            body()
        }
    } else {
        body()
    }
}
#endif
