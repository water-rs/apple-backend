#if canImport(UIKit)
import UIKit
import CWaterUI

@MainActor
final class PlatformRenderer {
    typealias Factory = (OpaquePointer, WuiEnvironment) -> PlatformView

    static let shared = PlatformRenderer()

    private var registry: [String: Factory] = [:]

    private init() {
        registerDefaults()
    }

    func register(id: String, factory: @escaping Factory) {
        registry[id] = factory
    }

    func makeView(anyview: OpaquePointer, env: WuiEnvironment) -> PlatformView {
        let id = decodeViewIdentifier(waterui_view_id(anyview))
        if let factory = registry[id] {
            return factory(anyview, env)
        }

        if let next = waterui_view_body(anyview, env.inner) {
            return makeView(anyview: next, env: env)
        }

        return UnsupportedComponentView(typeId: id)
    }

    private func registerDefaults() {
        register(id: WuiButton.id) { anyview, env in
            let button = waterui_force_as_button(anyview)
            let labelView = PlatformRenderer.shared.makeChildView(button.label, env: env)
            let action = Action(inner: button.action, env: env)
            return UIKitButtonHost(label: labelView, action: action)
        }

        register(id: WuiText.id) { anyview, env in
            let text = waterui_force_as_text(anyview)
            let content: WuiComputed<WuiStyledStr> = WuiComputed(text.content)
            return UIKitTextHost(content: content, env: env)
        }

        register(id: WuiSpacer.id) { _, _ in
            UIKitSpacerHost()
        }

        register(id: WuiToggle.id) { anyview, env in
            let toggle = waterui_force_as_toggle(anyview)
            let labelView = PlatformRenderer.shared.makeChildView(toggle.label, env: env)
            let binding: WuiBinding<Bool> = WuiBinding(toggle.toggle)
            return UIKitToggleHost(label: labelView, binding: binding)
        }

        register(id: WuiSlider.id) { anyview, env in
            let slider = waterui_force_as_slider(anyview)
            let labelView = PlatformRenderer.shared.makeChildView(slider.label, env: env)
            let minView = PlatformRenderer.shared.makeChildView(slider.min_value_label, env: env)
            let maxView = PlatformRenderer.shared.makeChildView(slider.max_value_label, env: env)
            let binding: WuiBinding<Double> = WuiBinding(slider.value)
            return UIKitSliderHost(
                label: labelView,
                minLabel: minView,
                maxLabel: maxView,
                range: slider.range,
                binding: binding
            )
        }

        register(id: WuiTextField.id) { anyview, env in
            let field = waterui_force_as_text_field(anyview)
            let labelView = PlatformRenderer.shared.makeChildView(field.label, env: env)
            let binding: WuiBinding<WuiStr> = WuiBinding(field.value)
            let prompt: WuiComputed<WuiStyledStr> = WuiComputed(field.prompt.content)
            return UIKitTextFieldHost(
                label: labelView,
                binding: binding,
                prompt: prompt,
                keyboard: field.keyboard,
                env: env
            )
        }

        register(id: WuiProgress.id) { anyview, env in
            let progress = waterui_force_as_progress(anyview)
            let labelView = PlatformRenderer.shared.makeChildView(progress.label, env: env)
            let value: WuiComputed<Double> = WuiComputed(progress.value)
            return UIKitProgressHost(label: labelView, value: value, style: progress.style)
        }

        register(id: WuiEmptyView.id) { _, _ in
            UIKitSpacerHost()
        }
    }
}

private extension PlatformRenderer {
    func makeChildView(
        _ pointer: OpaquePointer?,
        env: WuiEnvironment
    ) -> PlatformView {
        guard let pointer else {
            return UnsupportedComponentView(typeId: "nil-child")
        }
        return makeView(anyview: pointer, env: env)
    }
}

private final class UnsupportedComponentView: UIView, WaterUILayoutMeasurable {
    private let descriptorType: String

    init(typeId: String) {
        self.descriptorType = typeId
        super.init(frame: .zero)
        backgroundColor = UIColor.systemPink.withAlphaComponent(0.3)

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 0
        label.textAlignment = .center
        label.text = "Unsupported: \(typeId)"
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var descriptor: PlatformViewDescriptor {
        PlatformViewDescriptor(typeId: descriptorType, isSpacer: false)
    }

    func layoutPriority() -> UInt8 { 0 }

    func measure(in proposal: WuiProposalSize) -> CGSize {
        let width = proposal.width.map { CGFloat($0) } ?? 100
        return CGSize(width: width, height: 44)
    }
}
#endif
