import CWaterUI
import Foundation
import SwiftUI

extension WuiProgressStyle: SwiftUI.ProgressViewStyle {
    public func makeBody(configuration: Configuration) -> some View {
        let view = SwiftUI.ProgressView(
            value: configuration.fractionCompleted,
            label: { configuration.label },
            currentValueLabel: { configuration.currentValueLabel }
        )
        switch self {
        case WuiProgressStyle_Circular:
            view.progressViewStyle(.circular)
        case WuiProgressStyle_Linear:
            view.progressViewStyle(.linear)
        default:
            view.progressViewStyle(.automatic)
        }
    }
}

struct WuiProgress: View, WuiComponent {
    static let id: String = decodeViewIdentifier(waterui_progress_id())
    private var label: WuiAnyView
    @State private var value: WuiComputed<Double>
    private var style: WuiProgressStyle

    init(progress: CWaterUI.WuiProgress, env: WuiEnvironment) {
        self.label = WuiAnyView(anyview: progress.label, env: env)
        self.style = progress.style
        self.value = WuiComputed(progress.value)
    }

    init(anyview: OpaquePointer, env: WuiEnvironment) {
        self.init(progress: waterui_force_as_progress(anyview), env: env)
    }

    var body: some View {
        #if canImport(UIKit)
        UIKitProgressRepresentable(label: label, value: value, style: style)
        #else
        VStack {
            if value.value.isInfinite {
                SwiftUI.ProgressView {
                    label
                }
            } else {
                SwiftUI.ProgressView(value: value.value) {
                    label
                }
                .animation(.default, value: value.value)
            }
        }
        .progressViewStyle(style)
        #endif
    }
}

#if canImport(UIKit)
@MainActor
private struct UIKitProgressRepresentable: UIViewRepresentable {
    var label: WuiAnyView
    var value: WuiComputed<Double>
    var style: WuiProgressStyle

    func makeUIView(context: Context) -> UIKitProgressHost {
        UIKitProgressHost(label: label.makePlatformView(), value: value, style: style)
    }

    func updateUIView(_ uiView: UIKitProgressHost, context: Context) {
        uiView.updateLabel(label.makePlatformView())
        uiView.updateValueSource(value)
        uiView.updateStyle(style)
    }
}
#endif
