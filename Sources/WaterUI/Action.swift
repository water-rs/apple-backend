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
    private var inner: OpaquePointer
    private var env: WuiEnvironment

    init(inner: OpaquePointer, env: WuiEnvironment) {
        self.inner = inner
        self.env = env
    }

    func call() {
        waterui_call_action(self.inner, env.inner)
    }

    @MainActor deinit {
        waterui_drop_action(inner)
    }
}
