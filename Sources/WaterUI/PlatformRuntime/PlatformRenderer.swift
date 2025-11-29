#if canImport(UIKit)
import UIKit
import CWaterUI

@MainActor
final class PlatformRenderer {
    typealias Factory = (OpaquePointer, WuiEnvironment, String?) -> PlatformView

    static let shared = PlatformRenderer()

    private var registry: [String: Factory] = [:]
    private let plainViewId = decodeViewIdentifier(waterui_plain_id())

    private init() {
        registerDefaults()
    }

    func register(id: String, factory: @escaping Factory) {
        registry[id] = factory
    }

    func makeView(anyview: OpaquePointer, env: WuiEnvironment, typeId: String? = nil) -> PlatformView {
        guard let sanitized = sanitize(anyview) else {
            return UnsupportedComponentView(typeId: "invalid")
        }

        let resolvedId = typeId ?? decodeIdentifier(for: sanitized)

        if let resolvedId, resolvedId == plainViewId {
            let text = WuiStr(waterui_force_as_plain(sanitized)).toString()
            return UIKitPlainHost(text: text)
        }
        if let resolvedId, let factory = registry[resolvedId] {
            return factory(sanitized, env, resolvedId)
        }

        if let next = waterui_view_body(sanitized, env.inner) {
            return makeView(anyview: next, env: env)
        }

        return UnsupportedComponentView(typeId: resolvedId ?? "unknown")
    }

    private func registerDefaults() {
        // MARK: - Layout Containers
        
        // FixedContainer - layout with fixed number of children
        register(id: decodeViewIdentifier(waterui_fixed_container_id())) { anyview, env, _ in
            let container = waterui_force_as_fixed_container(anyview)
            let layout = WuiLayout(inner: container.layout!)
            
            // Build child views
            let pointerArray = WuiArray<OpaquePointer>(container.contents)
            let childViews = pointerArray
                .toArray()
                .map { PlatformRenderer.shared.makeChildView($0, env: env) }
            
            return UIKitLayoutContainer(layout: layout, children: childViews)
        }
        
        // LayoutContainer - layout with dynamic children (ForEach, etc.)
        register(id: decodeViewIdentifier(waterui_layout_container_id())) { anyview, env, _ in
            let container = waterui_force_as_layout_container(anyview)
            let layout = WuiLayout(inner: container.layout!)
            
            // Build child views from dynamic collection
            let anyViews = WuiAnyViews(container.contents)
            var childViews: [PlatformView] = []
            childViews.reserveCapacity(anyViews.count)
            for i in 0..<anyViews.count {
                let childPointer = waterui_anyviews_get_view(anyViews.inner, i)
                if let childPointer {
                    childViews.append(PlatformRenderer.shared.makeView(anyview: childPointer, env: env))
                }
            }
            
            return UIKitLayoutContainer(layout: layout, children: childViews)
        }
        
        // MARK: - Controls
        
        register(id: WuiButton.id) { anyview, env, _ in
            let button = waterui_force_as_button(anyview)
            let labelView = PlatformRenderer.shared.makeChildView(button.label, env: env)
            let action = Action(inner: button.action, env: env)
            return UIKitButtonHost(label: labelView, action: action)
        }

        register(id: WuiText.id) { anyview, env, _ in
            let text = waterui_force_as_text(anyview)
            let content: WuiComputed<WuiStyledStr> = WuiComputed(text.content)
            return UIKitTextHost(content: content, env: env)
        }


        register(id: WuiSpacer.id) { _, _, _ in
            UIKitSpacerHost()
        }

        register(id: WuiToggle.id) { anyview, env, _ in
            let toggle = waterui_force_as_toggle(anyview)
            let labelView = PlatformRenderer.shared.makeChildView(toggle.label, env: env)
            let binding: WuiBinding<Bool> = WuiBinding(toggle.toggle)
            return UIKitToggleHost(label: labelView, binding: binding)
        }

        register(id: WuiSlider.id) { anyview, env, _ in
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

        register(id: WuiTextField.id) { anyview, env, _ in
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

        register(id: WuiProgress.id) { anyview, env, _ in
            let progress = waterui_force_as_progress(anyview)
            let labelView = PlatformRenderer.shared.makeChildView(progress.label, env: env)
            let value: WuiComputed<Double> = WuiComputed(progress.value)
            return UIKitProgressHost(label: labelView, value: value, style: progress.style)
        }

        register(id: WuiEmptyView.id) { _, _, _ in
            UIKitSpacerHost()
        }
    }
}

private extension PlatformRenderer {
    func makeChildView(
        _ pointer: OpaquePointer?,
        env: WuiEnvironment
    ) -> PlatformView {
        guard let pointer = sanitize(pointer) else {
            return UnsupportedComponentView(typeId: "nil-child")
        }
        return makeView(anyview: pointer, env: env)
    }

    func sanitize(_ pointer: OpaquePointer?) -> OpaquePointer? {
        guard let pointer else {
            return nil
        }
        let raw = UInt(bitPattern: pointer)
        if raw <= 0x1000 {
            return nil
        }
        return pointer
    }

    func decodeIdentifier(for pointer: OpaquePointer) -> String? {
        let str = waterui_view_id(pointer)
        return WuiStr(str).toString()
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
