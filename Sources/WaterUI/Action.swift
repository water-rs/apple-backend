//
//  Action.swift
//
//
//  Created by Lexo Liu on 5/14/24.
//
import CWaterUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
class Action {
    /// The call and drop halves of the action. `nonisolated(unsafe)`: only
    /// ever touched on the main actor, plus by the deinit below, which
    /// cannot be isolated.
    private nonisolated(unsafe) let callbacks: Callbacks

    private final class Callbacks {
        let call: @MainActor () -> Void
        let drop: () -> Void

        init(call: @escaping @MainActor () -> Void, drop: @escaping () -> Void) {
            self.call = call
            self.drop = drop
        }
    }

    init(inner: OpaquePointer, env: WuiEnvironment) {
        callbacks = Callbacks(
            call: { waterui_call_action(inner, env.inner) },
            drop: { waterui_drop_action(inner) }
        )
    }

    init(call: @escaping @MainActor () -> Void, drop: @escaping () -> Void = {}) {
        callbacks = Callbacks(call: call, drop: drop)
    }

    func call() {
        callbacks.call()
    }

    // Not `@MainActor`: an isolated deinit goes through
    // `swift_task_deinitOnExecutorImpl`, whose executor check faults when AppKit
    // releases the owner from an autorelease-pool drain inside `NSView.dealloc`.
    // The body only hands a pointer back to Rust.
    nonisolated deinit {
        callbacks.drop()
    }
}
