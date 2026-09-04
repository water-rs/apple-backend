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
    // `nonisolated(unsafe)`: only ever touched on the main actor, plus by the
    // deinit below, which cannot be isolated.
    private nonisolated(unsafe) let inner: OpaquePointer
    private let env: WuiEnvironment

    init(inner: OpaquePointer, env: WuiEnvironment) {
        self.inner = inner
        self.env = env
    }

    func call() {
        waterui_call_action(inner, env.inner)
    }

    // Not `@MainActor`: an isolated deinit goes through
    // `swift_task_deinitOnExecutorImpl`, whose executor check faults when AppKit
    // releases the owner from an autorelease-pool drain inside `NSView.dealloc`.
    // The body only hands a pointer back to Rust.
    nonisolated deinit {
        waterui_drop_action(inner)
    }
}
