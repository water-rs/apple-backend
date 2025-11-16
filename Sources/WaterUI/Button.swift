//
//  Button.swift
//
//
//  Created by Lexo Liu on 5/14/24.
//
import CWaterUI
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

@MainActor
struct WuiButton: View, WuiComponent {
    static let id: String = decodeViewIdentifier(waterui_button_id())
    
    private var label: WuiAnyView
    private var action: Action

    init(button: CWaterUI.WuiButton, env: WuiEnvironment) {
        label = WuiAnyView(anyview: button.label, env: env)
        action = Action(inner: button.action, env: env)
    }

    init(anyview: OpaquePointer, env: WuiEnvironment) {
        self.init(button: waterui_force_as_button(anyview), env: env)
    }

    var body: some View {
        #if canImport(UIKit)
        UIKitButtonRepresentable(label: label, action: action)
        #else
        // TODO: Add AppKit/WatchKit native implementations.
        Button {
            action.call()
        } label: {
            label
        }
        #endif
    }
}

#if canImport(UIKit)
@MainActor
private struct UIKitButtonRepresentable: UIViewRepresentable {
    var label: WuiAnyView
    var action: Action

    func makeUIView(context: Context) -> UIKitButtonHost {
        UIKitButtonHost(label: label.makePlatformView(), action: action)
    }

    func updateUIView(_ uiView: UIKitButtonHost, context: Context) {
        uiView.updateLabel(label.makePlatformView())
    }
}
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
