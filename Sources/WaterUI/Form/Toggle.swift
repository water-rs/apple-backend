//
//  Toggle.swift
//
//
//  Created by Lexo Liu on 8/2/24.
//

import Foundation
import CWaterUI
import SwiftUI

public struct WuiToggle: View, WuiComponent {
    static let id: String = decodeViewIdentifier(waterui_toggle_id())
    @State private var binding: WuiBinding<Bool>
    private var label: WuiAnyView

    init(toggle: CWaterUI.WuiToggle, env: WuiEnvironment) {
        binding = WuiBinding(toggle.toggle)
        label = WuiAnyView(anyview: toggle.label, env: env)
    }

    init(anyview: OpaquePointer, env: WuiEnvironment) {
        self.init(toggle: waterui_force_as_toggle(anyview), env: env)
    }

    public var body: some View {
        #if canImport(UIKit)
        UIKitToggleRepresentable(label: label, binding: binding)
        #else
        SwiftUI.Toggle(isOn: $binding.value) {
            label
        }
        #endif
    }
}

#if canImport(UIKit)
@MainActor
private struct UIKitToggleRepresentable: UIViewRepresentable {
    var label: WuiAnyView
    var binding: WuiBinding<Bool>

    func makeUIView(context: Context) -> UIKitToggleHost {
        UIKitToggleHost(label: label.makePlatformView(), binding: binding)
    }

    func updateUIView(_ uiView: UIKitToggleHost, context: Context) {
        uiView.updateLabel(label.makePlatformView())
        uiView.updateBinding(binding)
    }
}
#endif
