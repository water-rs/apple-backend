import SwiftUI
import CWaterUI

struct WuiSlider: View, WuiComponent {
    static let id: String = decodeViewIdentifier(waterui_slider_id())
    private var label: WuiAnyView
    private var minLabel: WuiAnyView
    private var maxLabel: WuiAnyView
    private var range: WuiRange_f64
    @State private var binding: WuiBinding<Double>

    var body: some View {
        #if canImport(UIKit)
        UIKitSliderRepresentable(
            label: label,
            minLabel: minLabel,
            maxLabel: maxLabel,
            range: range,
            binding: binding
        )
        #else
        SwiftUI.Slider(
            value: $binding.value,
            in: range.start...range.end,
            label: { label },
            minimumValueLabel: { minLabel },
            maximumValueLabel: { maxLabel }
        )
        #endif
    }

    init(slider: CWaterUI.WuiSlider, env: WuiEnvironment) {
        self.label = WuiAnyView(anyview: slider.label, env: env)
        self.minLabel = WuiAnyView(anyview: slider.min_value_label, env: env)
        self.maxLabel = WuiAnyView(anyview: slider.max_value_label, env: env)
        self.range = slider.range
        self.binding = WuiBinding(slider.value)
    }

    init(anyview: OpaquePointer, env: WuiEnvironment) {
        self.init(slider: waterui_force_as_slider(anyview), env: env)
    }
}

#if canImport(UIKit)
@MainActor
private struct UIKitSliderRepresentable: UIViewRepresentable {
    var label: WuiAnyView
    var minLabel: WuiAnyView
    var maxLabel: WuiAnyView
    var range: WuiRange_f64
    var binding: WuiBinding<Double>

    func makeUIView(context: Context) -> UIKitSliderHost {
        UIKitSliderHost(
            label: label.makePlatformView(),
            minLabel: minLabel.makePlatformView(),
            maxLabel: maxLabel.makePlatformView(),
            range: range,
            binding: binding
        )
    }

    func updateUIView(_ uiView: UIKitSliderHost, context: Context) {
        uiView.updateLabel(label.makePlatformView())
        uiView.updateMinLabel(minLabel.makePlatformView())
        uiView.updateMaxLabel(maxLabel.makePlatformView())
        uiView.updateRange(range)
        uiView.updateBinding(binding)
    }
}
#endif
