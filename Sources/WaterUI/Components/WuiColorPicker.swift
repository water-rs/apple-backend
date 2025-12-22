// WuiColorPicker.swift
// ColorPicker component with HDR support - merged UIKit and AppKit implementation
//
// # Layout Behavior
// ColorPicker sizes itself to fit its content and never stretches to fill extra space.
// In a stack, it takes only the space it needs.

import CWaterUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif


#if canImport(UIKit)
@MainActor
final class WuiColorPicker: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_color_picker_id() }

    private let colorWell: UIColorWell
    private var labelView: WuiAnyView
    private var binding: WuiBinding<OpaquePointer>
    private var env: WuiEnvironment
    private var supportAlpha: Bool
    private var supportHdr: Bool
    private var isSyncingFromBinding = false

    private let spacing: CGFloat = 8.0

    // MARK: - WuiComponent Init

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
        let ffiColorPicker: CWaterUI.WuiColorPicker = waterui_force_as_color_picker(anyview)
        let labelView = WuiAnyView(anyview: ffiColorPicker.label, env: env)
        let binding = WuiBinding<OpaquePointer>.color(ffiColorPicker.value)
        let supportAlpha = ffiColorPicker.support_alpha
        let supportHdr = ffiColorPicker.support_hdr
        self.init(
            label: labelView,
            binding: binding,
            env: env,
            supportAlpha: supportAlpha,
            supportHdr: supportHdr
        )
    }

    // MARK: - Designated Init

    init(
        label: WuiAnyView,
        binding: WuiBinding<OpaquePointer>,
        env: WuiEnvironment,
        supportAlpha: Bool,
        supportHdr: Bool
    ) {
        self.labelView = label
        self.binding = binding
        self.env = env
        self.supportAlpha = supportAlpha
        self.supportHdr = supportHdr
        self.colorWell = UIColorWell()
        super.init(frame: .zero)
        configureSubviews()
        configureColorWell()
        startBindingWatcher()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - WuiComponent

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        let labelSize = labelView.sizeThatFits(WuiProposalSize())
        let wellSize = colorWell.intrinsicContentSize
        let hasLabel = labelSize.width > 0 && labelSize.height > 0

        var totalWidth: CGFloat = wellSize.width
        var maxHeight: CGFloat = wellSize.height

        if hasLabel {
            totalWidth += spacing + labelSize.width
            maxHeight = max(maxHeight, labelSize.height)
        }

        return CGSize(width: totalWidth, height: maxHeight)
    }

    // MARK: - Configuration

    private func configureSubviews() {
        labelView.translatesAutoresizingMaskIntoConstraints = false
        colorWell.translatesAutoresizingMaskIntoConstraints = false

        addSubview(labelView)
        addSubview(colorWell)

        labelView.setContentCompressionResistancePriority(.required, for: .horizontal)
        labelView.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        NSLayoutConstraint.activate([
            labelView.leadingAnchor.constraint(equalTo: leadingAnchor),
            labelView.centerYAnchor.constraint(equalTo: centerYAnchor),

            colorWell.leadingAnchor.constraint(equalTo: labelView.trailingAnchor, constant: spacing),
            colorWell.trailingAnchor.constraint(equalTo: trailingAnchor),
            colorWell.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func configureColorWell() {
        colorWell.supportsAlpha = supportAlpha

        // Set initial color from binding
        let initialColor = resolveColorFromBinding()
        colorWell.selectedColor = initialColor

        colorWell.addTarget(self, action: #selector(colorChanged), for: .valueChanged)
    }

    private func startBindingWatcher() {
        _ = binding.watch { [weak self] colorPtr, _ in
            guard let self, !isSyncingFromBinding else { return }
            isSyncingFromBinding = true
            let color = self.resolveColor(colorPtr)
            self.colorWell.selectedColor = color
            isSyncingFromBinding = false
        }
    }

    @objc private func colorChanged() {
        guard !isSyncingFromBinding, let selectedColor = colorWell.selectedColor else { return }
        updateBindingWithColor(selectedColor)
    }

    // MARK: - Color Conversion

    private func resolveColorFromBinding() -> UIColor {
        let colorPtr = binding.value
        return resolveColor(colorPtr)
    }

    private func resolveColor(_ colorPtr: OpaquePointer) -> UIColor {
        // Resolve the Color to ResolvedColor using the environment
        // OpaquePointer is accepted for opaque struct pointers
        guard let resolvedPtr = waterui_resolve_color(colorPtr, env.inner) else {
            return .systemBlue
        }

        let resolved = waterui_read_computed_resolved_color(resolvedPtr)
        waterui_drop_computed_resolved_color(resolvedPtr)

        return resolvedColorToUIColor(resolved)
    }

    private func resolvedColorToUIColor(_ resolved: WuiResolvedColor) -> UIColor {
        resolved.toUIColor(allowHdr: supportHdr)
    }

    private func updateBindingWithColor(_ color: UIColor) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        var headroom: Float = 0.0
        var baseColor = color
        if #available(iOS 26.0, tvOS 26.0, visionOS 26.0, watchOS 26.0, macCatalyst 26.0, *) {
            let exposure = Float(color.linearExposure)
            if exposure > 1.0 {
                baseColor = color.standardDynamicRange
                headroom = max(0.0, exposure - 1.0)
            }
        }
        let srgb = baseColor.usingColorSpace(.extendedSRGB) ?? baseColor
        guard srgb.getRed(&r, green: &g, blue: &b, alpha: &a) else { return }

        let linearR = wuiSrgbToLinear(Float(r))
        let linearG = wuiSrgbToLinear(Float(g))
        let linearB = wuiSrgbToLinear(Float(b))
        guard let colorPtr = waterui_color_from_linear_rgba_headroom(
            linearR,
            linearG,
            linearB,
            Float(a),
            headroom
        ) else { return }
        binding.set(colorPtr)
    }

}

#elseif canImport(AppKit)
@MainActor
final class WuiColorPicker: PlatformView, WuiComponent {
    static var rawId: CWaterUI.WuiTypeId { waterui_color_picker_id() }

    private let colorWell: NSColorWell
    private var labelView: WuiAnyView
    private var binding: WuiBinding<OpaquePointer>
    private var env: WuiEnvironment
    private var supportAlpha: Bool
    private var supportHdr: Bool
    private var isSyncingFromBinding = false

    private let spacing: CGFloat = 8.0

    // MARK: - WuiComponent Init

    convenience init(anyview: OpaquePointer, env: WuiEnvironment) {
        let ffiColorPicker: CWaterUI.WuiColorPicker = waterui_force_as_color_picker(anyview)
        let labelView = WuiAnyView(anyview: ffiColorPicker.label, env: env)
        let binding = WuiBinding<OpaquePointer>.color(ffiColorPicker.value)
        let supportAlpha = ffiColorPicker.support_alpha
        let supportHdr = ffiColorPicker.support_hdr
        self.init(
            label: labelView,
            binding: binding,
            env: env,
            supportAlpha: supportAlpha,
            supportHdr: supportHdr
        )
    }

    // MARK: - Designated Init

    init(
        label: WuiAnyView,
        binding: WuiBinding<OpaquePointer>,
        env: WuiEnvironment,
        supportAlpha: Bool,
        supportHdr: Bool
    ) {
        self.labelView = label
        self.binding = binding
        self.env = env
        self.supportAlpha = supportAlpha
        self.supportHdr = supportHdr
        self.colorWell = NSColorWell()
        super.init(frame: .zero)
        configureSubviews()
        configureColorWell()
        startBindingWatcher()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    // MARK: - WuiComponent

    func sizeThatFits(_ proposal: WuiProposalSize) -> CGSize {
        let labelSize = labelView.sizeThatFits(WuiProposalSize())
        let wellSize = CGSize(width: 44, height: 24) // Standard NSColorWell size
        let hasLabel = labelSize.width > 0 && labelSize.height > 0

        var totalWidth: CGFloat = wellSize.width
        var maxHeight: CGFloat = wellSize.height

        if hasLabel {
            totalWidth += spacing + labelSize.width
            maxHeight = max(maxHeight, labelSize.height)
        }

        return CGSize(width: totalWidth, height: maxHeight)
    }

    // MARK: - Configuration

    private func configureSubviews() {
        labelView.translatesAutoresizingMaskIntoConstraints = false
        colorWell.translatesAutoresizingMaskIntoConstraints = false

        addSubview(labelView)
        addSubview(colorWell)

        labelView.setContentCompressionResistancePriority(.required, for: .horizontal)
        labelView.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        NSLayoutConstraint.activate([
            labelView.leadingAnchor.constraint(equalTo: leadingAnchor),
            labelView.centerYAnchor.constraint(equalTo: centerYAnchor),

            colorWell.leadingAnchor.constraint(equalTo: labelView.trailingAnchor, constant: spacing),
            colorWell.trailingAnchor.constraint(equalTo: trailingAnchor),
            colorWell.centerYAnchor.constraint(equalTo: centerYAnchor),
            colorWell.widthAnchor.constraint(equalToConstant: 44),
            colorWell.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    private func configureColorWell() {
        // Set initial color from binding
        let initialColor = resolveColorFromBinding()
        colorWell.color = initialColor

        // Configure color panel for alpha/HDR if needed
        if supportAlpha {
            NSColorPanel.shared.showsAlpha = true
        }

        if supportHdr {
            // Use extended color space for HDR
            NSColorPanel.shared.mode = .colorList
        }

        colorWell.target = self
        colorWell.action = #selector(colorChanged)
    }

    private func startBindingWatcher() {
        _ = binding.watch { [weak self] colorPtr, _ in
            guard let self, !isSyncingFromBinding else { return }
            isSyncingFromBinding = true
            let color = self.resolveColor(colorPtr)
            self.colorWell.color = color
            isSyncingFromBinding = false
        }
    }

    @objc private func colorChanged() {
        guard !isSyncingFromBinding else { return }
        let selectedColor = colorWell.color
        updateBindingWithColor(selectedColor)
    }

    // MARK: - Color Conversion

    private func resolveColorFromBinding() -> NSColor {
        let colorPtr = binding.value
        return resolveColor(colorPtr)
    }

    private func resolveColor(_ colorPtr: OpaquePointer) -> NSColor {
        // Resolve the Color to ResolvedColor using the environment
        // OpaquePointer is accepted for opaque struct pointers
        guard let resolvedPtr = waterui_resolve_color(colorPtr, env.inner) else {
            return .systemBlue
        }

        let resolved = waterui_read_computed_resolved_color(resolvedPtr)
        waterui_drop_computed_resolved_color(resolvedPtr)

        return resolvedColorToNSColor(resolved)
    }

    private func resolvedColorToNSColor(_ resolved: WuiResolvedColor) -> NSColor {
        resolved.toNSColor(allowHdr: supportHdr)
    }

    private func updateBindingWithColor(_ color: NSColor) {
        var headroom: Float = 0.0
        var baseColor = color
        if supportHdr, #available(macOS 26.0, *) {
            let exposure = color.linearExposure
            if exposure > 1.0 {
                headroom = Float(exposure - 1.0)
                baseColor = color.standardDynamicRange
            }
        }

        let rgbColor = baseColor.usingColorSpace(.extendedSRGB) ?? baseColor.usingColorSpace(.sRGB)
        guard let rgbColor else { return }

        let r = Float(rgbColor.redComponent)
        let g = Float(rgbColor.greenComponent)
        let b = Float(rgbColor.blueComponent)
        let a = Float(rgbColor.alphaComponent)
        let linearR = wuiSrgbToLinear(r)
        let linearG = wuiSrgbToLinear(g)
        let linearB = wuiSrgbToLinear(b)
        guard let colorPtr = waterui_color_from_linear_rgba_headroom(
            linearR,
            linearG,
            linearB,
            a,
            headroom
        ) else { return }
        binding.set(colorPtr)
    }

}
#endif
