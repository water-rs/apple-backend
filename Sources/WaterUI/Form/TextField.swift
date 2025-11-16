import CWaterUI
import Foundation
import SwiftUI

public struct WuiTextField: View, WuiComponent {
    public static let id: String = decodeViewIdentifier(waterui_text_field_id())

    private var label: WuiAnyView
    @State private var prompt: WuiComputed<WuiStyledStr>
    @State private var value: WuiBinding<WuiStr>
    private var keyboard: CWaterUI.WuiKeyboardType
    private var env: WuiEnvironment

    public init(anyview: OpaquePointer, env: WuiEnvironment) {
        self.init(field: waterui_force_as_text_field(anyview), env: env)
    }

    init(field: CWaterUI.WuiTextField, env: WuiEnvironment) {
        self.label = WuiAnyView(anyview: field.label, env: env)
        self.value = WuiBinding(field.value)
        self.prompt = WuiComputed(field.prompt.content)
        self.keyboard = field.keyboard
        self.env = env
    }

    public var body: some View {
        #if canImport(UIKit)
        UIKitTextFieldRepresentable(
            label: label,
            binding: value,
            prompt: prompt,
            keyboard: keyboard,
            env: env
        )
        #else
        let promptText = WuiText(styledStr: prompt, env: env)
        SwiftUI.TextField(
            text: Binding(
                get: { value.value.toString() },
                set: { value.value = WuiStr(string: $0) }
            ),
            prompt: promptText.toSwiftUIText()
        ) {
            label
        }
        #endif
    }
}

#if canImport(UIKit)
@MainActor
private struct UIKitTextFieldRepresentable: UIViewRepresentable {
    var label: WuiAnyView
    var binding: WuiBinding<WuiStr>
    var prompt: WuiComputed<WuiStyledStr>
    var keyboard: CWaterUI.WuiKeyboardType
    var env: WuiEnvironment

    func makeUIView(context: Context) -> UIKitTextFieldHost {
        UIKitTextFieldHost(
            label: label.makePlatformView(),
            binding: binding,
            prompt: prompt,
            keyboard: keyboard,
            env: env
        )
    }

    func updateUIView(_ uiView: UIKitTextFieldHost, context: Context) {
        uiView.updateLabel(label.makePlatformView())
        uiView.updateBinding(binding)
        uiView.updatePrompt(prompt)
        uiView.updateKeyboard(keyboard)
    }
}
#endif
